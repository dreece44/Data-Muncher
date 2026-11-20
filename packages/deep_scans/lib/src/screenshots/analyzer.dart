import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart';

import '../empty_unreadable/analyzer.dart';
import 'measure.dart';
import 'metadata.dart';
import 'model.dart';
import 'names.dart';
import 'rules.dart';

/// Everything one run of the screenshot analysis produced.
final class ScreenshotAnalysis {
  const ScreenshotAnalysis({
    required this.verdicts,
    required this.health,
    required this.batches,
    required this.observations,
    required this.imagesConsidered,
    required this.imagesRead,
    required this.imagesDecoded,
    required this.skippedByHeader,
    required this.bytesRead,
    required this.decodeTime,
    required this.elapsed,
  });

  static const empty = ScreenshotAnalysis(
      verdicts: [],
      health: [],
      batches: [],
      observations: [],
      imagesConsidered: 0,
      imagesRead: 0,
      imagesDecoded: 0,
      skippedByHeader: 0,
      bytesRead: 0,
      decodeTime: Duration.zero,
      elapsed: Duration.zero);

  /// Screenshots, by path.
  final List<ScreenshotVerdict> verdicts;

  /// Screenshot files the empty & unreadable checks flagged; reported
  /// under that scan's rules.
  final List<ScreenshotHealth> health;

  /// The findings grouped for bulk review: blank ones, broken ones, then
  /// by kind of screen.
  final List<ScreenshotBatch> batches;
  final List<ScreenshotObservation> observations;

  /// Image files found in storage (plus partial downloads of them).
  final int imagesConsidered;

  /// Images whose header was read for metadata and size.
  final int imagesRead;

  /// Images decoded and measured.
  final int imagesDecoded;

  /// Images with no screenshot signal whose header ruled them out before
  /// decoding (camera data, or not a portrait screen shape).
  final int skippedByHeader;
  final int bytesRead;

  /// Time spent decoding and measuring (summed across parallel work).
  final Duration decodeTime;
  final Duration elapsed;

  Map<String, int> get countsByRule => {
        for (final rule in ScreenshotRule.values)
          if (verdicts.any((v) => v.rule == rule))
            rule.code: verdicts.where((v) => v.rule == rule).length,
        for (final h in health)
          h.verdict.rule.code:
              health.where((x) => x.verdict.rule == h.verdict.rule).length,
      };
}

/// The screenshot deep scan's pipeline (ruleset in
/// `docs/SCREENSHOT_RULESET.md`):
///
/// 1. run the empty & unreadable checks; image files they flag are
///    reported under their rules if the name or folder says screenshot;
/// 2. name (S01) and folder (S03) signals from the path; a short header
///    read gives metadata (S02 marker, camera data) and the image size;
/// 3. images with no signal are only decoded if they could be a phone
///    screen (portrait, no camera data);
/// 4. decode and measure: dominant colour, status bar, system-bar bands;
///    S04 for unsignalled images that look like an app screen;
/// 5. apply S05 → S06 → S01 → S02 → S03 → S04, hold back recent ones, and
///    group the findings into batches for bulk review.
final class ScreenshotAnalyzer {
  ScreenshotAnalyzer({
    this.rules = const ScreenshotRules(),
    EmptyUnreadableAnalyzer? health,
  }) : health = health ?? EmptyUnreadableAnalyzer();

  final ScreenshotRules rules;

  /// Says which images are empty or unreadable. Share one analyzer with
  /// the empty & unreadable detectors in the same [ScanEngine] so each file
  /// is checked once.
  final EmptyUnreadableAnalyzer health;

  final _runs = Expando<Future<ScreenshotAnalysis>>();

  /// The most recent completed analysis.
  ScreenshotAnalysis? lastResult;

  /// A [WasteDetector] for this scan, filing findings under [category].
  WasteDetector detector(WasteCategory category) =>
      DeepScreenshotDetector(this, category);

  Future<ScreenshotAnalysis> analyze(
          ScanContext context, WasteCategory progressCategory) =>
      _runs[context] ??= _run(context, progressCategory);

  Future<ScreenshotAnalysis> _run(
      ScanContext context, WasteCategory category) async {
    final clock = Stopwatch()..start();
    final source = context.source;
    final observations = <ScreenshotObservation>[];
    void note(
            ScreenshotObservationKind kind, StorageItem item, String detail) =>
        observations.add(ScreenshotObservation(kind, item.id, detail));

    // 1. Empty and unreadable files, from that scan.
    final checked = await health.analyze(context, category);
    final broken = {for (final v in checked.verdicts) v.item.id: v};

    final images = <StorageItem>[];
    for (final item in context.items) {
      final name = _withoutPartialExtension(item.displayName);
      final kind = mediaKindFor(name);
      if (kind == MediaKind.image) {
        images.add(item);
      } else if (kind == MediaKind.video && _isScreenRecording(item, name)) {
        note(ScreenshotObservationKind.screenRecording, item,
            'a screen recording; left to the old-video scan');
      }
    }
    images.sort((a, b) => a.id.compareTo(b.id));

    final verdicts = List<ScreenshotVerdict?>.filled(images.length, null);
    final healthHits = <ScreenshotHealth>[];
    var read = 0, decoded = 0, skipped = 0, bytes = 0, decodeMicros = 0;
    var next = 0, done = 0;

    Future<void> check(int i) async {
      final item = images[i];
      final folders = _folders(item);
      final name = _withoutPartialExtension(item.displayName);
      final systemName = matchScreenshotName(name, folders, rules.namePatterns);
      final signals = <ScreenshotSignal>[
        if (systemName != null)
          ScreenshotSignal(ScreenshotRule.s01SystemName,
              'named by ${systemName.tool}${systemName.app == null ? '' : ' (${systemName.app})'}'),
        ..._filedSignals(name, folders, systemName),
      ];

      // 1. Flagged by the empty & unreadable checks: only the path can say
      // it's a screenshot.
      final hit = broken[item.id];
      if (hit != null) {
        if (signals.isNotEmpty) {
          healthHits.add(ScreenshotHealth(hit, signals.first));
        }
        return;
      }
      if (!photoExtensions.contains(item.extension)) return;

      if (item.origin != ItemOrigin.fileSystem ||
          !source.canReadContent(item)) {
        if (signals.isNotEmpty) {
          note(ScreenshotObservationKind.contentNotRead, item,
              "contents can't be read here; judged by name and folder only");
          verdicts[i] = _classify(item, signals, systemName, null,
              ImageMetadata.none, null, context.now, observations);
        }
        return;
      }

      // 2. Header: metadata and size.
      final Uint8List head;
      try {
        head = await source.readRange(item, 0, rules.headBytes);
      } on StorageReadException catch (e) {
        note(ScreenshotObservationKind.unreadable, item, e.message);
        return;
      }
      read++;
      bytes += head.length;
      final meta = readImageMetadata(head);
      final size = readImageSize(head);
      final marker = meta.screenshotMarker(rules.toolWords);
      if (marker != null) {
        signals.insert(
            systemName == null ? 0 : 1,
            ScreenshotSignal(ScreenshotRule.s02Marker,
                'marked by its capture tool: $marker'));
      }
      final camera = meta.cameraEvidence;
      if (camera != null) {
        if (signals.isNotEmpty) {
          note(ScreenshotObservationKind.cameraPhoto, item,
              '${signals.first.detail}, but it has $camera: a photo');
        } else {
          skipped++;
        }
        return;
      }

      // 3. Nothing says screenshot: only a portrait screen shape is worth
      // decoding to look for S04.
      if (signals.isEmpty &&
          size != null &&
          !(size.$2 > size.$1 &&
              size.$2 / math.max(1, size.$1) >= rules.minPortraitAspect)) {
        skipped++;
        return;
      }
      if (!source.canDecodeThumbnail(item) ||
          item.sizeBytes > rules.maxImageBytes) {
        if (signals.isNotEmpty) {
          note(
              ScreenshotObservationKind.notDecoded,
              item,
              item.sizeBytes > rules.maxImageBytes
                  ? 'larger than ${rules.maxImageBytes ~/ (1024 * 1024)} MB; '
                      'not checked for blank content'
                  : "can't decode .${item.extension} here; not checked for "
                      'blank content');
          verdicts[i] = _classify(item, signals, systemName, null, meta, size,
              context.now, observations);
        }
        return;
      }

      // 4. Decode and measure.
      final ScreenMeasurement? m;
      try {
        final all = item.sizeBytes <= head.length
            ? head
            : await source.readRange(item, 0, item.sizeBytes);
        if (!identical(all, head)) bytes += all.length;
        final settings = rules.measureSettings;
        final watch = Stopwatch()..start();
        m = rules.useIsolates
            ? await _measureOnIsolate(all, settings)
            : measureScreen(all, settings);
        decodeMicros += watch.elapsedMicroseconds;
      } on StorageReadException catch (e) {
        note(ScreenshotObservationKind.unreadable, item, e.message);
        return;
      }
      if (m == null) {
        if (signals.isNotEmpty) {
          note(
              ScreenshotObservationKind.undecodable,
              item,
              "image data won't decode, but the empty & unreadable checks "
              'passed it');
          verdicts[i] = _classify(item, signals, systemName, null, meta, size,
              context.now, observations);
        }
        return;
      }
      decoded++;

      if (signals.isEmpty) {
        final shaped = m.portrait && m.aspect >= rules.minPortraitAspect;
        final ui = m.dominantShare >= rules.uiDominantShare &&
            m.dominantShare < rules.blankShare;
        if (shaped && ui && m.statusBar) {
          signals.add(ScreenshotSignal(
              ScreenshotRule.s04LooksLike,
              'status bar, app background covers '
              '${(m.dominantShare * 100).round()}%, no camera data'));
        } else {
          if (shaped && ui && m.flatShare >= rules.graphicFlatShare) {
            note(
                ScreenshotObservationKind.possibleScreenshot,
                item,
                'app-like flat colours '
                '(${(m.dominantShare * 100).round()}% one colour) at a '
                'screen shape, but no status bar: an exported graphic, or '
                'a screenshot without one');
          }
          return;
        }
      }
      verdicts[i] = _classify(
          item, signals, systemName, m, meta, size, context.now, observations);
    }

    Future<void> worker() async {
      while (next < images.length) {
        final i = next++;
        await check(i);
        context.tick(category, ++done, images.length);
      }
    }

    final workers = math.min(rules.concurrency, images.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);

    final found = [
      for (final v in verdicts)
        if (v != null) v
    ];
    healthHits.sort((a, b) => a.item.id.compareTo(b.item.id));
    return lastResult = ScreenshotAnalysis(
      verdicts: found,
      health: healthHits,
      batches: _batches(found, healthHits, context.now),
      observations: observations..sort((a, b) => a.id.compareTo(b.id)),
      imagesConsidered: images.length,
      imagesRead: read,
      imagesDecoded: decoded,
      skippedByHeader: skipped,
      bytesRead: bytes,
      decodeTime: Duration(microseconds: decodeMicros),
      elapsed: clock.elapsed,
    );
  }

  /// S03's signals: a screenshots folder, or a name that loosely says
  /// screenshot (when no tool pattern matched).
  List<ScreenshotSignal> _filedSignals(
      String name, List<String> folders, ScreenshotName? systemName) {
    final folder = folders.reversed
        .take(3)
        .where(rules.screenshotFolders.contains)
        .firstOrNull;
    return [
      if (folder != null)
        ScreenshotSignal(ScreenshotRule.s03Filed, 'in a "$folder" folder'),
      if (systemName == null && looseScreenshotWords.hasMatch(name))
        const ScreenshotSignal(
            ScreenshotRule.s03Filed, 'the name says screenshot'),
    ];
  }

  /// The first rule in precedence order that matches and is switched on,
  /// or null (with the reason noted).
  ScreenshotVerdict? _classify(
      StorageItem item,
      List<ScreenshotSignal> signals,
      ScreenshotName? name,
      ScreenMeasurement? m,
      ImageMetadata meta,
      (int, int)? size,
      DateTime now,
      List<ScreenshotObservation> observations) {
    void note(ScreenshotObservationKind kind, String detail) =>
        observations.add(ScreenshotObservation(kind, item.id, detail));
    signals.sort((a, b) => a.rule.index.compareTo(b.rule.index));
    final kind = _kind(name, m, size);
    final taken = name?.taken ?? item.modified;
    final ids = [
      for (final s in signals)
        if (!rules.disabledRules.contains(s.rule)) s
    ];
    final strongest = ids.isNotEmpty ? ids.first : signals.first;
    // S05/S06 need the name, a marker or the folder to say screenshot: a
    // plain-coloured image with no such signal is left to the blank-photo
    // scan (S04 never matches a blank frame).
    final named = strongest.rule != ScreenshotRule.s04LooksLike;
    final screen = switch (m?.colorName) {
      'black' => 'black',
      'white' => 'white',
      null => '',
      final c => 'one colour ($c)',
    };
    final bars = kind == ScreenKind.computer ? 'the taskbar' : 'the status bar';
    final candidates = <(ScreenshotRule, String)>[
      if (named && m != null && m.dominantShare >= rules.blankShare)
        (
          ScreenshotRule.s05Blank,
          'Blank screenshot: the whole capture is $screen'
              '${screen == 'black' ? ' (the app blocks screenshots, or the '
                  'screen was off)' : screen == 'white' ? ' (taken before '
                  'the screen loaded)' : ''}'
        ),
      if (named && m != null && m.contentDominantShare >= rules.blankShare)
        (
          ScreenshotRule.s06EmptyScreen,
          'Empty screen: nothing but $bars on a $screen screen'
        ),
      for (final s in signals)
        (s.rule, _identifiedReason(s, name, kind, taken)),
    ];
    for (final (rule, reason) in candidates) {
      if (rules.disabledRules.contains(rule)) {
        note(ScreenshotObservationKind.suppressed, '${rule.code} is disabled');
        continue;
      }
      if (!rule.confidence.atLeast(rules.minConfidence)) {
        note(ScreenshotObservationKind.suppressed,
            '${rule.code} is ${rule.confidence.name}');
        return null;
      }
      final age = taken == null ? null : now.difference(taken);
      if (!rule.empty && age != null && age < rules.recentWindow) {
        note(
            ScreenshotObservationKind.recent,
            'taken ${_ago(age)}; screenshots newer than '
            '${_ago(rules.recentWindow).replaceAll(' ago', '')} are kept');
        return null;
      }
      return ScreenshotVerdict(
        item: item,
        rule: rule,
        identifiedBy: strongest.rule,
        signals: signals,
        kind: kind,
        reason: reason,
        app: name?.app,
        taken: taken,
        measurement: m,
        metadata: meta,
      );
    }
    return null;
  }

  String _identifiedReason(ScreenshotSignal s, ScreenshotName? name,
      ScreenKind kind, DateTime? taken) {
    final what = switch (kind) {
      ScreenKind.phone => 'Phone screenshot',
      ScreenKind.tablet => 'Tablet screenshot',
      ScreenKind.computer => 'Computer screenshot',
      ScreenKind.unknown => 'Screenshot',
    };
    final of = name?.app == null ? '' : ' of ${name!.app}';
    final when = taken == null ? '' : ', taken ${_date(taken)}';
    return switch (s.rule) {
      ScreenshotRule.s01SystemName => '$what$of$when',
      ScreenshotRule.s02Marker => '$what$when (${s.detail})',
      ScreenshotRule.s03Filed => '$what$when (${s.detail})',
      _ => 'Looks like a ${what.toLowerCase()}$when: ${s.detail}',
    };
  }

  ScreenKind _kind(
      ScreenshotName? name, ScreenMeasurement? m, (int, int)? size) {
    switch (name?.tool) {
      case 'Android':
        return ScreenKind.phone;
      case 'macOS' ||
            'Windows' ||
            'Windows Snipping Tool' ||
            'GNOME' ||
            'Xbox Game Bar':
        return ScreenKind.computer;
    }
    final (w, h) = m != null ? (m.width, m.height) : size ?? (0, 0);
    if (w == 0 || h == 0) return ScreenKind.unknown;
    final aspect = math.max(w, h) / math.min(w, h);
    if (aspect < 1.2) return ScreenKind.unknown; // a crop
    if (w > h) return ScreenKind.computer;
    return aspect >= rules.phoneAspect ? ScreenKind.phone : ScreenKind.tablet;
  }

  List<ScreenshotBatch> _batches(List<ScreenshotVerdict> verdicts,
      List<ScreenshotHealth> healthHits, DateTime now) {
    bool old(DateTime? t) => t != null && now.difference(t) >= rules.oldAge;
    final empty = [
      for (final v in verdicts)
        if (v.rule.empty) v
    ];
    return [
      if (empty.isNotEmpty)
        ScreenshotBatch('empty', 'Blank & empty screenshots',
            [for (final v in empty) v.item],
            preselect: true, old: empty.where((v) => old(v.taken)).length),
      if (healthHits.isNotEmpty)
        ScreenshotBatch('unreadable', "Screenshots that can't be opened",
            [for (final h in healthHits) h.item],
            preselect: true,
            old: healthHits.where((h) => old(h.item.modified)).length),
      for (final kind in ScreenKind.values)
        if (verdicts.any((v) => !v.rule.empty && v.kind == kind))
          () {
            final these = [
              for (final v in verdicts)
                if (!v.rule.empty && v.kind == kind) v
            ];
            final apps = <String, int>{};
            for (final v in these) {
              if (v.app != null) apps[v.app!] = (apps[v.app!] ?? 0) + 1;
            }
            return ScreenshotBatch(
                kind.name, kind.label, [for (final v in these) v.item],
                old: these.where((v) => old(v.taken)).length, apps: apps);
          }(),
    ];
  }

  bool _isScreenRecording(StorageItem item, String name) {
    final lower = name.toLowerCase();
    return rules.screenRecordingWords.any(lower.contains) ||
        matchScreenshotName(name, _folders(item), rules.namePatterns)?.tool ==
            'Xbox Game Bar';
  }

  /// `Screenshot_1.png.part` → `Screenshot_1.png`.
  String _withoutPartialExtension(String name) {
    final ext = extensionOf(name);
    return health.rules.partialDownloadExtensions.contains(ext)
        ? name.substring(0, name.length - ext.length - 1)
        : name;
  }

  /// Folders above the file, lower case, nearest last.
  static List<String> _folders(StorageItem item) {
    final parts = (item.path ?? item.id).toLowerCase().split(RegExp(r'[/\\]'));
    return parts.sublist(0, parts.length - 1);
  }
}

/// Top level, so the closure sent to the isolate captures only the bytes
/// and settings, not the scan.
Future<ScreenMeasurement?> _measureOnIsolate(
        Uint8List bytes, ScreenMeasureSettings settings) =>
    Isolate.run(() => measureScreen(bytes, settings));

String _date(DateTime t) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${t.day} ${months[t.month - 1]} ${t.year}';
}

String _ago(Duration d) {
  if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  if (d.inHours >= 1) return '${d.inHours} h ago';
  return '${math.max(0, d.inMinutes)} min ago';
}

/// Screenshots, as found by the deep scan. scan_engine has no screenshot
/// category yet, so findings are filed under [category]; see the ruleset's
/// merge notes.
final class DeepScreenshotDetector extends WasteDetector {
  const DeepScreenshotDetector(this.analyzer, this.category);

  final ScreenshotAnalyzer analyzer;

  @override
  final WasteCategory category;

  @override
  Future<List<Finding>> detect(ScanContext context) async => [
        for (final v in (await analyzer.analyze(context, category)).verdicts)
          v.toFinding(category)
      ];
}
