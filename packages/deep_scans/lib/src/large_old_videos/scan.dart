import 'package:scan_engine/scan_engine.dart';

import '../duplicate_photos/scan.dart' show relPath;
import '../empty_unreadable/analyzer.dart';
import '../empty_unreadable/rules.dart';
import 'analyzer.dart';
import 'model.dart';
import 'rules.dart';

/// Version of the ruleset in `docs/LARGE_OLD_VIDEO_RULESET.md`.
const largeOldVideoRulesetVersion = '1.0';

/// The category videos are filed under in the standalone scan's
/// [ScanReport]. scan_engine has no video category yet and this package
/// doesn't change scan_engine; adding one is step 1 of the ruleset's merge
/// notes. Nothing else in this scan's engine run uses this category (the
/// unused-app detector isn't part of it).
const videoCategoryStandIn = WasteCategory.unusedApp;

/// Runs only the large & old video deep scan on a device, together with the
/// empty & unreadable deep scan it relies on, through [ScanEngine] so the
/// storage permission gate applies as in the mass scan.
final class LargeOldVideoScan {
  LargeOldVideoScan({
    required this.device,
    this.rules = const LargeOldVideoRules(),
    this.healthRules = const EmptyUnreadableRules(),
    this.scanRules = const ScanRules(),
    this.clock,
  });

  final DeviceAdapter device;
  final LargeOldVideoRules rules;

  /// Rules for the empty & unreadable checks that decide which video files
  /// are reported as empty or unreadable, and the grace period for videos
  /// that may still be recording.
  final EmptyUnreadableRules healthRules;

  final ScanRules scanRules;
  final DateTime Function()? clock;

  Future<LargeOldVideoResult> run({
    void Function(ScanProgress)? onProgress,
    ScanCancelToken? cancelToken,
  }) async {
    final health = EmptyUnreadableAnalyzer(rules: healthRules);
    final analyzer = LargeOldVideoAnalyzer(rules: rules, health: health);
    final report = await ScanEngine(
      device: device,
      rules: scanRules,
      detectors: [
        ...health.detectors(),
        analyzer.detector(videoCategoryStandIn),
      ],
      clock: clock,
    ).scan(onProgress: onProgress, cancelToken: cancelToken);
    return LargeOldVideoResult(
        report: report,
        analysis: analyzer.lastResult ?? LargeOldVideoAnalysis.empty,
        rules: rules);
  }
}

final class LargeOldVideoResult {
  const LargeOldVideoResult(
      {required this.report, required this.analysis, required this.rules});

  final ScanReport report;
  final LargeOldVideoAnalysis analysis;
  final LargeOldVideoRules rules;

  List<VideoVerdict> get verdicts => analysis.verdicts;

  Map<String, Object?> toJson() => {
        'scan': 'largeOldVideos',
        'rulesetVersion': largeOldVideoRulesetVersion,
        'sizeScale': rules.sizeScale,
        'stats': {
          'videosConsidered': analysis.videosConsidered,
          'videoBytes': analysis.videoBytes,
          'containersRead': analysis.containersRead,
          'projectsFound': analysis.projectsFound,
          'bytesRead': analysis.bytesRead,
          'elapsedMs': analysis.elapsed.inMilliseconds,
          'countsByRule': analysis.countsByRule,
          'flaggedBytes': analysis.flaggedBytes,
        },
        'batches': [for (final b in analysis.batches) b.toJson()],
        'ranking': [for (final v in analysis.ranking) v.item.id],
        'verdicts': [for (final v in verdicts) v.toJson()],
        'emptyAndUnreadable': [for (final h in analysis.health) h.toJson()],
        'observations': [for (final o in analysis.observations) o.toJson()],
        'report': report.toJson(),
      };

  String format({String? relativeTo, bool showEvidence = false, int top = 10}) {
    String name(String id) => relativeTo == null ? id : relPath(id, relativeTo);
    final a = analysis;
    final share = a.videoBytes == 0 ? 0 : a.flaggedBytes * 100 ~/ a.videoBytes;
    final out = StringBuffer()
      ..writeln('Large & old video deep scan  (ruleset '
          '$largeOldVideoRulesetVersion)')
      ..writeln('${a.videosConsidered} videos, ${formatBytes(a.videoBytes)}: '
          '${a.containersRead} containers read, ${a.projectsFound} editing '
          'projects; ${formatBytes(a.bytesRead)} read; '
          '${a.elapsed.inMilliseconds} ms');
    if (rules.sizeScale > 1) {
      out.writeln('Size thresholds divided by ${rules.sizeScale} (large '
          '${formatBytes(rules.largeBytes)}, huge '
          '${formatBytes(rules.hugeBytes)}, old from '
          '${formatBytes(rules.oldMinBytes)}): this storage is built at '
          '1/${rules.sizeScale} of real sizes');
    }
    out
      ..writeln()
      ..writeln('${verdicts.length + a.health.length} findings, '
          '${formatBytes(a.flaggedBytes)} ($share% of all video)');
    final state = report.categories[videoCategoryStandIn];
    if (state != null && state.state != CategoryState.completed) {
      out.writeln('  [${state.state.name}: ${state.note}]');
    }

    if (a.batches.isNotEmpty) {
      out
        ..writeln()
        ..writeln('For review:');
      for (final b in a.batches) {
        final sources = (b.sources.entries.toList()
              ..sort((x, y) => y.value.compareTo(x.value)))
            .map((e) => '${e.key} ${e.value}')
            .join(', ');
        out.writeln('  ${b.label.padRight(36)} '
            '${b.items.length.toString().padLeft(3)}  '
            '${formatBytes(b.bytes).padLeft(9)}'
            '${b.preselect ? '  (pre-selected)' : ''}'
            '${b.estimatedSavingBytes == null ? '' : '  saves ~${formatBytes(b.estimatedSavingBytes!)} re-encoded'}'
            '${sources.isEmpty ? '' : '; $sources'}');
      }
    }

    if (a.ranking.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Largest first:');
      for (final (i, v) in a.ranking.take(top).indexed) {
        out.writeln('  ${(i + 1).toString().padLeft(2)}. '
            '${formatBytes(v.item.sizeBytes).padLeft(9)}  ${v.rule.code}  '
            '${name(v.item.id)}');
      }
      if (a.ranking.length > top) {
        out.writeln('  … ${a.ranking.length - top} more (--top to list them)');
      }
    }

    void verdictLine(VideoVerdict v) {
      out.writeln('  ${v.rule.code}  ${v.confidence.name.padRight(7)} '
          '${name(v.item.id)}: ${v.reason}');
      if (showEvidence) {
        out.writeln('                  ${v.evidence ?? ''}'
            '${v.alsoMatched.isEmpty ? '' : '; also ${v.alsoMatched.join('; ')}'}');
        if (v.info != null) {
          out.writeln('                  ${v.info!.evidence}');
        }
      }
    }

    final broken = verdicts.where((v) => v.rule.health).toList();
    if (broken.isNotEmpty || a.health.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Broken videos:');
      broken.forEach(verdictLine);
      for (final h in a.health) {
        final v = h.verdict;
        out.writeln('  ${v.rule.code}  ${v.confidence.name.padRight(7)} '
            '${name(v.item.id)}: ${v.reason}  (empty & unreadable rule)');
        if (showEvidence && v.evidence != null) {
          out.writeln('                  ${v.evidence}');
        }
      }
    }
    final reclaim = verdicts.where((v) => !v.rule.health).toList();
    if (reclaim.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Large & old videos:');
      reclaim.forEach(verdictLine);
    }
    if (a.observations.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Not flagged, or worth knowing:');
      for (final o in a.observations) {
        out.writeln('  ${o.kind.code.padRight(3)} '
            '${o.kind.name.padRight(16)} ${name(o.id)}: ${o.detail}');
      }
    }
    for (final issue in report.issues) {
      out.writeln('Issue: $issue');
    }
    return out.toString();
  }
}

// --- Expectations ---------------------------------------------------------

/// What a test area expects for one planted video.
final class ExpectedVideo {
  const ExpectedVideo({
    required this.path,
    required this.why,
    this.rule,
    this.source,
    this.observation,
    this.changesAt,
    this.thenRule,
    this.thenObservation,
  });

  factory ExpectedVideo.fromJson(Map<String, Object?> json) => ExpectedVideo(
        path: json['path']! as String,
        why: json['why'] as String? ?? '',
        rule: json['expect'] as String?,
        source: json['source'] as String?,
        observation: json['observation'] as String?,
        changesAt: json['changesAt'] == null
            ? null
            : DateTime.parse(json['changesAt']! as String),
        thenRule: json['thenExpect'] as String?,
        thenObservation: json['thenObservation'] as String?,
      );

  final String path;
  final String why;

  /// Expected rule code: a video rule (V01–V14), an empty & unreadable rule
  /// (E01, U03…), or null for a video that must not be flagged.
  final String? rule;

  /// For flagged videos: the expected [VideoSource] name, if it matters.
  final String? source;

  /// An observation kind that must be recorded (`recent`, `activeProject`,
  /// `datesDisagree`…), or null.
  final String? observation;

  /// For a video whose answer changes with time (a recent recording, a
  /// file still being written, one about to turn a year old): from this
  /// time on, [thenRule] and [thenObservation] are expected instead.
  final DateTime? changesAt;
  final String? thenRule;
  final String? thenObservation;

  /// The expectation as of [now].
  ExpectedVideo at(DateTime now) =>
      changesAt == null || now.isBefore(changesAt!)
          ? this
          : ExpectedVideo(
              path: path,
              why: '$why (as of ${changesAt!.toIso8601String()})',
              rule: thenRule,
              source: source,
              observation: thenObservation);

  Map<String, Object?> toJson() => {
        'path': path,
        'why': why,
        'expect': rule,
        if (source != null) 'source': source,
        if (observation != null) 'observation': observation,
        if (changesAt != null) 'changesAt': changesAt!.toIso8601String(),
        if (changesAt != null) 'thenExpect': thenRule,
        if (thenObservation != null) 'thenObservation': thenObservation,
      };
}

/// How one [ExpectedVideo] came out.
final class VideoOutcome {
  const VideoOutcome(this.expected,
      {this.rule, this.source, this.observations = const {}});

  final ExpectedVideo expected;
  final String? rule;
  final String? source;
  final Set<String> observations;

  bool get passed =>
      rule == expected.rule &&
      (expected.source == null || source == expected.source) &&
      (expected.observation == null ||
          observations.contains(expected.observation));
}

/// The result of checking a scan against a test area.
final class VideoVerification {
  const VideoVerification(this.outcomes, this.unexpected);

  final List<VideoOutcome> outcomes;

  /// Flagged videos the test area doesn't list (paths and rule codes).
  final Map<String, String> unexpected;

  bool get passed => unexpected.isEmpty && outcomes.every((o) => o.passed);
}

/// Checks [r] against [expected] (paths relative to [root]), judging
/// time-dependent expectations as of the scan's start.
VideoVerification verifyVideos(
    LargeOldVideoResult r, List<ExpectedVideo> expected, String root) {
  final a = r.analysis;
  final rules = <String, String>{
    for (final h in a.health) relPath(h.item.id, root): h.verdict.rule.code,
    for (final v in a.verdicts) relPath(v.item.id, root): v.rule.code,
  };
  final sources = <String, String>{
    for (final h in a.health) relPath(h.item.id, root): h.source.name,
    for (final v in a.verdicts) relPath(v.item.id, root): v.source.name,
  };
  final notes = <String, Set<String>>{};
  for (final o in a.observations) {
    (notes[relPath(o.id, root)] ??= {}).add(o.kind.name);
  }
  final listed = {for (final e in expected) e.path};
  return VideoVerification([
    for (final e in expected.map((e) => e.at(r.report.startedAt)))
      VideoOutcome(e,
          rule: rules[e.path],
          source: sources[e.path],
          observations: notes[e.path] ?? const {})
  ], {
    for (final MapEntry(:key, :value) in rules.entries)
      if (!listed.contains(key)) key: value
  });
}

String formatVideoVerification(VideoVerification verification) {
  final outcomes = verification.outcomes;
  String mark(bool ok) => ok ? '✓' : '✗';
  final width = outcomes.fold(
      0, (w, o) => o.expected.path.length > w ? o.expected.path.length : w);
  bool broken(ExpectedVideo e) =>
      e.rule != null && (VideoRule.byCode(e.rule!)?.health ?? true);
  bool reclaim(ExpectedVideo e) =>
      e.rule != null && !(VideoRule.byCode(e.rule!)?.health ?? true);
  String section(String title, bool Function(ExpectedVideo) where) {
    final rows = outcomes.where((o) => where(o.expected)).toList();
    if (rows.isEmpty) return '';
    final b = StringBuffer()..writeln(title);
    for (final o in rows) {
      final e = o.expected;
      final want = [e.rule ?? 'clean', if (e.observation != null) e.observation]
          .join(' + ');
      final got = [
        o.rule ?? 'clean',
        if (e.observation != null && o.observations.contains(e.observation))
          e.observation
      ].join(' + ');
      b.writeln('  ${e.path.padRight(width)}  expect ${want.padRight(22)} '
          'got ${got.padRight(22)} ${mark(o.passed)}');
      if (!o.passed) {
        b.writeln('      (${e.why}'
            '${e.source != null && o.source != e.source ? '; expected source '
                '${e.source}, got ${o.source}' : ''}'
            '${o.observations.isEmpty ? '' : '; noted: ${o.observations.join(', ')}'})');
      }
    }
    return b.toString();
  }

  int ok(bool Function(ExpectedVideo) where) =>
      outcomes.where((o) => where(o.expected) && o.passed).length;
  int all(bool Function(ExpectedVideo) where) =>
      outcomes.where((o) => where(o.expected)).length;
  bool clean(ExpectedVideo e) => e.rule == null;
  final out = StringBuffer()
    ..write(
        section('Broken videos (V01–V04, empty & unreadable rules):', broken))
    ..writeln()
    ..write(section('Large & old videos (V10–V14):', reclaim))
    ..writeln()
    ..write(section('Must not be flagged:', clean))
    ..writeln();
  if (verification.unexpected.isNotEmpty) {
    out.writeln('Flagged but not in the test area:');
    for (final MapEntry(:key, :value) in verification.unexpected.entries) {
      out.writeln('  $key  $value ✗');
    }
    out.writeln();
  }
  final met = outcomes.where((o) => o.passed).length;
  out.writeln('Deep scan: $met/${outcomes.length} expectations met (broken '
      '${ok(broken)}/${all(broken)}, large & old ${ok(reclaim)}/'
      '${all(reclaim)}, not flagged ${ok(clean)}/${all(clean)}); '
      '${verification.unexpected.length} unexpected');
  return out.toString();
}
