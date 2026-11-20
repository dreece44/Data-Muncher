import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:scan_engine/scan_engine.dart';

import '../empty_unreadable/bytes.dart' show indexOf;
import 'detail.dart';
import 'fingerprint.dart';
import 'matcher.dart';
import 'model.dart';
import 'rules.dart';

/// Everything one run of the duplicate photo analysis produced.
final class DuplicateAnalysis {
  const DuplicateAnalysis({
    required this.groups,
    required this.observations,
    required this.imagesConsidered,
    required this.photosCompared,
    required this.bytesHashed,
    required this.candidatePairs,
    required this.matchedPairs,
    required this.detailChecks,
    required this.decodeTime,
    required this.elapsed,
  });

  static const empty = DuplicateAnalysis(
      groups: [],
      observations: [],
      imagesConsidered: 0,
      photosCompared: 0,
      bytesHashed: 0,
      candidatePairs: 0,
      matchedPairs: 0,
      detailChecks: 0,
      decodeTime: Duration.zero,
      elapsed: Duration.zero);

  /// Largest reclaimable space first.
  final List<DuplicateGroup> groups;
  final List<PhotoObservation> observations;

  /// Image files found in storage.
  final int imagesConsidered;

  /// Distinct decoded photos that took part in matching (one per set of
  /// identical copies).
  final int photosCompared;

  /// Bytes read to find identical copies.
  final int bytesHashed;

  /// Pairs that got a full comparison, and how many matched.
  final int candidatePairs;
  final int matchedPairs;

  /// D06 matches whose photos were decoded again to compare fine detail.
  final int detailChecks;

  /// Time spent decoding (summed across parallel decodes).
  final Duration decodeTime;
  final Duration elapsed;

  Map<String, int> get countsByRule => {
        for (final rule in DuplicateRule.values)
          if (groups.any((g) => g.duplicates.any((m) => m.rule == rule)))
            rule.code: groups.fold(0,
                (s, g) => s + g.duplicates.where((m) => m.rule == rule).length),
      };
}

/// The duplicate photo deep scan's pipeline (ruleset in
/// `docs/DUPLICATE_PHOTO_RULESET.md`):
///
/// 1. identical files by size → first 64 KB hash → full SHA-256;
/// 2. decode one photo per identical set; drop blank and tiny ones;
/// 3. candidate pairs from a banded perceptual-hash index (all rotations and
///    mirrors) plus photos taken close together;
/// 4. compare each candidate pair in depth; confirm near-identical shots on
///    fine detail (photos decoded again);
/// 5. group so every member matches every other (complete linkage);
/// 6. pick the copy to keep.
final class DuplicatePhotoAnalyzer {
  DuplicatePhotoAnalyzer({this.rules = const DuplicatePhotoRules()});

  final DuplicatePhotoRules rules;
  final _runs = Expando<Future<DuplicateAnalysis>>();

  /// The most recent completed analysis.
  DuplicateAnalysis? lastResult;

  WasteDetector detector() => DeepDuplicatePhotoDetector(this);

  Future<DuplicateAnalysis> analyze(ScanContext context) =>
      _runs[context] ??= _run(context);

  static const _category = WasteCategory.duplicatePhoto;

  Future<DuplicateAnalysis> _run(ScanContext context) async {
    final clock = Stopwatch()..start();
    final source = context.source;
    final observations = <PhotoObservation>[];
    final images = [
      for (final item in context.items)
        if (item.kind == MediaKind.image) item
    ]..sort((a, b) => a.id.compareTo(b.id));

    // 1. Identical files.
    final (sets, bytesHashed) =
        rules.disabledRules.contains(DuplicateRule.d01Exact)
            ? (<List<StorageItem>>[], 0)
            : await _identicalSets(source, images, observations);
    final inSet = {
      for (final s in sets)
        for (final i in s) i.id
    };
    final units = [
      ...sets,
      for (final i in images)
        if (!inSet.contains(i.id)) [i]
    ]..sort((a, b) => a.first.id.compareTo(b.first.id));

    // 2. Decode one photo per unit.
    final fingerprints = List<PhotoFingerprint?>.filled(units.length, null);
    final identicalOnly = <List<StorageItem>>[];
    var decodeMicros = 0;
    var next = 0, done = 0;
    Future<void> worker() async {
      while (next < units.length) {
        final u = next++;
        final unit = units[u];
        final rep = unit.first;
        final ids = [for (final i in unit) i.id];
        if (!source.canDecodeThumbnail(rep)) {
          if (unit.length > 1) {
            identicalOnly.add(unit);
            observations.add(PhotoObservation(
                PhotoObservationKind.identicalOnly,
                ids,
                "can't decode .${rep.extension} here; only identical "
                'copies checked'));
          }
        } else {
          final watch = Stopwatch()..start();
          try {
            final thumb = await source.loadThumbnail(rep, rules.analysisSize);
            if (thumb == null) {
              observations.add(PhotoObservation(
                  PhotoObservationKind.undecodable,
                  ids,
                  "image data is damaged; left to the unreadable-file scan"));
            } else {
              final f = PhotoFingerprint.fromThumbnail(thumb,
                  borderMaxStdDev: rules.borderMaxStdDev,
                  borderMaxShare: rules.borderMaxShare);
              if (math.min(f.width, f.height) < rules.minPhotoDimension) {
                observations.add(PhotoObservation(PhotoObservationKind.tooSmall,
                    ids, '${f.width}×${f.height} is an icon, not a photo'));
              } else if (f.spread <= rules.blankMaxStdDev) {
                observations.add(PhotoObservation(
                    PhotoObservationKind.blank,
                    ids,
                    'flat colour (spread ${f.spread.toStringAsFixed(1)}); '
                    'left to the blank-photo scan'));
              } else {
                fingerprints[u] = f;
              }
            }
          } on StorageReadException catch (e) {
            observations.add(PhotoObservation(
                PhotoObservationKind.unreadable, ids, e.message));
          }
          decodeMicros += watch.elapsedMicroseconds;
        }
        context.tick(_category, ++done, units.length);
      }
    }

    final workers = math.min(rules.concurrency, units.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);

    final photos = [
      for (var u = 0; u < units.length; u++)
        if (fingerprints[u] != null) (unit: units[u], fp: fingerprints[u]!)
    ];

    // 3–4. Candidate pairs, compared in depth; near-identical shots are
    // confirmed on fine detail.
    final detail = ShotDetailCheck(source, rules);
    final fps = [for (final p in photos) p.fp];
    final pairs = hashCandidates(
        fps, math.max(rules.copyHashDistance, rules.shotHashDistance))
      ..addAll(_closeInTime(photos.map((p) => p.unit.first).toList()));
    final edges = <(int, int), PairCheck>{};
    for (final (a, b) in pairs) {
      context.throwIfCancelled();
      final itemA = photos[a].unit.first, itemB = photos[b].unit.first;
      final blocked = _shotBlocked(itemA, itemB);
      var check = comparePhotos(fps[a], fps[b], rules,
          shotAllowed: blocked == null,
          bothOriginals:
              photos[a].unit.any(_firsthand) && photos[b].unit.any(_firsthand),
          shotBlockedReason: blocked);
      if (check == null) continue;
      final ids = [itemA.id, itemB.id];
      if (check.matched && rules.disabledRules.contains(check.rule)) {
        observations.add(PhotoObservation(PhotoObservationKind.dropped, ids,
            '${check.rule!.code} is disabled (${check.evidence})'));
      } else if (check.matched) {
        if (check.rule == DuplicateRule.d06SimilarShot &&
            rules.shotDetailAgreement > -1) {
          final agreement = await detail.agreement(itemA, itemB);
          if (agreement == null || agreement < rules.shotDetailAgreement) {
            observations.add(PhotoObservation(
                PhotoObservationKind.detailDiffers,
                ids,
                agreement == null
                    ? "near-identical shots (${check.evidence}) but couldn't "
                        'be decoded again to compare fine detail'
                    : 'near-identical layout (${check.evidence}) but the fine '
                        'detail differs (agreement '
                        '${agreement.toStringAsFixed(3)} < '
                        '${rules.shotDetailAgreement}): a different subject'));
            continue;
          }
          check = check.withDetail(agreement);
        }
        edges[(a, b)] = check;
      } else if (check.correlation >= rules.shotCorrelation - 0.05) {
        observations.add(PhotoObservation(PhotoObservationKind.nearMiss, ids,
            '${check.note}: ${check.evidence}'));
      }
    }

    // 5. Groups in which every photo matches every other.
    final clusters = _cluster(photos.length, edges, photos, observations);

    // 6. Keeper and members.
    final groups = <DuplicateGroup>[];
    for (final cluster in clusters) {
      final units = [for (final i in cluster) photos[i].unit];
      if (units.fold(0, (n, u) => n + u.length) < 2) continue;
      final shots = edges.entries.any((e) =>
          e.value.rule == DuplicateRule.d06SimilarShot &&
          cluster.contains(e.key.$1) &&
          cluster.contains(e.key.$2));
      final group = await _group(
          source,
          shots,
          [
            for (final i in cluster)
              for (final item in photos[i].unit) (index: i, item: item)
          ],
          (i) => photos[i].fp,
          (a, b) => edges[a < b ? (a, b) : (b, a)],
          observations);
      if (group != null) groups.add(group);
    }
    for (final unit in identicalOnly) {
      final group = await _group(
          source,
          false,
          [for (final item in unit) (index: -1, item: item)],
          (_) => null,
          (_, __) => null,
          observations);
      if (group != null) groups.add(group);
    }
    groups.sort((a, b) {
      final bySpace = b.reclaimableBytes.compareTo(a.reclaimableBytes);
      return bySpace != 0
          ? bySpace
          : a.keeper.item.id.compareTo(b.keeper.item.id);
    });

    return lastResult = DuplicateAnalysis(
      groups: groups,
      observations: observations
        ..sort((a, b) => a.ids.first.compareTo(b.ids.first)),
      imagesConsidered: images.length,
      photosCompared: photos.length,
      bytesHashed: bytesHashed,
      candidatePairs: pairs.length,
      matchedPairs: edges.length,
      detailChecks: detail.checks,
      decodeTime: Duration(microseconds: decodeMicros),
      elapsed: clock.elapsed,
    );
  }

  /// Sets of byte-identical image files: same size, then same first 64 KB,
  /// then same SHA-256. Only same-size files are ever read.
  Future<(List<List<StorageItem>>, int)> _identicalSets(StorageSource source,
      List<StorageItem> images, List<PhotoObservation> observations) async {
    var bytes = 0;
    final bySize = <int, List<StorageItem>>{};
    for (final i in images) {
      if (i.sizeBytes >= rules.exactMinBytes && source.canReadContent(i)) {
        (bySize[i.sizeBytes] ??= []).add(i);
      }
    }
    Future<Map<String, List<StorageItem>>> split(List<StorageItem> items,
        Future<String> Function(StorageItem) digest) async {
      final out = <String, List<StorageItem>>{};
      for (final i in items) {
        try {
          (out[await digest(i)] ??= []).add(i);
        } on StorageReadException catch (e) {
          observations.add(PhotoObservation(
              PhotoObservationKind.unreadable, [i.id], e.message));
        }
      }
      return out;
    }

    final sets = <List<StorageItem>>[];
    for (final same in bySize.values.where((s) => s.length > 1)) {
      final size = same.first.sizeBytes;
      final prefixLength = math.min(size, rules.exactPrefixBytes);
      final byPrefix = await split(same, (i) async {
        bytes += prefixLength;
        return sha256
            .convert(await source.readRange(i, 0, prefixLength))
            .toString();
      });
      for (final candidates in byPrefix.values.where((s) => s.length > 1)) {
        if (size <= rules.exactPrefixBytes) {
          sets.add(candidates);
          continue;
        }
        final byContent = await split(candidates, (i) async {
          bytes += size;
          return (await sha256.bind(source.openRead(i)).first).toString();
        });
        sets.addAll(byContent.values.where((s) => s.length > 1));
      }
    }
    return (sets, bytes);
  }

  /// Pairs of photos taken within [DuplicatePhotoRules.shotTimeWindow] of
  /// each other: the only pairs that can be near-identical shots.
  Set<(int, int)> _closeInTime(List<StorageItem> reps) {
    final timed = [
      for (var i = 0; i < reps.length; i++)
        if (reps[i].modified != null && !_isScreenshot(reps[i])) i
    ]..sort((a, b) => reps[a].modified!.compareTo(reps[b].modified!));
    final pairs = <(int, int)>{};
    for (var x = 0; x < timed.length; x++) {
      for (var y = x + 1; y < timed.length; y++) {
        final a = timed[x], b = timed[y];
        if (reps[b].modified!.difference(reps[a].modified!) >
            rules.shotTimeWindow) {
          break;
        }
        pairs.add(a < b ? (a, b) : (b, a));
      }
    }
    return pairs;
  }

  /// Why two photos can't be shots of the same moment, or null if they can.
  String? _shotBlocked(StorageItem a, StorageItem b) {
    if (_isScreenshot(a) || _isScreenshot(b)) {
      return 'screenshots are never near-identical shots';
    }
    final ta = a.modified, tb = b.modified;
    if (ta == null || tb == null) return 'no time taken to compare';
    final gap = ta.difference(tb).abs();
    if (gap > rules.shotTimeWindow) {
      return 'similar, but taken ${_duration(gap)} apart';
    }
    return null;
  }

  bool _isScreenshot(StorageItem item) =>
      item.displayName.toLowerCase().startsWith('screenshot') ||
      _folders(item).any(rules.screenshotFolders.contains);

  static List<String> _folders(StorageItem item) {
    final parts = (item.path ?? item.id).toLowerCase().split(RegExp(r'[/\\]'));
    return parts.sublist(0, parts.length - 1);
  }

  /// Complete-linkage clustering inside each connected set of matches: two
  /// clusters merge only if every photo in one matches every photo in the
  /// other, most alike first. Stops chains of gradually changing shots
  /// becoming one group, and doesn't depend on file order.
  List<List<int>> _cluster(
      int n,
      Map<(int, int), PairCheck> edges,
      List<({List<StorageItem> unit, PhotoFingerprint fp})> photos,
      List<PhotoObservation> observations) {
    final parent = List<int>.generate(n, (i) => i);
    int find(int i) => parent[i] == i ? i : parent[i] = find(parent[i]);
    for (final (a, b) in edges.keys) {
      parent[find(a)] = find(b);
    }
    final components = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      (components[find(i)] ??= []).add(i);
    }

    final out = <List<int>>[];
    for (final component in components.values) {
      if (component.length == 1 || component.length > rules.maxClusterSize) {
        out.add(component);
        continue;
      }
      var clusters = [
        for (final i in component) [i]
      ];
      while (true) {
        (int, int)? best;
        var bestScore = -2.0;
        for (var x = 0; x < clusters.length; x++) {
          for (var y = x + 1; y < clusters.length; y++) {
            var score = 2.0;
            for (final a in clusters[x]) {
              for (final b in clusters[y]) {
                final e = edges[a < b ? (a, b) : (b, a)];
                score = e == null ? -3 : math.min(score, e.correlation);
              }
            }
            if (score > bestScore) {
              bestScore = score;
              best = (x, y);
            }
          }
        }
        if (best == null || bestScore < -1) break;
        final (x, y) = best;
        clusters = [
          for (var k = 0; k < clusters.length; k++)
            if (k != x && k != y) clusters[k],
          [...clusters[x], ...clusters[y]],
        ];
      }
      if (clusters.length > 1) {
        observations.add(PhotoObservation(
            PhotoObservationKind.split,
            [for (final i in component) photos[i].unit.first.id],
            'linked by a chain of matches but not all alike; split into '
            '${clusters.length} groups'));
      }
      out.addAll(clusters);
    }
    return out;
  }

  static final _copyName =
      RegExp(r'\(\d+\)|\bcopy\b|-WA\d+|[_-]edited', caseSensitive: false);

  /// Not in a second-hand folder and not named like a copy.
  bool _firsthand(StorageItem item) =>
      !_folders(item).any(rules.secondhandFolders.contains) &&
      !_copyName.hasMatch(item.displayName);

  Future<DuplicateGroup?> _group(
      StorageSource source,
      bool shotGroup,
      List<({int index, StorageItem item})> entries,
      PhotoFingerprint? Function(int index) fingerprintOf,
      PairCheck? Function(int a, int b) edge,
      List<PhotoObservation> observations) async {
    final facts = <String, PhotoFacts>{};
    for (final e in entries) {
      facts[e.item.id] = PhotoFacts(
        item: e.item,
        fingerprint: e.index < 0 ? null : fingerprintOf(e.index),
        hasCameraDetails: await _cameraDetails(source, e.item),
        secondhand: _folders(e.item).any(rules.secondhandFolders.contains),
        copyName: _copyName.hasMatch(e.item.displayName),
      );
    }

    // K01 (shots only): sharp enough; then K02–K07. Sharpness can't rank
    // copies: heavy JPEG compression on a small copy adds edges and makes
    // it measure sharper than the original.
    final all = facts.values.toList();
    final sharpest = all.map((f) => f.sharpness).reduce(math.max);
    final eligible = [
      for (final f in all)
        if (!shotGroup ||
            f.fingerprint == null ||
            f.sharpness >= sharpest * rules.keepSharpnessShare)
          f
    ]..sort((a, b) => _keeperOrder(a, b, shotGroup: shotGroup));
    final keep = eligible.first;
    final keepIndex =
        entries.firstWhere((e) => e.item.id == keep.item.id).index;

    final members = [DuplicateMember(keep, null)];
    for (final e in entries) {
      if (e.item.id == keep.item.id) continue;
      final f = facts[e.item.id]!;
      final check = e.index == keepIndex ? null : edge(e.index, keepIndex);
      final rule = e.index == keepIndex
          ? DuplicateRule.d01Exact
          : check?.rule ?? DuplicateRule.d06SimilarShot;
      if (!rule.confidence.atLeast(rules.minConfidence)) {
        observations.add(PhotoObservation(PhotoObservationKind.dropped,
            [e.item.id], '${rule.code} is ${rule.confidence.name}'));
        continue;
      }
      members.add(DuplicateMember(f, rule, check));
    }
    if (members.length < 2) return null;
    members.sort((a, b) => a.isKeeper
        ? -1
        : b.isKeeper
            ? 1
            : a.item.id.compareTo(b.item.id));
    return DuplicateGroup(members, _keepReason(keep, all, sharpest, shotGroup));
  }

  /// K02–K07: most pixels, camera details, not a second-hand folder, not a
  /// copy-looking name, largest file, oldest, then path. In a group of
  /// shots, oldest comes before largest: the first of equally sharp shots is
  /// the one the user meant, and size there mostly measures sensor noise.
  static int _keeperOrder(PhotoFacts a, PhotoFacts b,
      {required bool shotGroup}) {
    int flag(bool x) => x ? 1 : 0;
    final bySize = b.item.sizeBytes.compareTo(a.item.sizeBytes);
    final byAge = (a.item.modified ?? DateTime(9999))
        .compareTo(b.item.modified ?? DateTime(9999));
    final steps = [
      b.pixels.compareTo(a.pixels),
      flag(b.hasCameraDetails).compareTo(flag(a.hasCameraDetails)),
      flag(a.secondhand).compareTo(flag(b.secondhand)),
      flag(a.copyName).compareTo(flag(b.copyName)),
      shotGroup ? byAge : bySize,
      shotGroup ? bySize : byAge,
      a.item.id.compareTo(b.item.id),
    ];
    return steps.firstWhere((s) => s != 0, orElse: () => 0);
  }

  String _keepReason(
      PhotoFacts keep, List<PhotoFacts> all, double sharpest, bool shotGroup) {
    final others = all.where((f) => f.item.id != keep.item.id);
    final reasons = [
      if (shotGroup &&
          others.any((f) =>
              f.fingerprint != null &&
              f.sharpness < sharpest * rules.keepSharpnessShare))
        'sharpest',
      if (keep.fingerprint != null && others.any((f) => f.pixels < keep.pixels))
        'highest resolution, ${keep.dimensions}',
      if (keep.hasCameraDetails && others.any((f) => !f.hasCameraDetails))
        'has camera details',
      if (!keep.secondhand && others.any((f) => f.secondhand))
        'original location',
    ];
    if (reasons.isEmpty) {
      return shotGroup ? 'first of equally sharp shots' : 'oldest copy';
    }
    return reasons.join(', ');
  }

  /// Whether the file carries EXIF camera metadata (JPEG APP1 "Exif",
  /// PNG eXIf chunk, or an Exif item in HEIC), judged from its first 64 KB.
  Future<bool> _cameraDetails(StorageSource source, StorageItem item) async {
    if (!source.canReadContent(item)) return false;
    try {
      final head = await source.readRange(item, 0, 64 * 1024);
      return indexOf(head, 'Exif\x00\x00'.codeUnits) >= 0 ||
          indexOf(head, 'eXIf'.codeUnits) >= 0;
    } on StorageReadException {
      return false;
    }
  }

  static String _duration(Duration d) => d.inDays >= 1
      ? '${d.inDays} day${d.inDays == 1 ? '' : 's'}'
      : d.inHours >= 1
          ? '${d.inHours} h'
          : '${d.inMinutes} min';
}

/// Duplicate photos, as found by the deep scan. Drop-in alternative to the
/// mass scan's `DuplicatePhotoDetector`.
final class DeepDuplicatePhotoDetector extends WasteDetector {
  const DeepDuplicatePhotoDetector(this.analyzer);

  final DuplicatePhotoAnalyzer analyzer;

  @override
  WasteCategory get category => WasteCategory.duplicatePhoto;

  @override
  Future<List<Finding>> detect(ScanContext context) async =>
      [for (final g in (await analyzer.analyze(context)).groups) g.toFinding()];
}
