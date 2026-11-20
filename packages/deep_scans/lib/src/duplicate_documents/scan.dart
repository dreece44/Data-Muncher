import 'package:scan_engine/scan_engine.dart';

import '../duplicate_photos/rules.dart' show DuplicatePhotoRules;
import '../duplicate_photos/scan.dart' show FoundGroup, GroupScore, relPath;
import '../empty_unreadable/analyzer.dart';
import '../empty_unreadable/bytes.dart' show kb;
import '../empty_unreadable/rules.dart';
import '../empty_unreadable/verdict.dart';
import 'analyzer.dart';
import 'model.dart';
import 'rules.dart';

/// Version of the ruleset in `docs/DUPLICATE_DOCUMENT_RULESET.md`.
const duplicateDocumentRulesetVersion = '1.0';

/// The category duplicate-document groups are filed under in the
/// standalone scan's [ScanReport]. scan_engine has no duplicate-document
/// category yet and this package doesn't change scan_engine; adding one is
/// step 1 of the ruleset's merge notes. Nothing else in this scan's engine
/// run uses this category.
const documentCategoryStandIn = WasteCategory.duplicatePhoto;

/// Runs only the duplicate document deep scan on a device, together with
/// the empty & unreadable deep scan it relies on, through [ScanEngine] so
/// the storage permission gate applies as in the mass scan.
final class DuplicateDocumentScan {
  DuplicateDocumentScan({
    required this.device,
    this.rules = const DuplicateDocumentRules(),
    this.healthRules = const EmptyUnreadableRules(),
    this.scanPageRules = const DuplicatePhotoRules(),
    this.scanRules = const ScanRules(),
    this.clock,
  });

  final DeviceAdapter device;
  final DuplicateDocumentRules rules;

  /// Rules for the empty & unreadable checks that decide which documents
  /// are left out (X01–X03).
  final EmptyUnreadableRules healthRules;

  /// Thresholds for comparing scanned pages (F05).
  final DuplicatePhotoRules scanPageRules;
  final ScanRules scanRules;
  final DateTime Function()? clock;

  Future<DuplicateDocumentResult> run({
    void Function(ScanProgress)? onProgress,
    ScanCancelToken? cancelToken,
  }) async {
    final health = EmptyUnreadableAnalyzer(rules: healthRules);
    final analyzer = DuplicateDocumentAnalyzer(
        rules: rules, scanRules: scanPageRules, health: health);
    final report = await ScanEngine(
      device: device,
      rules: scanRules,
      detectors: [
        ...health.detectors(),
        analyzer.detector(documentCategoryStandIn),
      ],
      clock: clock,
    ).scan(onProgress: onProgress, cancelToken: cancelToken);
    return DuplicateDocumentResult(
      report: report,
      analysis: analyzer.lastResult ?? DuplicateDocumentAnalysis.empty,
      health: health.lastResult ?? AnalysisResult.empty,
    );
  }
}

final class DuplicateDocumentResult {
  const DuplicateDocumentResult(
      {required this.report, required this.analysis, required this.health});

  final ScanReport report;
  final DuplicateDocumentAnalysis analysis;

  /// The empty & unreadable verdicts the scan left documents out by.
  final AnalysisResult health;

  List<DocumentGroup> get groups => analysis.groups;

  Map<String, Object?> toJson() => {
        'scan': 'duplicate_documents',
        'rulesetVersion': duplicateDocumentRulesetVersion,
        'stats': {
          'filesConsidered': analysis.filesConsidered,
          'documentsCompared': analysis.documentsCompared,
          'bytesHashed': analysis.bytesHashed,
          'bytesRead': analysis.bytesRead,
          'bytesInflated': analysis.bytesInflated,
          'candidatePairs': analysis.candidatePairs,
          'matchedPairs': analysis.matchedPairs,
          'elapsedMs': analysis.elapsed.inMilliseconds,
          'healthCheckMs': health.elapsed.inMilliseconds,
          'countsByRule': analysis.countsByRule,
        },
        'groups': [for (final g in groups) g.toJson()],
        'observations': [for (final o in analysis.observations) o.toJson()],
        'emptyAndUnreadable': [for (final v in health.verdicts) v.toJson()],
        'report': report.toJson(),
      };

  String format({String? relativeTo, bool showEvidence = false}) {
    String name(String id) => relativeTo == null ? id : relPath(id, relativeTo);
    final a = analysis;
    final reclaim = groups.fold(0, (s, g) => s + g.reclaimableBytes);
    final out = StringBuffer()
      ..writeln('Duplicate document deep scan  (ruleset '
          '$duplicateDocumentRulesetVersion)')
      ..writeln('${a.filesConsidered} non-image files, ${a.documentsCompared} '
          'distinct documents looked inside; ${kb(a.bytesHashed)} hashed, '
          '${kb(a.bytesRead)} read, ${kb(a.bytesInflated)} inflated; '
          '${a.candidatePairs} pairs compared in depth, ${a.matchedPairs} '
          'matched; ${a.elapsed.inMilliseconds} ms (+ '
          '${health.elapsed.inMilliseconds} ms empty & unreadable checks)')
      ..writeln()
      ..writeln('${groups.length} groups, ${kb(reclaim)} reclaimable');
    final state = report.categories[documentCategoryStandIn];
    if (state != null && state.state != CategoryState.completed) {
      out.writeln('  [${state.state.name}: ${state.note}]');
    }
    for (final g in groups) {
      out
        ..writeln()
        ..writeln('${g.confidence.name.toUpperCase()}  ${g.reason}');
      for (final m in g.members) {
        final f = m.facts;
        final detail = [
          f.content.format.label,
          kb(m.item.sizeBytes),
          if (f.content.words.isNotEmpty) '${f.content.words.length} words',
          if (f.content.pageCount > 0) '${f.content.pageCount} pages',
          if (f.sharpness != null)
            'sharpness ${f.sharpness!.toStringAsFixed(0)}',
        ].join(', ');
        out.writeln('  ${(m.rule?.code ?? 'keep').padRight(4)}  '
            '${name(m.item.id)}  ($detail)');
        if (showEvidence && m.match != null) {
          out.writeln('        ${m.match!.evidence}');
        }
      }
    }
    if (health.verdicts.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Empty & unreadable (left to those scans):');
      for (final v in health.verdicts) {
        out.writeln('  ${v.rule.code}  ${name(v.item.id)}: ${v.reason}');
      }
    }
    if (a.observations.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Not grouped, but noted:');
      for (final o in a.observations) {
        if (o.kind == DocumentObservationKind.empty ||
            o.kind == DocumentObservationKind.unreadable) {
          continue; // Listed above.
        }
        out.writeln('  ${o.kind.name.padRight(15)} '
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

/// A planted empty, unreadable or still-being-written document: what the
/// empty & unreadable checks should say about it, and that it must stay out
/// of every duplicate group.
final class ExpectedHealth {
  const ExpectedHealth({
    required this.path,
    required this.why,
    this.rule,
    this.observation,
    this.partialCopyOf,
    this.graceEnds,
    this.ruleAfterGrace,
    this.partialAfterGrace,
  });

  factory ExpectedHealth.fromJson(Map<String, Object?> json) => ExpectedHealth(
        path: json['path']! as String,
        why: json['why'] as String? ?? '',
        rule: json['expect'] as String?,
        observation: json['observation'] as String?,
        partialCopyOf: json['partialCopyOf'] as String?,
        graceEnds: json['graceEnds'] == null
            ? null
            : DateTime.parse(json['graceEnds']! as String),
        ruleAfterGrace: json['expectAfterGrace'] as String?,
        partialAfterGrace: json['partialCopyOfAfterGrace'] as String?,
      );

  final String path;
  final String why;

  /// Expected empty/unreadable rule code (E01, U06…), or null.
  final String? rule;

  /// Expected observation kind (e.g. `beingWritten`), or null.
  final String? observation;

  /// The healthy document this one should be found to be a failed
  /// download of.
  final String? partialCopyOf;

  /// For a document that is only left out because it was just modified:
  /// when the grace period ends, and what is expected after it.
  final DateTime? graceEnds;
  final String? ruleAfterGrace;
  final String? partialAfterGrace;

  /// The expectation that applies at [now].
  ExpectedHealth at(DateTime now) =>
      graceEnds == null || now.isBefore(graceEnds!)
          ? this
          : ExpectedHealth(
              path: path,
              why: why,
              rule: ruleAfterGrace,
              partialCopyOf: partialAfterGrace);

  Map<String, Object?> toJson() => {
        'path': path,
        'why': why,
        if (rule != null) 'expect': rule,
        if (observation != null) 'observation': observation,
        if (partialCopyOf != null) 'partialCopyOf': partialCopyOf,
        if (graceEnds != null) 'graceEnds': graceEnds!.toIso8601String(),
        if (ruleAfterGrace != null) 'expectAfterGrace': ruleAfterGrace,
        if (partialAfterGrace != null)
          'partialCopyOfAfterGrace': partialAfterGrace,
      };
}

/// How one [ExpectedHealth] came out.
final class HealthOutcome {
  const HealthOutcome(this.expected,
      {this.rule,
      this.observations = const {},
      this.partialOf,
      this.grouped = false});

  final ExpectedHealth expected;
  final String? rule;
  final Set<String> observations;
  final String? partialOf;
  final bool grouped;

  bool get passed =>
      !grouped &&
      rule == expected.rule &&
      (expected.observation == null ||
          observations.contains(expected.observation)) &&
      partialOf == expected.partialCopyOf;
}

List<FoundGroup> documentGroups(DuplicateDocumentResult r, String root) => [
      for (final g in r.groups)
        FoundGroup(relPath(g.keeper.item.id, root), {
          for (final m in g.members)
            relPath(m.item.id, root): m.rule?.code ?? 'keep'
        })
    ];

List<HealthOutcome> verifyHealth(
    DuplicateDocumentResult r, List<ExpectedHealth> cases, String root,
    {required DateTime now}) {
  final verdicts = <String, FileVerdict>{
    for (final v in r.health.verdicts) relPath(v.item.id, root): v
  };
  final kinds = <String, Set<String>>{};
  final partial = <String, String>{};
  for (final o in r.analysis.observations) {
    final first = relPath(o.ids.first, root);
    (kinds[first] ??= {}).add(o.kind.name);
    if (o.kind == DocumentObservationKind.partialCopy) {
      partial[first] = relPath(o.ids[1], root);
    }
  }
  final grouped = {
    for (final g in documentGroups(r, root)) ...g.paths,
  };
  return [
    for (final c in cases.map((c) => c.at(now)))
      HealthOutcome(c,
          rule: verdicts[c.path]?.rule.code,
          observations: kinds[c.path] ?? const {},
          partialOf: partial[c.path],
          grouped: grouped.contains(c.path))
  ];
}

String formatDocumentVerification(
    GroupScore score, List<HealthOutcome> health) {
  String pct(double v) => '${(v * 100).toStringAsFixed(0)}%';
  String mark(bool ok) => ok ? '✓' : '✗';
  final out = StringBuffer();
  for (final e in score.expected) {
    final g = score.match(e);
    out.writeln('${score.passed(e) ? 'PASS' : 'FAIL'}  ${e.name}  '
        '(${e.paths.length} files)');
    final width =
        e.paths.fold(0, (w, path) => path.length > w ? path.length : w);
    for (final path in [e.keep, ...e.members.keys]) {
      final want = path == e.keep ? 'keep' : e.members[path]!;
      final got = g?.roles[path] ?? '-';
      out.writeln('  ${path.padRight(width)}  expect ${want.padRight(4)}  '
          'got ${got.padRight(4)} ${mark(want == got)}');
    }
    if (g != null) {
      for (final extra in g.paths.difference(e.paths)) {
        out.writeln('  $extra  should not be in this group ✗');
      }
    }
  }
  for (final g in score.extra) {
    out.writeln('FAIL  unexpected group: ${g.paths.join(', ')}');
  }
  final wrong = score.wronglyGrouped;
  out
    ..writeln()
    ..writeln('Look-alikes kept apart: '
        '${score.singles.length - wrong.length}/${score.singles.length}');
  for (final s in wrong) {
    out.writeln('  ✗ ${s.path} was grouped (${s.why})');
  }

  out
    ..writeln()
    ..writeln('Empty, unreadable and in-progress documents left out:');
  final width = health.fold(
      0, (w, o) => o.expected.path.length > w ? o.expected.path.length : w);
  for (final o in health) {
    final e = o.expected;
    final want = [
      e.rule ?? e.observation ?? '-',
      if (e.partialCopyOf != null) 'partial',
    ].join('+');
    final got = [
      o.rule ??
          (e.observation != null && o.observations.contains(e.observation)
              ? e.observation
              : '-'),
      if (o.partialOf != null) 'partial',
      if (o.grouped) 'GROUPED',
    ].join('+');
    out.writeln('  ${e.path.padRight(width)}  expect ${want.padRight(12)} '
        'got ${got.padRight(12)} ${mark(o.passed)}');
    if (!o.passed && e.partialCopyOf != o.partialOf) {
      out.writeln('      partial copy of: expected ${e.partialCopyOf ?? '-'}, '
          'got ${o.partialOf ?? '-'}');
    }
  }

  final passed = score.expected.where(score.passed).length;
  final healthPassed = health.where((o) => o.passed).length;
  out
    ..writeln()
    ..writeln('Deep scan: $passed/${score.expected.length} groups exactly '
        'right, ${score.extra.length} unexpected; pair precision '
        '${pct(score.precision)}, recall ${pct(score.recall)}; '
        '$healthPassed/${health.length} empty/unreadable cases right');
  return out.toString();
}

/// Whether every group, look-alike and empty/unreadable case is right.
bool allDocumentExpectationsMet(GroupScore score, List<HealthOutcome> health) =>
    score.allPassed && health.every((o) => o.passed);
