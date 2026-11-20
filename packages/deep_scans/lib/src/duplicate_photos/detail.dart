import 'dart:math' as math;
import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart';

import '../blurry_photos/measure.dart';
import '../blurry_photos/retake.dart';
import '../blurry_photos/rules.dart' show BlurryPhotoRules;
import 'rules.dart';

/// D06's fine-detail confirmation: whether two photos the 32×32 comparison
/// calls near-identical shots really show the same thing.
///
/// Different receipts photographed in the same layout look alike at 32×32
/// (the paper, the table, the rows of text), so they can pass D06. Their
/// text doesn't line up, which [detailAgreement] catches: the sharper
/// photo is blurred to match the other, the two are aligned, and only the
/// detail left after removing the local average is compared.
///
/// Both photos are first softened a little
/// ([DuplicatePhotoRules.shotDetailBlur]): two sharp shots are never
/// aligned to a fraction of a pixel, and thin text strokes half a pixel
/// apart would otherwise look like different text.
///
/// The fingerprints keep only the 32×32 grid, so both photos are decoded
/// again here. Only pairs that already matched D06 get this far.
final class ShotDetailCheck {
  ShotDetailCheck(this.source, this.rules)
      : _measure =
            BlurryPhotoRules(analysisSize: math.max(128, rules.analysisSize))
                .measureSettings;

  final StorageSource source;
  final DuplicatePhotoRules rules;
  final MeasureSettings _measure;

  /// Recently decoded photos. Cleared when full, so memory stays bounded
  /// however many shots a library has.
  final _photos = <String, Future<_Prepared?>>{};
  static const _maxPhotos = 64;

  /// Pairs whose detail was compared.
  int checks = 0;

  /// Correlation (−1…1) of the fine detail of [a] and [b], or null if either
  /// can't be decoded again.
  Future<double?> agreement(StorageItem a, StorageItem b) async {
    final _Prepared? pa, pb;
    try {
      pa = await _photo(a);
      pb = await _photo(b);
    } on StorageReadException {
      return null;
    }
    if (pa == null || pb == null || pa.thumb.size != pb.thumb.size) {
      return null;
    }
    checks++;
    final (blurry, sharp) = pa.blurWidth >= pb.blurWidth
        ? (pa.thumb, pb.thumb)
        : (pb.thumb, pa.thumb);
    final extraBlur = math.sqrt(
            (pa.blurWidth * pa.blurWidth - pb.blurWidth * pb.blurWidth).abs()) /
        _widthPerSigma;
    return detailAgreement(blurry, sharp, extraBlur,
        maxShift: rules.shotDetailMaxShift);
  }

  Future<_Prepared?> _photo(StorageItem item) {
    if (_photos.length >= _maxPhotos && !_photos.containsKey(item.id)) {
      _photos.clear();
    }
    return _photos[item.id] ??= () async {
      final thumb = await source.loadThumbnail(item, rules.analysisSize);
      if (thumb == null) return null;
      return _Prepared(
          _soften(thumb, rules.shotDetailBlur * rules.analysisSize / 256),
          BlurMeasurement.fromThumbnail(thumb, _measure).blurWidth);
    }();
  }
}

final class _Prepared {
  _Prepared(this.thumb, this.blurWidth);

  /// Softened by [DuplicatePhotoRules.shotDetailBlur].
  final Thumbnail thumb;

  /// Edge width before softening (blurry photo scan units).
  final double blurWidth;
}

/// A Gaussian blur of sigma s widens an edge's 10%–90% rise by about 2.56 s
/// (as in the blurry photo scan).
const _widthPerSigma = 2.56;

/// Separable Gaussian blur of a thumbnail.
Thumbnail _soften(Thumbnail t, double sigma) {
  if (sigma <= 0.3) return t;
  final n = t.size, r = (sigma * 3).ceil();
  final kernel = [
    for (var i = -r; i <= r; i++) math.exp(-i * i / (2 * sigma * sigma))
  ];
  final total = kernel.reduce((x, y) => x + y);
  final tmp = Float64List(n * n), out = Uint8List(n * n);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      var s = 0.0;
      for (var k = -r; k <= r; k++) {
        s += t.luma[y * n + (x + k).clamp(0, n - 1)] * kernel[k + r];
      }
      tmp[y * n + x] = s / total;
    }
  }
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      var s = 0.0;
      for (var k = -r; k <= r; k++) {
        s += tmp[(y + k).clamp(0, n - 1) * n + x] * kernel[k + r];
      }
      out[y * n + x] = (s / total).round().clamp(0, 255);
    }
  }
  return Thumbnail(
      size: n,
      luma: out,
      sourceWidth: t.sourceWidth,
      sourceHeight: t.sourceHeight);
}
