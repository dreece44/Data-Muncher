import 'package:scan_engine/scan_engine.dart';

import '../duplicate_photos/scan.dart' show relPath;
import '../empty_unreadable/analyzer.dart';
import '../empty_unreadable/bytes.dart' show kb;
import '../empty_unreadable/rules.dart';
import 'analyzer.dart';
import 'model.dart';
import 'rules.dart';

/// Version of the ruleset in `docs/SCREENSHOT_RULESET.md`.
const screenshotRulesetVersion = '1.0';

/// The category screenshots are filed under in the standalone scan's
/// [ScanReport]. scan_engine has no screenshot category yet and this
/// package doesn't change scan_engine; adding one is step 1 of the
/// ruleset's merge notes. Nothing else in this scan's engine run uses this
/// category (the blank-photo detector isn't part of it).
const screenshotCategoryStandIn = WasteCategory.blankPhoto;

/// Runs only the screenshot deep scan on a device, together with the empty
/// & unreadable deep scan it relies on, through [ScanEngine] so the storage
/// permission gate applies as in the mass scan.
final class ScreenshotScan {
  ScreenshotScan({
    required this.device,
    this.rules = const ScreenshotRules(),
    this.healthRules = const EmptyUnreadableRules(),
    this.scanRules = const ScanRules(),
    this.clock,
  });

  final DeviceAdapter device;
  final ScreenshotRules rules;

  /// Rules for the empty & unreadable checks that decide which screenshot
  /// files are reported as empty or unreadable.
  final EmptyUnreadableRules healthRules;

  final ScanRules scanRules;
  final DateTime Function()? clock;

  Future<ScreenshotResult> run({
    void Function(ScanProgress)? onProgress,
    ScanCancelToken? cancelToken,
  }) async {
    final health = EmptyUnreadableAnalyzer(rules: healthRules);
    final analyzer = ScreenshotAnalyzer(rules: rules, health: health);
    final report = await ScanEngine(
      device: device,
      rules: scanRules,
      detectors: [
        ...health.detectors(),
        analyzer.detector(screenshotCategoryStandIn),
      ],
      clock: clock,
    ).scan(onProgress: onProgress, cancelToken: cancelToken);
    return ScreenshotResult(
        report: report,
        analysis: analyzer.lastResult ?? ScreenshotAnalysis.empty);
  }
}

final class ScreenshotResult {
  const ScreenshotResult({required this.report, required this.analysis});

  final ScanReport report;
  final ScreenshotAnalysis analysis;

  List<ScreenshotVerdict> get verdicts => analysis.verdicts;

  /// Space freed by clearing every flagged screenshot, broken ones too.
  int get reclaimableBytes =>
      verdicts.fold(0, (s, v) => s + v.item.sizeBytes) +
      analysis.health.fold(0, (s, h) => s + h.item.sizeBytes);

  Map<String, Object?> toJson() => {
        'scan': 'screenshots',
        'rulesetVersion': screenshotRulesetVersion,
        'stats': {
          'imagesConsidered': analysis.imagesConsidered,
          'imagesRead': analysis.imagesRead,
          'imagesDecoded': analysis.imagesDecoded,
          'skippedByHeader': analysis.skippedByHeader,
          'bytesRead': analysis.bytesRead,
          'decodeMs': analysis.decodeTime.inMilliseconds,
          'elapsedMs': analysis.elapsed.inMilliseconds,
          'countsByRule': analysis.countsByRule,
          'reclaimableBytes': reclaimableBytes,
        },
        'batches': [for (final b in analysis.batches) b.toJson()],
        'verdicts': [for (final v in verdicts) v.toJson()],
        'emptyAndUnreadable': [for (final h in analysis.health) h.toJson()],
        'observations': [for (final o in analysis.observations) o.toJson()],
        'report': report.toJson(),
      };

  String format({String? relativeTo, bool showEvidence = false}) {
    String name(String id) => relativeTo == null ? id : relPath(id, relativeTo);
    final a = analysis;
    final out = StringBuffer()
      ..writeln('Screenshot deep scan  (ruleset $screenshotRulesetVersion)')
      ..writeln('${a.imagesConsidered} images: ${a.imagesRead} headers read, '
          '${a.skippedByHeader} ruled out by header, ${a.imagesDecoded} '
          'decoded; ${kb(a.bytesRead)} read; ${a.elapsed.inMilliseconds} ms '
          '(decoding ${a.decodeTime.inMilliseconds} ms across threads)')
      ..writeln()
      ..writeln('${verdicts.length + a.health.length} screenshots, '
          '${kb(reclaimableBytes)} reclaimable');
    final state = report.categories[screenshotCategoryStandIn];
    if (state != null && state.state != CategoryState.completed) {
      out.writeln('  [${state.state.name}: ${state.note}]');
    }

    if (a.batches.isNotEmpty) {
      out
        ..writeln()
        ..writeln('For bulk review:');
      for (final b in a.batches) {
        final apps = b.apps.isEmpty
            ? ''
            : '; ${(b.apps.entries.toList()..sort((x, y) => y.value.compareTo(x.value))).map((e) => '${e.key} ${e.value}').join(', ')}';
        out.writeln(
            '  ${b.label.padRight(34)} ${b.items.length.toString().padLeft(3)}'
            '  ${kb(b.bytes).padLeft(9)}${b.preselect ? '  (pre-selected)' : ''}'
            '${b.old > 0 ? '  ${b.old} older than a month' : ''}$apps');
      }
    }

    out
      ..writeln()
      ..writeln('Screenshots:');
    for (final v in verdicts) {
      out.writeln('  ${v.rule.code}  ${v.confidence.name.padRight(7)} '
          '${name(v.item.id)}: ${v.reason}');
      if (showEvidence) {
        out.writeln('                  signals: ${v.signals.join('; ')}');
        if (v.measurement != null) {
          out.writeln('                  ${v.measurement!.evidence}');
        }
      }
    }
    if (a.health.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Empty & unreadable screenshots (empty & unreadable rules):');
      for (final h in a.health) {
        final v = h.verdict;
        out.writeln('  ${v.rule.code}  ${v.confidence.name.padRight(7)} '
            '${name(v.item.id)}: ${v.reason}');
        if (showEvidence) {
          out.writeln('                  screenshot by ${h.signal}'
              '${v.evidence == null ? '' : '; ${v.evidence}'}');
        }
      }
    }
    if (a.observations.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Not flagged, but noted:');
      for (final o in a.observations) {
        out.writeln('  ${o.kind.name.padRight(18)} ${name(o.id)}: ${o.detail}');
      }
    }
    for (final issue in report.issues) {
      out.writeln('Issue: $issue');
    }
    return out.toString();
  }
}

// --- Expectations ---------------------------------------------------------

/// What a test area expects for one planted image.
final class ExpectedScreenshot {
  const ExpectedScreenshot({
    required this.path,
    required this.why,
    this.rule,
    this.kind,
    this.observation,
    this.recentUntil,
    this.thenRule,
  });

  factory ExpectedScreenshot.fromJson(Map<String, Object?> json) =>
      ExpectedScreenshot(
        path: json['path']! as String,
        why: json['why'] as String? ?? '',
        rule: json['expect'] as String?,
        kind: json['kind'] as String?,
        observation: json['observation'] as String?,
        recentUntil: json['recentUntil'] == null
            ? null
            : DateTime.parse(json['recentUntil']! as String),
        thenRule: json['thenExpect'] as String?,
      );

  final String path;
  final String why;

  /// Expected rule code: a screenshot rule (S01–S06), an empty & unreadable
  /// rule (E01, U06…), or null for an image that must not be flagged.
  final String? rule;

  /// For screenshots: the expected [ScreenKind] name, if it matters.
  final String? kind;

  /// For unflagged images: an observation kind that must be recorded
  /// (`cameraPhoto`, `recent`…), or null.
  final String? observation;

  /// For a screenshot planted as just taken: until this time it is held
  /// back as recent ([rule] null, [observation] `recent`); after it,
  /// [thenRule] is expected instead.
  final DateTime? recentUntil;
  final String? thenRule;

  /// The expectation as of [now].
  ExpectedScreenshot at(DateTime now) =>
      recentUntil == null || now.isBefore(recentUntil!)
          ? this
          : ExpectedScreenshot(
              path: path,
              why: '$why (no longer recent)',
              rule: thenRule,
              kind: kind);

  Map<String, Object?> toJson() => {
        'path': path,
        'why': why,
        'expect': rule,
        if (kind != null) 'kind': kind,
        if (observation != null) 'observation': observation,
        if (recentUntil != null) 'recentUntil': recentUntil!.toIso8601String(),
        if (thenRule != null) 'thenExpect': thenRule,
      };
}

/// How one [ExpectedScreenshot] came out.
final class ScreenshotOutcome {
  const ScreenshotOutcome(this.expected,
      {this.rule, this.kind, this.observations = const {}});

  final ExpectedScreenshot expected;
  final String? rule;
  final String? kind;
  final Set<String> observations;

  bool get passed =>
      rule == expected.rule &&
      (expected.kind == null || kind == expected.kind) &&
      (expected.observation == null ||
          observations.contains(expected.observation));
}

/// Checks [r] against [expected] (paths relative to [root]), judging
/// recent-screenshot expectations as of the scan's start.
List<ScreenshotOutcome> verifyScreenshots(
    ScreenshotResult r, List<ExpectedScreenshot> expected, String root) {
  final a = r.analysis;
  final rules = <String, String>{
    for (final h in a.health) relPath(h.item.id, root): h.verdict.rule.code,
    for (final v in a.verdicts) relPath(v.item.id, root): v.rule.code,
  };
  final kinds = {
    for (final v in a.verdicts) relPath(v.item.id, root): v.kind.name,
  };
  final notes = <String, Set<String>>{};
  for (final o in a.observations) {
    (notes[relPath(o.id, root)] ??= {}).add(o.kind.name);
  }
  return [
    for (final e in expected.map((e) => e.at(r.report.startedAt)))
      ScreenshotOutcome(e,
          rule: rules[e.path],
          kind: kinds[e.path],
          observations: notes[e.path] ?? const {})
  ];
}

String formatScreenshotVerification(List<ScreenshotOutcome> outcomes) {
  String mark(bool ok) => ok ? '✓' : '✗';
  final width = outcomes.fold(
      0, (w, o) => o.expected.path.length > w ? o.expected.path.length : w);
  bool screenshot(ExpectedScreenshot e) =>
      e.rule != null && ScreenshotRule.byCode(e.rule!) != null;
  bool broken(ExpectedScreenshot e) =>
      e.rule != null && ScreenshotRule.byCode(e.rule!) == null;
  String section(String title, bool Function(ExpectedScreenshot) where) {
    final rows = outcomes.where((o) => where(o.expected)).toList();
    if (rows.isEmpty) return '';
    final b = StringBuffer()..writeln(title);
    for (final o in rows) {
      final e = o.expected;
      final want = e.rule ?? e.observation ?? 'clean';
      final got = o.rule ??
          (e.observation != null && o.observations.contains(e.observation)
              ? e.observation!
              : 'clean');
      final kind = e.kind == null ? '' : '  ${o.kind ?? '-'}';
      b.writeln('  ${e.path.padRight(width)}  expect ${want.padRight(18)} '
          'got ${got.padRight(18)} ${mark(o.passed)}$kind');
      if (!o.passed) {
        b.writeln('      (${e.why}${e.kind != null && o.kind != e.kind ? '; '
            'expected a ${e.kind} screenshot' : ''})');
      }
    }
    return b.toString();
  }

  final shots = outcomes.where((o) => screenshot(o.expected));
  final health = outcomes.where((o) => broken(o.expected));
  final clean = outcomes.where((o) => o.expected.rule == null);
  int ok(Iterable<ScreenshotOutcome> os) => os.where((o) => o.passed).length;
  return (StringBuffer()
        ..write(section('Screenshots:', screenshot))
        ..writeln()
        ..write(section('Empty & unreadable screenshots:', broken))
        ..writeln()
        ..write(section(
            'Look-alikes and held-back screenshots that must not '
            'be flagged:',
            (e) => e.rule == null))
        ..writeln()
        ..writeln('Deep scan: ${ok(outcomes)}/${outcomes.length} expectations '
            'met (screenshots ${ok(shots)}/${shots.length}, empty/unreadable '
            '${ok(health)}/${health.length}, not flagged ${ok(clean)}/'
            '${clean.length})'))
      .toString();
}

bool allScreenshotExpectationsMet(List<ScreenshotOutcome> outcomes) =>
    outcomes.every((o) => o.passed);
