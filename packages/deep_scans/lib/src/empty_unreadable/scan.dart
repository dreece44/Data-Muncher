import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

import 'analyzer.dart';
import 'bytes.dart';
import 'rules.dart';
import 'verdict.dart';

/// Version of the ruleset in `docs/EMPTY_UNREADABLE_RULESET.md`. Bump it
/// when a rule's meaning changes, so saved results can be compared fairly.
const emptyUnreadableRulesetVersion = '1.0';

/// Runs only the empty & unreadable deep scan on a device.
///
/// Goes through [ScanEngine], so the storage permission gate applies exactly
/// as in the mass scan: without access it throws [PermissionDeniedException]
/// and reads nothing.
final class EmptyUnreadableScan {
  EmptyUnreadableScan({
    required this.device,
    this.rules = const EmptyUnreadableRules(),
    this.scanRules = const ScanRules(),
    this.clock,
  });

  final DeviceAdapter device;
  final EmptyUnreadableRules rules;

  /// Engine-wide settings (image decode limits, concurrency for decoding).
  final ScanRules scanRules;
  final DateTime Function()? clock;

  Future<DeepScanResult> run({
    void Function(ScanProgress)? onProgress,
    ScanCancelToken? cancelToken,
  }) async {
    final analyzer = EmptyUnreadableAnalyzer(rules: rules);
    final report = await ScanEngine(
      device: device,
      rules: scanRules,
      detectors: analyzer.detectors(),
      clock: clock,
    ).scan(onProgress: onProgress, cancelToken: cancelToken);
    return DeepScanResult(
        report: report, analysis: analyzer.lastResult ?? AnalysisResult.empty);
  }
}

/// The deep scan's output: the standard [ScanReport] (what the UI already
/// understands) plus rule-level detail for tuning.
final class DeepScanResult {
  const DeepScanResult({required this.report, required this.analysis});

  final ScanReport report;
  final AnalysisResult analysis;

  List<FileVerdict> get verdicts => analysis.verdicts;

  FileVerdict? verdictFor(String id) {
    for (final v in verdicts) {
      if (v.item.id == id) return v;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'scan': 'empty_unreadable',
        'rulesetVersion': emptyUnreadableRulesetVersion,
        'stats': {
          'filesConsidered': analysis.filesConsidered,
          'bytesRead': analysis.reads.bytesRead,
          'reads': analysis.reads.reads,
          'elapsedMs': analysis.elapsed.inMilliseconds,
          'countsByRule': analysis.countsByRule,
        },
        'verdicts': [for (final v in verdicts) v.toJson()],
        'observations': [for (final o in analysis.observations) o.toJson()],
        'report': report.toJson(),
      };

  /// Human-readable summary. Paths are shown relative to [relativeTo].
  String format({String? relativeTo, bool showEvidence = false}) {
    String name(StorageItem item) =>
        relativeTo == null ? item.id : _rel(item.id, relativeTo);
    final out = StringBuffer()
      ..writeln('Empty & unreadable deep scan  (ruleset '
          '$emptyUnreadableRulesetVersion)')
      ..writeln('${analysis.filesConsidered} files checked, '
          '${kb(analysis.reads.bytesRead)} read in '
          '${analysis.reads.reads} reads, '
          '${analysis.elapsed.inMilliseconds} ms')
      ..writeln();

    for (final category in const [
      WasteCategory.emptyFile,
      WasteCategory.unreadableFile
    ]) {
      final state = report.categories[category];
      final found = [
        for (final v in verdicts)
          if (v.category == category) v
      ];
      final bytes = found.fold(0, (s, v) => s + v.item.sizeBytes);
      out.writeln('${category.label} (${found.length}, ${kb(bytes)})'
          '${state != null && state.state != CategoryState.completed ? '  [${state.state.name}: ${state.note}]' : ''}');
      for (final v in found) {
        out.writeln('  ${v.rule.code}  ${v.confidence.name.padRight(7)}  '
            '${name(v.item)}');
        out.writeln('                 ${v.reason}');
        if (showEvidence && v.evidence != null) {
          out.writeln('                 evidence: ${v.evidence}');
        }
      }
      out.writeln();
    }
    if (analysis.observations.isNotEmpty) {
      out.writeln('Not flagged, but noted:');
      for (final o in analysis.observations) {
        out.writeln('  ${o.kind.name.padRight(17)}  ${name(o.item)}: '
            '${o.detail}');
      }
      out.writeln();
    }
    for (final issue in report.issues) {
      out.writeln('Issue: $issue');
    }
    return out.toString();
  }
}

String _rel(String id, String root) => p.isWithin(root, id)
    ? p.relative(id, from: root).replaceAll(r'\', '/')
    : id;

/// Runs the mass scan's existing empty and unreadable detectors on [device],
/// for side-by-side comparison. Returns finding reason by item id.
Future<Map<String, Finding>> massScanFindings(DeviceAdapter device,
    {ScanRules rules = const ScanRules()}) async {
  final report = await ScanEngine(
      device: device,
      rules: rules,
      detectors: const [EmptyFileDetector(), UnreadableFileDetector()]).scan();
  return {
    for (final f in report.findings)
      for (final i in f.items) i.id: f
  };
}

/// One expected outcome from a test area's `expected.json`.
final class ExpectedCase {
  const ExpectedCase({
    required this.path,
    required this.rule,
    this.confidence,
    this.why = '',
    this.ruleAfterGrace,
    this.graceEnds,
  });

  factory ExpectedCase.fromJson(Map<String, Object?> json) => ExpectedCase(
        path: json['path']! as String,
        rule: json['expect'] as String?,
        confidence: json['confidence'] as String?,
        why: json['why'] as String? ?? '',
        ruleAfterGrace: json['expectAfterGrace'] as String?,
        graceEnds: json['graceEnds'] == null
            ? null
            : DateTime.parse(json['graceEnds']! as String),
      );

  /// Path relative to the scanned folder, with `/` separators.
  final String path;

  /// Expected rule code, or null for "should not be flagged".
  final String? rule;
  final String? confidence;
  final String why;

  /// For files that are only exempt because they were just modified: the
  /// rule expected once the grace period is over, and when that is.
  final String? ruleAfterGrace;
  final DateTime? graceEnds;

  String? ruleAt(DateTime now) =>
      graceEnds != null && !now.isBefore(graceEnds!) ? ruleAfterGrace : rule;

  Map<String, Object?> toJson() => {
        'path': path,
        'expect': rule,
        if (confidence != null) 'confidence': confidence,
        'why': why,
        if (ruleAfterGrace != null) 'expectAfterGrace': ruleAfterGrace,
        if (graceEnds != null) 'graceEnds': graceEnds!.toIso8601String(),
      };
}

/// One row of a verification run.
final class CaseOutcome {
  const CaseOutcome(this.path, this.expected, this.actual,
      {this.expectedConfidence, this.why = '', this.massScan});

  final String path;
  final String? expected;
  final FileVerdict? actual;
  final String? expectedConfidence;
  final String why;

  /// What the mass scan's detectors said, when compared.
  final Finding? massScan;

  bool get passed =>
      actual?.rule.code == expected &&
      (expectedConfidence == null ||
          actual?.confidence.name == expectedConfidence);

  WasteCategory? get expectedCategory =>
      expected == null ? null : DeepRule.byCode(expected!)?.category;

  /// Whether the mass scan put this file in the right category (it has no
  /// rule ids, so this is the fairest comparison available).
  bool get massScanCorrect => massScan?.category == expectedCategory;
}

/// Checks a scan against a test area's expectations. Files flagged but not
/// listed count as failures (unexpected findings).
List<CaseOutcome> verify(DeepScanResult result, List<ExpectedCase> cases,
    {required String root,
    required DateTime now,
    Map<String, Finding>? massScan}) {
  final byPath = {
    for (final v in result.verdicts) _rel(v.item.id, root): v,
  };
  final massByPath = {
    for (final e in (massScan ?? const <String, Finding>{}).entries)
      _rel(e.key, root): e.value,
  };
  final outcomes = [
    for (final c in cases)
      CaseOutcome(c.path, c.ruleAt(now), byPath.remove(c.path),
          expectedConfidence: c.ruleAt(now) == c.rule ? c.confidence : null,
          why: c.why,
          massScan: massByPath[c.path]),
  ];
  for (final extra in byPath.entries) {
    outcomes.add(CaseOutcome(extra.key, null, extra.value,
        why: 'not in expected.json', massScan: massByPath[extra.key]));
  }
  return outcomes;
}

String formatVerification(List<CaseOutcome> outcomes, {bool compared = false}) {
  final out = StringBuffer();
  final width =
      outcomes.fold(0, (w, o) => o.path.length > w ? o.path.length : w);
  out.writeln('${'File'.padRight(width)}  Expect  Got     '
      '${compared ? 'Mass scan         ' : ''}Result');
  for (final o in outcomes) {
    final got = o.actual == null
        ? 'clean'
        : '${o.actual!.rule.code}${o.actual!.confidence == Confidence.likely ? '?' : ''}';
    final mass = !compared
        ? ''
        : '${(o.massScan?.category.name ?? 'clean').padRight(15)}'
            '${o.massScanCorrect ? '   ' : ' ✗ '}';
    out.writeln(
        '${o.path.padRight(width)}  ${(o.expected ?? 'clean').padRight(6)}  '
        '${got.padRight(6)}  $mass${o.passed ? 'PASS' : 'FAIL'}');
    if (!o.passed && o.actual != null) {
      out.writeln('${''.padRight(width)}    → ${o.actual!.reason}'
          '${o.actual!.evidence == null ? '' : ' [${o.actual!.evidence}]'}');
    }
  }
  final passed = outcomes.where((o) => o.passed).length;
  out
    ..writeln()
    ..writeln('Deep scan: $passed/${outcomes.length} expectations met'
        '  (? = likely)');
  if (compared) {
    final mass = outcomes.where((o) => o.massScanCorrect).length;
    out.writeln('Mass scan (EmptyFileDetector + UnreadableFileDetector): '
        '$mass/${outcomes.length} in the right category');
  }
  return out.toString();
}
