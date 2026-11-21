import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

import '../empty_unreadable/bytes.dart' show kb;
import 'analyzer.dart';
import 'model.dart';
import 'rules.dart';

/// Version of the ruleset in `docs/DUPLICATE_PHOTO_RULESET.md`.
const duplicatePhotoRulesetVersion = '1.1';

/// Runs only the duplicate photo deep scan on a device, through
/// [ScanEngine] so the storage permission gate applies as in the mass scan.
final class DuplicatePhotoScan {
  DuplicatePhotoScan({
    required this.device,
    this.rules = const DuplicatePhotoRules(),
    this.scanRules = const ScanRules(),
    this.clock,
  });

  final DeviceAdapter device;
  final DuplicatePhotoRules rules;
  final ScanRules scanRules;
  final DateTime Function()? clock;

  Future<DuplicatePhotoResult> run({
    void Function(ScanProgress)? onProgress,
    ScanCancelToken? cancelToken,
  }) async {
    final analyzer = DuplicatePhotoAnalyzer(rules: rules);
    final report = await ScanEngine(
      device: device,
      rules: scanRules,
      detectors: [analyzer.detector()],
      clock: clock,
    ).scan(onProgress: onProgress, cancelToken: cancelToken);
    return DuplicatePhotoResult(
        report: report,
        analysis: analyzer.lastResult ?? DuplicateAnalysis.empty);
  }
}

final class DuplicatePhotoResult {
  const DuplicatePhotoResult({required this.report, required this.analysis});

  final ScanReport report;
  final DuplicateAnalysis analysis;

  List<DuplicateGroup> get groups => analysis.groups;

  Map<String, Object?> toJson() => {
        'scan': 'duplicate_photos',
        'rulesetVersion': duplicatePhotoRulesetVersion,
        'stats': {
          'imagesConsidered': analysis.imagesConsidered,
          'photosCompared': analysis.photosCompared,
          'bytesHashed': analysis.bytesHashed,
          'candidatePairs': analysis.candidatePairs,
          'matchedPairs': analysis.matchedPairs,
          'detailChecks': analysis.detailChecks,
          'decodeMs': analysis.decodeTime.inMilliseconds,
          'elapsedMs': analysis.elapsed.inMilliseconds,
          'countsByRule': analysis.countsByRule,
        },
        'groups': [for (final g in groups) g.toJson()],
        'observations': [for (final o in analysis.observations) o.toJson()],
        'report': report.toJson(),
      };

  String format({String? relativeTo, bool showEvidence = false}) {
    String name(String id) => relativeTo == null ? id : relPath(id, relativeTo);
    final a = analysis;
    final reclaim = groups.fold(0, (s, g) => s + g.reclaimableBytes);
    final out = StringBuffer()
      ..writeln('Duplicate photo deep scan  (ruleset '
          '$duplicatePhotoRulesetVersion)')
      ..writeln('${a.imagesConsidered} images, ${a.photosCompared} distinct '
          'photos compared; ${kb(a.bytesHashed)} hashed; '
          '${a.candidatePairs} pairs checked, ${a.matchedPairs} matched '
          '(${a.detailChecks} shot pairs checked on fine detail); '
          '${a.elapsed.inMilliseconds} ms '
          '(decoding ${a.decodeTime.inMilliseconds} ms across threads)')
      ..writeln()
      ..writeln('${groups.length} groups, ${kb(reclaim)} reclaimable');
    final state = report.categories[WasteCategory.duplicatePhoto];
    if (state != null && state.state != CategoryState.completed) {
      out.writeln('  [${state.state.name}: ${state.note}]');
    }
    for (final g in groups) {
      out
        ..writeln()
        ..writeln('${g.confidence.name.toUpperCase()}  ${g.reason}');
      for (final m in g.members) {
        final f = m.facts;
        final sharp = f.fingerprint == null
            ? ''
            : '  sharpness ${f.sharpness.toStringAsFixed(0)}';
        out.writeln('  ${(m.rule?.code ?? 'keep').padRight(4)}  '
            '${name(m.item.id)}  (${f.dimensions}, ${kb(m.item.sizeBytes)}'
            '$sharp${f.hasCameraDetails ? ', camera details' : ''})');
        if (showEvidence && m.check != null) {
          out.writeln('        ${m.check!.evidence}');
        }
      }
    }
    if (a.observations.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Not grouped, but noted:');
      for (final o in a.observations) {
        out.writeln('  ${o.kind.name.padRight(13)} '
            '${o.ids.map(name).join(' + ')}: ${o.detail}');
      }
    }
    for (final issue in report.issues) {
      out.writeln('Issue: $issue');
    }
    return out.toString();
  }
}

String relPath(String id, String root) => p.isWithin(root, id)
    ? p.relative(id, from: root).replaceAll(r'\', '/')
    : id;

/// Runs the mass scan's existing `DuplicatePhotoDetector` on [device], for
/// side-by-side comparison.
Future<List<Finding>> massScanDuplicates(DeviceAdapter device,
        {ScanRules rules = const ScanRules()}) async =>
    (await ScanEngine(
            device: device,
            rules: rules,
            detectors: const [DuplicatePhotoDetector()]).scan())
        .findings;

// --- Expectations ---------------------------------------------------------

/// One group a test area expects to be found.
final class ExpectedGroup {
  const ExpectedGroup(
      {required this.name,
      required this.keep,
      required this.members,
      this.why = ''});

  factory ExpectedGroup.fromJson(Map<String, Object?> json) => ExpectedGroup(
        name: json['name']! as String,
        keep: json['keep']! as String,
        members: (json['members']! as Map).cast<String, String>(),
        why: json['why'] as String? ?? '',
      );

  final String name;

  /// Path of the photo that should be kept.
  final String keep;

  /// Every other member: path → expected rule code.
  final Map<String, String> members;
  final String why;

  Set<String> get paths => {keep, ...members.keys};

  Map<String, Object?> toJson() =>
      {'name': name, 'why': why, 'keep': keep, 'members': members};
}

/// A photo that must not be in any group.
final class ExpectedSingle {
  const ExpectedSingle(this.path, this.why);
  factory ExpectedSingle.fromJson(Map<String, Object?> json) =>
      ExpectedSingle(json['path']! as String, json['why'] as String? ?? '');
  final String path;
  final String why;
  Map<String, Object?> toJson() => {'path': path, 'why': why};
}

/// A found group as plain paths, so deep and mass results compare alike.
final class FoundGroup {
  const FoundGroup(this.keep, this.roles);
  final String? keep;

  /// Path → rule code (or 'keep'); the mass scan has no rule codes, so its
  /// non-keepers are '?'.
  final Map<String, String> roles;
  Set<String> get paths => roles.keys.toSet();
}

List<FoundGroup> deepGroups(DuplicatePhotoResult r, String root) => [
      for (final g in r.groups)
        FoundGroup(relPath(g.keeper.item.id, root), {
          for (final m in g.members)
            relPath(m.item.id, root): m.rule?.code ?? 'keep'
        })
    ];

List<FoundGroup> massGroups(List<Finding> findings, String root) => [
      for (final f in findings)
        FoundGroup(f.keep == null ? null : relPath(f.keep!.id, root), {
          for (final i in f.items)
            relPath(i.id, root): i.id == f.keep?.id ? 'keep' : '?'
        })
    ];

/// How well a set of found groups matches the expectations.
final class GroupScore {
  GroupScore(this.expected, this.singles, this.found);

  final List<ExpectedGroup> expected;
  final List<ExpectedSingle> singles;
  final List<FoundGroup> found;

  FoundGroup? match(ExpectedGroup e) {
    for (final g in found) {
      if (g.paths.intersection(e.paths).isNotEmpty) return g;
    }
    return null;
  }

  bool membersRight(ExpectedGroup e) =>
      _setEquals(match(e)?.paths ?? const {}, e.paths);
  bool keeperRight(ExpectedGroup e) => match(e)?.keep == e.keep;
  bool rulesRight(ExpectedGroup e) {
    final g = match(e);
    return g != null &&
        e.members.entries.every((m) => g.roles[m.key] == m.value);
  }

  /// Fully right: same members, same keeper, same rule for every member.
  bool passed(ExpectedGroup e) =>
      membersRight(e) && keeperRight(e) && rulesRight(e);

  /// Groups that don't overlap any expected group.
  List<FoundGroup> get extra => [
        for (final g in found)
          if (!expected.any((e) => g.paths.intersection(e.paths).isNotEmpty)) g
      ];

  List<ExpectedSingle> get wronglyGrouped => [
        for (final s in singles)
          if (found.any((g) => g.paths.contains(s.path))) s
      ];

  Set<(String, String)> _pairs(Iterable<Set<String>> groups) => {
        for (final g in groups)
          for (final a in g)
            for (final b in g)
              if (a.compareTo(b) < 0) (a, b)
      };

  /// Share of grouped pairs that really are duplicates.
  double get precision {
    final f = _pairs(found.map((g) => g.paths));
    if (f.isEmpty) return 1;
    return f.intersection(_pairs(expected.map((e) => e.paths))).length /
        f.length;
  }

  /// Share of real duplicate pairs that were grouped.
  double get recall {
    final e = _pairs(expected.map((e) => e.paths));
    if (e.isEmpty) return 1;
    return e.intersection(_pairs(found.map((g) => g.paths))).length / e.length;
  }

  bool get allPassed =>
      expected.every(passed) && extra.isEmpty && wronglyGrouped.isEmpty;
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

String formatGroupVerification(GroupScore deep, {GroupScore? mass}) {
  String pct(double v) => '${(v * 100).toStringAsFixed(0)}%';
  String mark(bool ok) => ok ? '✓' : '✗';
  final out = StringBuffer();
  for (final e in deep.expected) {
    final g = deep.match(e);
    out.writeln('${deep.passed(e) ? 'PASS' : 'FAIL'}  ${e.name}  '
        '(${e.paths.length} photos)'
        '${mass == null ? '' : '   mass scan: members ${mark(mass.membersRight(e))} keeper ${mark(mass.keeperRight(e))}'}');
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
  for (final g in deep.extra) {
    out.writeln('FAIL  unexpected group: ${g.paths.join(', ')}');
  }
  final wrong = deep.wronglyGrouped;
  out
    ..writeln()
    ..writeln('Singles kept apart: '
        '${deep.singles.length - wrong.length}/${deep.singles.length}'
        '${mass == null ? '' : '   (mass scan: ${mass.singles.length - mass.wronglyGrouped.length}/${mass.singles.length})'}');
  for (final s in wrong) {
    out.writeln('  ✗ ${s.path} was grouped (${s.why})');
  }
  final passed = deep.expected.where(deep.passed).length;
  out
    ..writeln()
    ..writeln('Deep scan: $passed/${deep.expected.length} groups exactly '
        'right, ${deep.extra.length} unexpected; pair precision '
        '${pct(deep.precision)}, recall ${pct(deep.recall)}');
  if (mass != null) {
    final members = mass.expected.where(mass.membersRight).length;
    final keepers = mass.expected.where(mass.keeperRight).length;
    out.writeln('Mass scan (DuplicatePhotoDetector): $members/'
        '${mass.expected.length} groups with the right members, $keepers '
        'with the right keeper, ${mass.extra.length} unexpected; pair '
        'precision ${pct(mass.precision)}, recall ${pct(mass.recall)}');
  }
  return out.toString();
}
