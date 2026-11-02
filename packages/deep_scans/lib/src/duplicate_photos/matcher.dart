import 'dart:math' as math;

import 'fingerprint.dart';
import 'rules.dart';

/// The outcome of comparing two photos: the rule they match under (if any)
/// and the measurements behind it, kept for tuning.
final class PairCheck {
  const PairCheck({
    required this.rule,
    required this.hashDistance,
    required this.correlation,
    required this.edgeCorrelation,
    required this.brightnessDiff,
    required this.transform,
    required this.bordered,
    this.note,
    this.detailAgreement,
  });

  /// Null when the photos aren't duplicates.
  final DuplicateRule? rule;
  final int hashDistance;
  final double correlation;
  final double edgeCorrelation;
  final double brightnessDiff;
  final PhotoTransform transform;

  /// Whether the match needed one photo's borders trimmed off.
  final bool bordered;

  /// Why a close pair was rejected (e.g. taken days apart).
  final String? note;

  /// D06 only: how well the photos' fine detail agrees (−1…1), measured on
  /// the re-decoded photos (detail.dart). Null when not checked.
  final double? detailAgreement;

  bool get matched => rule != null;

  PairCheck withDetail(double agreement) => PairCheck(
        rule: rule,
        hashDistance: hashDistance,
        correlation: correlation,
        edgeCorrelation: edgeCorrelation,
        brightnessDiff: brightnessDiff,
        transform: transform,
        bordered: bordered,
        note: note,
        detailAgreement: agreement,
      );

  String get evidence => 'pHash $hashDistance, correlation '
      '${correlation.toStringAsFixed(3)}, edges '
      '${edgeCorrelation.toStringAsFixed(3)}, brightness Δ'
      '${brightnessDiff.toStringAsFixed(1)}'
      '${transform == PhotoTransform.none ? '' : ', ${transform.label}'}'
      '${bordered ? ', borders trimmed' : ''}'
      '${detailAgreement == null ? '' : ', detail '
          '${detailAgreement!.toStringAsFixed(3)}'}';

  Map<String, Object?> toJson() => {
        'rule': rule?.code,
        'hashDistance': hashDistance,
        'correlation': correlation,
        'edgeCorrelation': edgeCorrelation,
        'brightnessDiff': brightnessDiff,
        'transform': transform.name,
        'bordered': bordered,
        if (note != null) 'note': note,
        if (detailAgreement != null) 'detailAgreement': detailAgreement,
      };
}

/// Compares two photos under every rotation/mirror and with/without
/// trimmed borders, and classifies the best alignment.
///
/// [shotAllowed] is false when the photos can't be shots of the same
/// moment (taken too far apart, or screenshots); D06 then doesn't apply.
/// [bothOriginals] says both files look first-hand (not in a messaging or
/// download folder, not named like a copy): two such files taken moments
/// apart are separate shots even when they're pixel-for-pixel alike.
PairCheck? comparePhotos(
    PhotoFingerprint a, PhotoFingerprint b, DuplicatePhotoRules r,
    {required bool shotAllowed,
    bool bothOriginals = false,
    String? shotBlockedReason}) {
  _Candidate? bestCopy, bestAny;
  final viewsA = [(a.full, false), if (a.trimmed != null) (a.trimmed!, true)];
  final viewsB = [(b.full, false), if (b.trimmed != null) (b.trimmed!, true)];

  for (final t in PhotoTransform.values) {
    for (final (va, trimA) in viewsA) {
      for (final (vb, trimB) in viewsB) {
        final distance = bitCount(va.hash() ^ vb.hash(t));
        if (distance > math.max(r.copyHashDistance, r.shotHashDistance)) {
          continue;
        }
        // Copies keep their shape (once rotation is undone).
        final aspectA = trimA ? a.trimmedAspect : a.aspect;
        var aspectB = trimB ? b.trimmedAspect : b.aspect;
        if (t.swapsSides) aspectB = 1 / aspectB;
        final bordered = trimA != trimB;
        final tolerance =
            bordered ? r.borderedAspectTolerance : r.aspectTolerance;
        if ((aspectA / aspectB - 1).abs() > tolerance) continue;

        final turned = vb.transformed(t);
        final c = _Candidate(
          distance: distance,
          correlation: correlation(va.normalized, turned.normalized),
          edges: correlation(va.gradient, turned.gradient),
          brightness: meanAbsDiff(va.grid, turned.grid),
          transform: t,
          bordered: bordered,
        );
        if (bestAny == null || c.correlation > bestAny.correlation) {
          bestAny = c;
        }
        final isCopy = distance <= r.copyHashDistance &&
            c.correlation >= r.copyCorrelation &&
            c.edges >= r.copyEdgeCorrelation;
        if (isCopy && (bestCopy == null || c.preferredTo(bestCopy))) {
          bestCopy = c;
        }
      }
    }
  }

  if (bestCopy != null) {
    final c = bestCopy;
    final sharpRatio = a.sharpness < b.sharpness
        ? a.sharpness / b.sharpness
        : b.sharpness / a.sharpness;
    final DuplicateRule rule;
    final sameFrame = a.width == b.width && a.height == b.height;
    if (shotAllowed &&
        c.transform == PhotoTransform.none &&
        !c.bordered &&
        (sharpRatio < r.blurryRetakeSharpness ||
            (bothOriginals && sameFrame))) {
      // A blurry retake, or another frame from the same burst.
      rule = DuplicateRule.d06SimilarShot;
    } else if (c.transform != PhotoTransform.none) {
      rule = DuplicateRule.d03Turned;
    } else if (c.bordered) {
      rule = DuplicateRule.d04Bordered;
    } else if (c.brightness > r.editedMinBrightnessDiff) {
      rule = DuplicateRule.d05Edited;
    } else {
      rule = DuplicateRule.d02ReEncoded;
    }
    return c.toCheck(rule);
  }

  final c = bestAny;
  if (c == null) return null;
  final isShot = c.transform == PhotoTransform.none &&
      !c.bordered &&
      c.distance <= r.shotHashDistance &&
      c.correlation >= r.shotCorrelation &&
      c.edges >= r.shotEdgeCorrelation;
  if (isShot && shotAllowed) return c.toCheck(DuplicateRule.d06SimilarShot);
  return c.toCheck(null,
      note: isShot ? shotBlockedReason : 'below match thresholds');
}

final class _Candidate {
  _Candidate({
    required this.distance,
    required this.correlation,
    required this.edges,
    required this.brightness,
    required this.transform,
    required this.bordered,
  });

  final int distance;
  final double correlation, edges, brightness;
  final PhotoTransform transform;
  final bool bordered;

  /// The simplest explanation wins: as-is beats rotated beats bordered;
  /// then the closer match.
  bool preferredTo(_Candidate other) {
    int rank(_Candidate c) =>
        (c.transform == PhotoTransform.none ? 0 : 2) + (c.bordered ? 1 : 0);
    final byRank = rank(this).compareTo(rank(other));
    if (byRank != 0) return byRank < 0;
    return correlation > other.correlation;
  }

  PairCheck toCheck(DuplicateRule? rule, {String? note}) => PairCheck(
        rule: rule,
        hashDistance: distance,
        correlation: correlation,
        edgeCorrelation: edges,
        brightnessDiff: brightness,
        transform: transform,
        bordered: bordered,
        note: note,
      );
}

/// Finds pairs of photos whose perceptual hashes are within [maxDistance]
/// bits under some rotation/mirror, without comparing every pair.
///
/// Each 63-bit hash is cut into `maxDistance + 1` bands. Two hashes within
/// [maxDistance] bits can differ in at most that many bands, so they share
/// at least one band exactly (pigeonhole): looking up equal bands finds
/// every such pair, and only those plus a few false candidates.
Set<(int, int)> hashCandidates(List<PhotoFingerprint> photos, int maxDistance) {
  final bands = maxDistance + 1;
  final width = (63 / bands).ceil();
  int band(int hash, int i) => (hash >> (i * width)) & ((1 << width) - 1);

  final index = <int, List<int>>{};
  for (var p = 0; p < photos.length; p++) {
    for (final view in _views(photos[p])) {
      final h = view.hash();
      for (var i = 0; i < bands; i++) {
        (index[i << 32 | band(h, i)] ??= []).add(p);
      }
    }
  }

  final pairs = <(int, int)>{};
  for (var p = 0; p < photos.length; p++) {
    for (final view in _views(photos[p])) {
      for (final t in PhotoTransform.values) {
        final h = view.hash(t);
        for (var i = 0; i < bands; i++) {
          for (final q in index[i << 32 | band(h, i)] ?? const <int>[]) {
            if (q != p) pairs.add(p < q ? (p, q) : (q, p));
          }
        }
      }
    }
  }
  return pairs;
}

Iterable<PhotoView> _views(PhotoFingerprint f) =>
    [f.full, if (f.trimmed != null) f.trimmed!];
