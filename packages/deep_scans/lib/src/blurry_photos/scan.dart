import 'package:scan_engine/scan_engine.dart';

import '../duplicate_photos/scan.dart' show relPath;
import '../empty_unreadable/analyzer.dart';
import '../empty_unreadable/bytes.dart' show kb;
import '../empty_unreadable/rules.dart';
import 'analyzer.dart';
import 'model.dart';
import 'rules.dart';

/// Version of the ruleset in `docs/BLURRY_PHOTO_RULESET.md`.
const blurryPhotoRulesetVersion = '1.0';

/// The category blurry photos are filed under in the standalone scan's
/// [ScanReport]. scan_engine has no blurry-photo category yet and this
/// package doesn't change scan_engine; adding one is step 1 of the
/// ruleset's merge notes. Nothing else in this scan's engine run uses this
/// category (the blank-photo detector isn't part of it).
const blurryCategoryStandIn = WasteCategory.blankPhoto;

/// Runs only the blurry photo deep scan on a device, together with the
/// empty & unreadable deep scan it relies on, through [ScanEngine] so the
/// storage permission gate applies as in the mass scan.
final class BlurryPhotoScan {
  BlurryPhotoScan({
    required this.device,
    this.rules = const BlurryPhotoRules(),
    this.healthRules = const EmptyUnreadableRules(),
    this.scanRules = const ScanRules(),
    this.clock,
  });

  final DeviceAdapter device;
  final BlurryPhotoRules rules;

  /// Rules for the empty & unreadable checks that decide which photos are
  /// reported as empty or unreadable instead of judged for blur.
  final EmptyUnreadableRules healthRules;

  final ScanRules scanRules;
  final DateTime Function()? clock;

  Future<BlurryPhotoResult> run({
    void Function(ScanProgress)? onProgress,
    ScanCancelToken? cancelToken,
  }) async {
    final health = EmptyUnreadableAnalyzer(rules: healthRules);
    final analyzer = BlurryPhotoAnalyzer(rules: rules, health: health);
    final report = await ScanEngine(
      device: device,
      rules: scanRules,
      detectors: [
        ...health.detectors(),
        analyzer.detector(blurryCategoryStandIn),
      ],
      clock: clock,
    ).scan(onProgress: onProgress, cancelToken: cancelToken);
    return BlurryPhotoResult(
        report: report, analysis: analyzer.lastResult ?? BlurryAnalysis.empty);
  }
}

final class BlurryPhotoResult {
  const BlurryPhotoResult({required this.report, required this.analysis});

  final ScanReport report;
  final BlurryAnalysis analysis;

  List<BlurVerdict> get verdicts => analysis.verdicts;

  Map<String, Object?> toJson() => {
        'scan': 'blurry_photos',
        'rulesetVersion': blurryPhotoRulesetVersion,
        'stats': {
          'photosConsidered': analysis.photosConsidered,
          'photosMeasured': analysis.photosMeasured,
          'retakePairs': analysis.retakePairs,
          'detailChecks': analysis.detailChecks,
          'decodeMs': analysis.decodeTime.inMilliseconds,
          'measureMs': analysis.measureTime.inMilliseconds,
          'elapsedMs': analysis.elapsed.inMilliseconds,
          'countsByRule': analysis.countsByRule,
          'emptyOrUnreadable': analysis.health.length,
        },
        'verdicts': [for (final v in verdicts) v.toJson()],
        'ranking': [for (final r in analysis.ranking) r.toJson()],
        'emptyAndUnreadable': [for (final v in analysis.health) v.toJson()],
        'observations': [for (final o in analysis.observations) o.toJson()],
        'report': report.toJson(),
      };

  String format(
      {String? relativeTo, bool showEvidence = false, int rankingSize = 10}) {
    String name(String id) => relativeTo == null ? id : relPath(id, relativeTo);
    final a = analysis;
    final reclaim = verdicts.fold(
        0, (s, v) => s + v.toFinding(blurryCategoryStandIn).reclaimableBytes);
    final out = StringBuffer()
      ..writeln('Blurry photo deep scan  (ruleset $blurryPhotoRulesetVersion)')
      ..writeln('${a.photosConsidered} photos, ${a.photosMeasured} measured; '
          '${a.retakePairs} retake pairs compared '
          '(${a.detailChecks} in fine detail); '
          '${a.elapsed.inMilliseconds} ms (decoding '
          '${a.decodeTime.inMilliseconds} ms, measuring '
          '${a.measureTime.inMilliseconds} ms across threads)')
      ..writeln()
      ..writeln('${verdicts.length} blurry photos, ${kb(reclaim)} reclaimable '
          '(blurriest first)');
    final state = report.categories[blurryCategoryStandIn];
    if (state != null && state.state != CategoryState.completed) {
      out.writeln('  [${state.state.name}: ${state.note}]');
    }
    for (final v in verdicts) {
      out.writeln('  ${v.rule.code}  ${v.confidence.name.padRight(7)} '
          '${v.score.toStringAsFixed(0).padLeft(3)}  ${name(v.item.id)}: '
          '${v.reason}');
      if (v.retake != null) {
        out.writeln('                  keep ${name(v.retake!.item.id)}');
      }
      if (showEvidence) {
        out.writeln('                  ${v.measurement.evidence}');
        if (v.retake != null) {
          out.writeln('                  retake: ${v.retake!.check.evidence}, '
              'detail agreement '
              '${v.retake!.detailAgreement.toStringAsFixed(3)}, '
              'retake blur width '
              '${v.retake!.measurement.blurWidth.toStringAsFixed(2)}');
        }
      }
    }

    if (a.ranking.isNotEmpty) {
      final top = a.ranking.take(rankingSize).toList();
      out
        ..writeln()
        ..writeln('Blurriest ${top.length} of ${a.ranking.length} measured '
            'photos (score, blur width in px):');
      for (final r in top) {
        out.writeln('  ${r.score.toStringAsFixed(0).padLeft(3)}  '
            '${r.measurement.blurWidth.toStringAsFixed(2).padLeft(5)}  '
            '${(r.rule?.code ?? '-').padRight(3)}  ${name(r.item.id)}');
      }
    }

    if (a.health.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Empty & unreadable photos (empty & unreadable rules):');
      for (final v in a.health) {
        out.writeln('  ${v.rule.code}  ${v.confidence.name.padRight(7)} '
            '${name(v.item.id)}: ${v.reason}');
        if (showEvidence && v.evidence != null) {
          out.writeln('                  ${v.evidence}');
        }
      }
    }
    if (a.observations.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Not flagged, but noted:');
      for (final o in a.observations) {
        out.writeln('  ${o.kind.name.padRight(12)} '
            '${o.ids.map(name).join(' + ')}: ${o.detail}');
      }
    }
    for (final issue in report.issues) {
      out.writeln('Issue: $issue');
    }
    return out.toString();
  }
}

// --- Expectations ---------------------------------------------------------

/// What a test area expects for one planted photo.
final class ExpectedPhoto {
  const ExpectedPhoto({
    required this.path,
    required this.why,
    this.rule,
    this.observation,
    this.sharperRetake,
  });

  factory ExpectedPhoto.fromJson(Map<String, Object?> json) => ExpectedPhoto(
        path: json['path']! as String,
        why: json['why'] as String? ?? '',
        rule: json['expect'] as String?,
        observation: json['observation'] as String?,
        sharperRetake: json['sharperRetake'] as String?,
      );

  final String path;
  final String why;

  /// Expected rule code: a blur rule (B01–B04), an empty & unreadable rule
  /// (E01, U06…), or null for a photo that must not be flagged.
  final String? rule;

  /// For unflagged photos: an observation kind that must be recorded
  /// (`lowDetail`, `sharpSubject`…), or null.
  final String? observation;

  /// For B04: the photo expected as the sharper retake.
  final String? sharperRetake;

  Map<String, Object?> toJson() => {
        'path': path,
        'why': why,
        'expect': rule,
        if (observation != null) 'observation': observation,
        if (sharperRetake != null) 'sharperRetake': sharperRetake,
      };
}

/// How one [ExpectedPhoto] came out.
final class PhotoOutcome {
  const PhotoOutcome(this.expected,
      {this.rule, this.observations = const {}, this.retake, this.score});

  final ExpectedPhoto expected;
  final String? rule;
  final Set<String> observations;
  final String? retake;

  /// Blur score, for measured photos.
  final double? score;

  bool get passed =>
      rule == expected.rule &&
      (expected.observation == null ||
          observations.contains(expected.observation)) &&
      retake == expected.sharperRetake;
}

List<PhotoOutcome> verifyBlurryPhotos(
    BlurryPhotoResult r, List<ExpectedPhoto> expected, String root) {
  final a = r.analysis;
  final rules = <String, String>{
    for (final v in a.health) relPath(v.item.id, root): v.rule.code,
    for (final v in a.verdicts) relPath(v.item.id, root): v.rule.code,
  };
  final retakes = <String, String>{
    for (final v in a.verdicts)
      if (v.retake != null)
        relPath(v.item.id, root): relPath(v.retake!.item.id, root)
  };
  final scores = {
    for (final p in a.ranking) relPath(p.item.id, root): p.score,
  };
  final kinds = <String, Set<String>>{};
  for (final o in a.observations) {
    for (final id in o.ids) {
      (kinds[relPath(id, root)] ??= {}).add(o.kind.name);
    }
  }
  return [
    for (final e in expected)
      PhotoOutcome(e,
          rule: rules[e.path],
          observations: kinds[e.path] ?? const {},
          retake: retakes[e.path],
          score: scores[e.path])
  ];
}

/// Whether [order] (paths, blurriest first) appears in that relative order
/// in the scan's ranking.
bool rankingFollows(BlurryPhotoResult r, List<String> order, String root) {
  final position = {
    for (var i = 0; i < r.analysis.ranking.length; i++)
      relPath(r.analysis.ranking[i].item.id, root): i
  };
  final at = [for (final path in order) position[path]];
  if (at.contains(null)) return false;
  for (var i = 1; i < at.length; i++) {
    if (at[i]! <= at[i - 1]!) return false;
  }
  return true;
}

String formatBlurryVerification(List<PhotoOutcome> outcomes,
    {List<String> rankingOrder = const [], bool? rankingOk}) {
  String mark(bool ok) => ok ? '✓' : '✗';
  final out = StringBuffer();
  final width = outcomes.fold(
      0, (w, o) => o.expected.path.length > w ? o.expected.path.length : w);
  String section(String title, bool Function(ExpectedPhoto) where) {
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
      final score = o.score == null ? '' : '  score ${o.score!.round()}';
      b.writeln('  ${e.path.padRight(width)}  expect ${want.padRight(12)} '
          'got ${got.padRight(12)} ${mark(o.passed)}$score');
      if (e.sharperRetake != null || o.retake != null) {
        b.writeln('      sharper retake: expected ${e.sharperRetake ?? '-'}, '
            'got ${o.retake ?? '-'} ${mark(e.sharperRetake == o.retake)}');
      }
      if (!o.passed) b.writeln('      (${e.why})');
    }
    return b.toString();
  }

  out
    ..write(section('Blurry photos:',
        (e) => e.rule != null && BlurRule.byCode(e.rule!) != null))
    ..writeln()
    ..write(section('Empty & unreadable photos:',
        (e) => e.rule != null && BlurRule.byCode(e.rule!) == null))
    ..writeln()
    ..write(section(
        'Look-alikes that must not be flagged:', (e) => e.rule == null));
  if (rankingOrder.isNotEmpty) {
    out
      ..writeln()
      ..writeln('Ranking order (blurriest first) '
          '${rankingOk! ? 'followed' : 'NOT followed'} ${mark(rankingOk)}: '
          '${rankingOrder.join(' > ')}');
  }

  final blur = outcomes.where((o) =>
      o.expected.rule != null && BlurRule.byCode(o.expected.rule!) != null);
  final health = outcomes.where((o) =>
      o.expected.rule != null && BlurRule.byCode(o.expected.rule!) == null);
  final clean = outcomes.where((o) => o.expected.rule == null);
  int ok(Iterable<PhotoOutcome> os) => os.where((o) => o.passed).length;
  out
    ..writeln()
    ..writeln('Deep scan: ${ok(outcomes)}/${outcomes.length} expectations met '
        '(blurry ${ok(blur)}/${blur.length}, empty/unreadable '
        '${ok(health)}/${health.length}, look-alikes ${ok(clean)}/'
        '${clean.length})${rankingOrder.isEmpty ? '' : '; ranking ${rankingOk! ? 'right' : 'wrong'}'}');
  return out.toString();
}

/// Whether every expectation and the ranking order are met.
bool allBlurryExpectationsMet(List<PhotoOutcome> outcomes,
        {bool rankingOk = true}) =>
    rankingOk && outcomes.every((o) => o.passed);
