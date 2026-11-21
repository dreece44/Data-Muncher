import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// DAT-34 (PB-21): duplicate grouping with best-copy suggestion.
///
/// Photos that are copies of each other (same picture hash), or shots of the
/// same moment taken seconds apart (nearly the same hash), are grouped. In
/// each group the clearest, most centred copy is suggested as the one to
/// keep, so the user can drop the rest in one action.

/// How good one photo is, measured on its scan thumbnail.
class PhotoQuality {
  const PhotoQuality({required this.clarity, required this.centering});

  /// Side the thumbnail is reduced to before measuring, so every photo in a
  /// group is measured at the same scale.
  static const int sample = 128;

  /// How crisp the fine detail is: variance of the Laplacian divided by the
  /// variance of brightness. Dividing by brightness spread means a copy that
  /// was only made brighter or more contrasty doesn't count as sharper.
  /// Higher is clearer; 0 for a flat image.
  final double clarity;

  /// 0–1: how close the centre of the photo's detail is to the centre of the
  /// frame. 1 when the subject is centred, 0 when all the detail sits at an
  /// edge (subject cut off or the camera pointed off to the side).
  final double centering;

  /// Measures [im] (any size, colour or greyscale).
  factory PhotoQuality.fromImage(img.Image im) {
    const n = sample;
    final small = img.copyResize(img.grayscale(im),
        width: n, height: n, interpolation: img.Interpolation.average);
    final luma = List<double>.generate(
        n * n, (i) => small.getPixel(i % n, i ~/ n).luminance.toDouble());
    double at(int x, int y) => luma[y * n + x];

    // Brightness spread.
    final mean = luma.reduce((a, b) => a + b) / luma.length;
    final spread =
        luma.fold<double>(0, (t, v) => t + (v - mean) * (v - mean)) / luma.length;

    // Laplacian variance (clarity) and gradient-weighted centroid (centering).
    var lapSum = 0.0, lapSquares = 0.0, count = 0;
    var weight = 0.0, cx = 0.0, cy = 0.0;
    for (var y = 1; y < n - 1; y++) {
      for (var x = 1; x < n - 1; x++) {
        final lap = at(x - 1, y) + at(x + 1, y) + at(x, y - 1) + at(x, y + 1) - 4 * at(x, y);
        lapSum += lap;
        lapSquares += lap * lap;
        count++;
        final g = (at(x + 1, y) - at(x - 1, y)).abs() + (at(x, y + 1) - at(x, y - 1)).abs();
        weight += g;
        cx += g * x;
        cy += g * y;
      }
    }
    final lapMean = lapSum / count;
    final lapVariance = lapSquares / count - lapMean * lapMean;
    final clarity = spread < 1 ? 0.0 : math.max(0.0, lapVariance) / spread;

    var centering = 1.0;
    if (weight > 0) {
      // Offset from the centre in units of half the frame: 0 at the centre,
      // 1 at the middle of an edge.
      final half = (n - 1) / 2;
      final dx = (cx / weight - half) / half, dy = (cy / weight - half) / half;
      centering = (1 - math.sqrt(dx * dx + dy * dy)).clamp(0.0, 1.0);
    }
    return PhotoQuality(clarity: clarity, centering: centering);
  }

  @override
  String toString() =>
      'PhotoQuality(clarity ${clarity.toStringAsFixed(3)}, centering ${centering.toStringAsFixed(3)})';
}

/// One photo or video the duplicate grouping looks at.
class DuplicateCandidate {
  const DuplicateCandidate({
    required this.id,
    required this.hash,
    this.quality,
    this.width = 0,
    this.height = 0,
    this.taken,
    this.isVideo = false,
    this.durationSec = 0,
  });

  final String id;

  /// 64-bit difference hash of the thumbnail (see [hashFromBits]).
  final int hash;

  /// Null for videos and photos that couldn't be measured.
  final PhotoQuality? quality;

  /// Size of the original, in pixels (0 if unknown).
  final int width, height;

  /// When it was taken (or created); null if unknown.
  final DateTime? taken;

  final bool isVideo;
  final int durationSec;

  int get pixels => width * height;
}

/// Turns the classifier's `'0'/'1'` hash string into a 64-bit int.
int hashFromBits(String bits) {
  var h = 0;
  for (var i = 0; i < bits.length; i++) {
    h = (h << 1) | (bits.codeUnitAt(i) == 0x31 ? 1 : 0);
  }
  return h;
}

/// Number of bits that differ between two hashes.
int hashDistance(int a, int b) {
  var x = a ^ b, count = 0;
  while (x != 0) {
    x &= x - 1; // Clears the lowest set bit.
    count++;
  }
  return count;
}

/// Thresholds for grouping and for picking the best copy.
class DuplicateGroupRules {
  const DuplicateGroupRules({
    this.shotHashDistance = 6,
    this.shotWindow = const Duration(minutes: 3),
    this.aspectTolerance = 0.03,
    this.clarityWeight = 0.6,
    this.centeringWeight = 0.25,
    this.resolutionWeight = 0.15,
    this.tieMargin = 0.02,
  });

  /// Two photos with exactly the same hash are copies, whenever they were
  /// taken. Photos up to this many bits apart (of 64) are shots of the same
  /// moment, but only when taken within [shotWindow] of each other and with
  /// the same shape: the same view on another day is a different photo.
  final int shotHashDistance;
  final Duration shotWindow;

  /// Width/height may differ by at most this share for near-identical shots.
  final double aspectTolerance;

  /// How the best copy is scored: clarity against the group's clearest,
  /// centring, and resolution against the group's largest. Sum to 1.
  final double clarityWeight, centeringWeight, resolutionWeight;

  /// Scores this close to the top count as a tie, broken by resolution,
  /// then the oldest, then the id, so identical copies keep the original.
  final double tieMargin;
}

/// A set of duplicates with one copy suggested to keep.
class DuplicateGroup {
  DuplicateGroup._(this.members, this.bestId, this.reason, this.scores);

  /// Builds a group from [members] (two or more) and picks the best copy.
  factory DuplicateGroup.of(List<DuplicateCandidate> members,
      [DuplicateGroupRules rules = const DuplicateGroupRules()]) {
    assert(members.length >= 2);
    final scores = scoreCopies(members, rules);
    final top = scores.values.reduce(math.max);
    final tied = members.where((m) => scores[m.id]! >= top - rules.tieMargin).toList()
      ..sort((a, b) {
        final byPixels = b.pixels.compareTo(a.pixels);
        if (byPixels != 0) return byPixels;
        final byAge = (a.taken ?? DateTime(9999)).compareTo(b.taken ?? DateTime(9999));
        return byAge != 0 ? byAge : a.id.compareTo(b.id);
      });
    final best = tied.first;
    final ordered = [best, ...members.where((m) => m.id != best.id)];
    return DuplicateGroup._(
        List.unmodifiable(ordered), best.id, _reason(best, ordered.skip(1)), Map.unmodifiable(scores));
  }

  /// Best copy first, then the rest in the order they were taken.
  final List<DuplicateCandidate> members;

  /// The copy suggested to keep.
  final String bestId;

  /// Why [bestId] was suggested, e.g. "sharpest, best centred".
  final String reason;

  /// Each member's score, 0–1 (higher is better).
  final Map<String, double> scores;

  DuplicateCandidate get best => members.first;
  Iterable<DuplicateCandidate> get others => members.skip(1);
  List<String> get ids => [for (final m in members) m.id];

  /// This group without [removed] (for example once they're in the bin),
  /// with the best copy picked again; null when fewer than two are left.
  DuplicateGroup? without(Set<String> removed,
      [DuplicateGroupRules rules = const DuplicateGroupRules()]) {
    final left = [for (final m in members) if (!removed.contains(m.id)) m];
    if (left.length == members.length) return this;
    return left.length < 2 ? null : DuplicateGroup.of(left, rules);
  }

  static String _reason(DuplicateCandidate best, Iterable<DuplicateCandidate> others) {
    final q = best.quality;
    final reasons = [
      if (q != null &&
          others.any((o) => o.quality != null && o.quality!.clarity < q.clarity * 0.9) &&
          others.every((o) => (o.quality?.clarity ?? 0) <= q.clarity))
        'sharpest',
      if (q != null &&
          others.any((o) => o.quality != null && o.quality!.centering < q.centering - 0.05) &&
          others.every((o) => (o.quality?.centering ?? 0) <= q.centering))
        'best centred',
      if (best.pixels > 0 && others.any((o) => o.pixels < best.pixels)) 'highest resolution',
    ];
    if (reasons.isNotEmpty) return reasons.join(', ');
    return best.isVideo ? 'oldest copy' : 'as clear as the others; oldest copy';
  }
}

/// Each copy's score, 0–1: clarity relative to the clearest in the group,
/// how centred it is, and resolution relative to the largest. Videos and
/// photos without a [PhotoQuality] are scored on resolution alone.
Map<String, double> scoreCopies(List<DuplicateCandidate> members,
    [DuplicateGroupRules rules = const DuplicateGroupRules()]) {
  final clearest = members.map((m) => m.quality?.clarity ?? 0).reduce(math.max);
  final largest = members.map((m) => m.pixels).reduce(math.max);
  return {
    for (final m in members)
      m.id: (clearest > 0 ? rules.clarityWeight * (m.quality?.clarity ?? 0) / clearest : 0) +
          rules.centeringWeight * (m.quality?.centering ?? 0) +
          (largest > 0 ? rules.resolutionWeight * m.pixels / largest : rules.resolutionWeight),
  };
}

/// Groups [candidates] into sets of duplicates, each with a best copy.
///
/// Copies: same media type, same video length, identical hash. Shots of the
/// same moment (photos only): hashes at most [DuplicateGroupRules.shotHashDistance]
/// apart, taken within [DuplicateGroupRules.shotWindow], same shape. Every
/// member of a group matches every other member, so a slow pan through a
/// burst doesn't chain unrelated frames together. Largest groups first.
List<DuplicateGroup> groupDuplicates(List<DuplicateCandidate> candidates,
    [DuplicateGroupRules rules = const DuplicateGroupRules()]) {
  final n = candidates.length;
  final edges = <int, Set<int>>{};
  void link(int a, int b) {
    (edges[a] ??= {}).add(b);
    (edges[b] ??= {}).add(a);
  }

  String kind(DuplicateCandidate c) => c.isVideo ? 'video-${c.durationSec}' : 'image';

  // Copies: identical hash and kind, at any time.
  final byHash = <String, List<int>>{};
  for (var i = 0; i < n; i++) {
    (byHash['${kind(candidates[i])}-${candidates[i].hash}'] ??= []).add(i);
  }
  for (final same in byHash.values) {
    for (var x = 0; x < same.length; x++) {
      for (var y = x + 1; y < same.length; y++) {
        link(same[x], same[y]);
      }
    }
  }

  // Shots of the same moment: only photos taken close together are compared.
  final timed = [
    for (var i = 0; i < n; i++)
      if (!candidates[i].isVideo && candidates[i].taken != null) i
  ]..sort((a, b) => candidates[a].taken!.compareTo(candidates[b].taken!));
  for (var x = 0; x < timed.length; x++) {
    final a = candidates[timed[x]];
    for (var y = x + 1; y < timed.length; y++) {
      final b = candidates[timed[y]];
      if (b.taken!.difference(a.taken!) > rules.shotWindow) break;
      if (hashDistance(a.hash, b.hash) <= rules.shotHashDistance && _sameShape(a, b, rules)) {
        link(timed[x], timed[y]);
      }
    }
  }

  // Connected sets, then split so every member matches every other: each
  // photo (in the order taken) joins the first cluster it fully matches.
  final parent = List<int>.generate(n, (i) => i);
  int find(int i) => parent[i] == i ? i : parent[i] = find(parent[i]);
  edges.forEach((a, bs) {
    for (final b in bs) {
      parent[find(a)] = find(b);
    }
  });
  final components = <int, List<int>>{};
  for (final i in edges.keys) {
    (components[find(i)] ??= []).add(i);
  }

  int byTaken(int a, int b) {
    final ta = candidates[a].taken, tb = candidates[b].taken;
    final byTime = (ta ?? DateTime(9999)).compareTo(tb ?? DateTime(9999));
    return byTime != 0 ? byTime : candidates[a].id.compareTo(candidates[b].id);
  }

  final groups = <DuplicateGroup>[];
  for (final component in components.values) {
    component.sort(byTaken);
    final clusters = <List<int>>[];
    for (final i in component) {
      final home = clusters.where((c) => c.every((j) => edges[i]!.contains(j))).firstOrNull;
      home == null ? clusters.add([i]) : home.add(i);
    }
    for (final c in clusters.where((c) => c.length >= 2)) {
      groups.add(DuplicateGroup.of([for (final i in c) candidates[i]], rules));
    }
  }
  groups.sort((a, b) {
    final bySize = b.members.length.compareTo(a.members.length);
    return bySize != 0 ? bySize : a.bestId.compareTo(b.bestId);
  });
  return groups;
}

bool _sameShape(DuplicateCandidate a, DuplicateCandidate b, DuplicateGroupRules rules) {
  if (a.width <= 0 || a.height <= 0 || b.width <= 0 || b.height <= 0) return true;
  final ra = a.width / a.height, rb = b.width / b.height;
  return (ra - rb).abs() / math.max(ra, rb) <= rules.aspectTolerance;
}
