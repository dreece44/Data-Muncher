import 'dart:math' as math;
import 'dart:typed_data';

import 'thumbnail.dart';

/// Measurements of one image that the photo detectors compare.
final class ImageFeatures {
  ImageFeatures({
    required this.coarseHash,
    required this.fineHash,
    required this.mean,
    required this.stdDev,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  /// 64-bit difference hash (dHash) from a 9×8 shrink. Near-identical images
  /// differ in only a few bits; used to find duplicate candidates quickly.
  final Uint8List coarseHash;

  /// 256-bit difference hash from a 17×16 shrink. Confirms candidates, so
  /// two different receipts shot on the same table aren't called duplicates.
  final Uint8List fineHash;

  /// Average brightness, 0–255.
  final double mean;

  /// Brightness spread. Near zero means the image is one flat colour.
  final double stdDev;

  final int sourceWidth;
  final int sourceHeight;

  int get pixelCount => sourceWidth * sourceHeight;

  factory ImageFeatures.fromThumbnail(Thumbnail t) {
    final luma = t.luma;
    var sum = 0;
    for (final v in luma) {
      sum += v;
    }
    final mean = sum / luma.length;
    var squares = 0.0;
    for (final v in luma) {
      squares += (v - mean) * (v - mean);
    }
    return ImageFeatures(
      coarseHash: differenceHash(t, 8),
      fineHash: differenceHash(t, 16),
      mean: mean,
      stdDev: math.sqrt(squares / luma.length),
      sourceWidth: t.sourceWidth,
      sourceHeight: t.sourceHeight,
    );
  }
}

/// Brightness difference (0–255 scale) below which two neighbouring cells
/// count as equal. Without it, sensor noise decides the bits in flat areas
/// (sky, walls, paper), and copies of one photo hash far apart.
const _flatTolerance = 2.0;

/// Difference hash with `rows × rows` bits: shrink the thumbnail to
/// `(rows + 1) × rows` by averaging, then set a bit wherever a cell is
/// clearly brighter than its right-hand neighbour. Robust to resizing,
/// recompression, noise and small brightness changes.
Uint8List differenceHash(Thumbnail t, int rows) {
  final cols = rows + 1;
  final sums = List<int>.filled(cols * rows, 0);
  final counts = List<int>.filled(cols * rows, 0);
  for (var y = 0; y < t.size; y++) {
    final cy = y * rows ~/ t.size;
    for (var x = 0; x < t.size; x++) {
      final cell = cy * cols + x * cols ~/ t.size;
      sums[cell] += t.luma[y * t.size + x];
      counts[cell]++;
    }
  }
  final hash = Uint8List(rows * rows ~/ 8);
  var bit = 0;
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < rows; c++) {
      final left = sums[r * cols + c] / counts[r * cols + c];
      final right = sums[r * cols + c + 1] / counts[r * cols + c + 1];
      if (left - right > _flatTolerance) hash[bit >> 3] |= 1 << (bit & 7);
      bit++;
    }
  }
  return hash;
}

final _bitCounts = Uint8List.fromList([
  for (var i = 0; i < 256; i++)
    [for (var b = 0; b < 8; b++) (i >> b) & 1].reduce((a, b) => a + b),
]);

/// Number of differing bits between two hashes of the same length.
int hammingDistance(Uint8List a, Uint8List b) {
  assert(a.length == b.length);
  var distance = 0;
  for (var i = 0; i < a.length; i++) {
    distance += _bitCounts[a[i] ^ b[i]];
  }
  return distance;
}
