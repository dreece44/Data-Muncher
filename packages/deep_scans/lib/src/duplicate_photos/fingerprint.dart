import 'dart:math' as math;
import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart' show Thumbnail;

/// Side of the comparison grid every photo is reduced to.
const gridSize = 32;
const _cells = gridSize * gridSize;

/// The eight ways a photo can be turned or flipped and still be the same
/// picture.
enum PhotoTransform {
  none('as is'),
  mirror('mirrored'),
  flip('flipped upside down'),
  rotate180('rotated 180°'),
  transpose('rotated and mirrored'),
  rotate90('rotated 90°'),
  rotate270('rotated 270°'),
  transverse('rotated and mirrored');

  const PhotoTransform(this.label);
  final String label;

  /// Whether width and height swap.
  bool get swapsSides => index >= 4;

  /// Source cell for output cell (x, y) in an n×n grid.
  (int, int) source(int x, int y, int n) => switch (this) {
        none => (x, y),
        mirror => (n - 1 - x, y),
        flip => (x, n - 1 - y),
        rotate180 => (n - 1 - x, n - 1 - y),
        transpose => (y, x),
        rotate90 => (y, n - 1 - x),
        rotate270 => (n - 1 - y, x),
        transverse => (n - 1 - y, n - 1 - x),
      };
}

/// One view of a photo (the whole frame, or the frame with uniform borders
/// trimmed off) reduced to a [gridSize]² brightness grid, with everything
/// the matcher compares precomputed.
final class PhotoView {
  PhotoView._(this.grid, this._dct);

  factory PhotoView(Float64List grid) => PhotoView._(grid, _lowDct(grid));

  /// Brightness 0–255, row by row.
  final Float64List grid;

  /// [grid] scaled to mean 0 and spread 1, so brightness and contrast edits
  /// don't change it.
  late final Float64List normalized = _normalize(grid);

  /// Normalised edge strength: where the picture's detail is.
  late final Float64List gradient = _normalize(_gradient(grid));

  /// Low-frequency 8×8 DCT block, row (vertical frequency) by column.
  final Float64List _dct;

  double get mean => grid.reduce((a, b) => a + b) / _cells;

  final _hashes = <PhotoTransform, int>{};

  /// 63-bit perceptual hash (pHash) of this view turned by [t]: one bit per
  /// low-frequency DCT coefficient, set when it's above the median.
  /// Turning a picture only swaps and flips the signs of its DCT
  /// coefficients, so every transform comes from one DCT.
  int hash([PhotoTransform t = PhotoTransform.none]) =>
      _hashes[t] ??= _hashOf(t);

  int _hashOf(PhotoTransform t) {
    final coeffs = Float64List(63);
    var i = 0;
    for (var v = 0; v < 8; v++) {
      for (var u = 0; u < 8; u++) {
        if (u == 0 && v == 0) continue; // Overall brightness: not compared.
        final (su, sv) = t.swapsSides ? (v, u) : (u, v);
        var c = _dct[sv * 8 + su];
        final flipX = t == PhotoTransform.mirror ||
            t == PhotoTransform.rotate180 ||
            t == PhotoTransform.rotate90 ||
            t == PhotoTransform.transverse;
        final flipY = t == PhotoTransform.flip ||
            t == PhotoTransform.rotate180 ||
            t == PhotoTransform.rotate270 ||
            t == PhotoTransform.transverse;
        if (flipX && u.isOdd) c = -c;
        if (flipY && v.isOdd) c = -c;
        coeffs[i++] = c;
      }
    }
    final sorted = Float64List.fromList(coeffs)..sort();
    final median = sorted[31];
    var hash = 0;
    for (var k = 0; k < 63; k++) {
      if (coeffs[k] > median) hash |= 1 << k;
    }
    return hash;
  }

  /// This view's grid turned by [t].
  PhotoView transformed(PhotoTransform t) {
    if (t == PhotoTransform.none) return this;
    final out = Float64List(_cells);
    for (var y = 0; y < gridSize; y++) {
      for (var x = 0; x < gridSize; x++) {
        final (sx, sy) = t.source(x, y, gridSize);
        out[y * gridSize + x] = grid[sy * gridSize + sx];
      }
    }
    return PhotoView(out);
  }
}

/// Everything the duplicate scan knows about one decoded photo.
final class PhotoFingerprint {
  PhotoFingerprint({
    required this.width,
    required this.height,
    required this.full,
    required this.trimmed,
    required this.trimmedShare,
    required this.trimmedAspect,
    required this.sharpness,
    required this.spread,
  });

  /// Size of the original image.
  final int width;
  final int height;

  /// The whole frame.
  final PhotoView full;

  /// The frame with uniform borders (letterboxing, white frames) removed,
  /// or null if there were none.
  final PhotoView? trimmed;

  /// Share of the frame the trimmed borders took up (0–1).
  final double trimmedShare;

  /// Width / height of the picture inside the borders.
  final double trimmedAspect;

  /// Variance of the Laplacian at analysis size: higher is sharper. Only
  /// meaningful when comparing shots of the same scene.
  final double sharpness;

  /// Brightness spread (standard deviation, 0–255). Near zero is a blank,
  /// flat-colour photo.
  final double spread;

  int get pixels => width * height;
  double get aspect => width / height;

  /// Builds a fingerprint from a square greyscale [thumbnail] of the photo
  /// (the decoders don't keep aspect ratio; [width]/[height] carry it).
  factory PhotoFingerprint.fromThumbnail(Thumbnail thumbnail,
      {double borderMaxStdDev = 6, double borderMaxShare = 0.35}) {
    final n = thumbnail.size;
    final luma = thumbnail.luma;
    final fullGrid = _resample(luma, n, 0, 0, n, n);
    final (top, bottom, left, right) =
        _uniformBorders(luma, n, borderMaxStdDev, borderMaxShare);
    final trimmedArea = (n - top - bottom) * (n - left - right);
    final share = 1 - trimmedArea / (n * n);
    return PhotoFingerprint(
      width: thumbnail.sourceWidth,
      height: thumbnail.sourceHeight,
      full: PhotoView(fullGrid),
      trimmed: share >= 0.03
          ? PhotoView(_resample(luma, n, left, top, n - right, n - bottom))
          : null,
      trimmedShare: share >= 0.03 ? share : 0,
      trimmedAspect: thumbnail.sourceWidth /
          thumbnail.sourceHeight *
          (n - left - right) /
          (n - top - bottom),
      sharpness: _laplacianVariance(luma, n, left, top, n - right, n - bottom),
      spread: _stdDev(fullGrid),
    );
  }
}

// --- Image maths ----------------------------------------------------------

/// Area-averages the rectangle [x0,x1)×[y0,y1) of an n×n image down to the
/// comparison grid.
Float64List _resample(Uint8List luma, int n, int x0, int y0, int x1, int y1) {
  final out = Float64List(_cells);
  final w = (x1 - x0) / gridSize, h = (y1 - y0) / gridSize;
  for (var gy = 0; gy < gridSize; gy++) {
    final sy0 = y0 + gy * h, sy1 = sy0 + h;
    for (var gx = 0; gx < gridSize; gx++) {
      final sx0 = x0 + gx * w, sx1 = sx0 + w;
      var sum = 0.0, area = 0.0;
      for (var y = sy0.floor(); y < sy1.ceil() && y < n; y++) {
        final wy = math.min(sy1, y + 1.0) - math.max(sy0, y.toDouble());
        for (var x = sx0.floor(); x < sx1.ceil() && x < n; x++) {
          final wx = math.min(sx1, x + 1.0) - math.max(sx0, x.toDouble());
          final weight = wx * wy;
          sum += luma[y * n + x] * weight;
          area += weight;
        }
      }
      out[gy * gridSize + gx] = sum / area;
    }
  }
  return out;
}

/// Rows/columns at each edge that are one flat colour matching the edge.
(int, int, int, int) _uniformBorders(
    Uint8List luma, int n, double maxStd, double maxShare) {
  final limit = (n * maxShare).floor();
  bool flat(Iterable<int> values, double reference) {
    var sum = 0.0, squares = 0.0, count = 0;
    for (final v in values) {
      sum += v;
      squares += v * v;
      count++;
    }
    final mean = sum / count;
    final std = math.sqrt(math.max(0, squares / count - mean * mean));
    return std <= maxStd && (mean - reference).abs() <= 8;
  }

  Iterable<int> row(int y) sync* {
    for (var x = 0; x < n; x++) {
      yield luma[y * n + x];
    }
  }

  Iterable<int> col(int x) sync* {
    for (var y = 0; y < n; y++) {
      yield luma[y * n + x];
    }
  }

  double meanOf(Iterable<int> v) => v.reduce((a, b) => a + b) / v.length;

  int count(Iterable<int> Function(int) line, int Function(int) index) {
    final reference = meanOf(line(index(0)));
    var k = 0;
    while (k < limit && flat(line(index(k)), reference)) {
      k++;
    }
    return k;
  }

  return (
    count(row, (k) => k),
    count(row, (k) => n - 1 - k),
    count(col, (k) => k),
    count(col, (k) => n - 1 - k),
  );
}

/// Inside [x0,x1)×[y0,y1), so added borders don't count as detail.
double _laplacianVariance(
    Uint8List luma, int n, int x0, int y0, int x1, int y1) {
  var sum = 0.0, squares = 0.0;
  var count = 0;
  for (var y = y0 + 1; y < y1 - 1; y++) {
    for (var x = x0 + 1; x < x1 - 1; x++) {
      final i = y * n + x;
      final l =
          4 * luma[i] - luma[i - 1] - luma[i + 1] - luma[i - n] - luma[i + n];
      sum += l;
      squares += l * l;
      count++;
    }
  }
  final mean = sum / count;
  return squares / count - mean * mean;
}

double _stdDev(Float64List v) {
  final mean = v.reduce((a, b) => a + b) / v.length;
  var squares = 0.0;
  for (final x in v) {
    squares += (x - mean) * (x - mean);
  }
  return math.sqrt(squares / v.length);
}

Float64List _normalize(Float64List v) {
  final mean = v.reduce((a, b) => a + b) / v.length;
  final std = _stdDev(v);
  return Float64List.fromList(
      [for (final x in v) std < 1e-9 ? 0.0 : (x - mean) / std]);
}

/// Edge strength: horizontal + vertical brightness differences.
Float64List _gradient(Float64List g) {
  final out = Float64List(_cells);
  for (var y = 0; y < gridSize; y++) {
    for (var x = 0; x < gridSize; x++) {
      final i = y * gridSize + x;
      final dx = x + 1 < gridSize ? g[i + 1] - g[i] : 0.0;
      final dy = y + 1 < gridSize ? g[i + gridSize] - g[i] : 0.0;
      out[i] = math.sqrt(dx * dx + dy * dy);
    }
  }
  return out;
}

final Float64List _cosTable = () {
  final t = Float64List(8 * gridSize);
  for (var u = 0; u < 8; u++) {
    for (var x = 0; x < gridSize; x++) {
      t[u * gridSize + x] =
          math.cos(math.pi * (2 * x + 1) * u / (2 * gridSize));
    }
  }
  return t;
}();

/// The top-left 8×8 of the 2-D DCT-II of the grid (separable).
Float64List _lowDct(Float64List g) {
  final rows = Float64List(gridSize * 8); // [y][u]
  for (var y = 0; y < gridSize; y++) {
    for (var u = 0; u < 8; u++) {
      var s = 0.0;
      for (var x = 0; x < gridSize; x++) {
        s += g[y * gridSize + x] * _cosTable[u * gridSize + x];
      }
      rows[y * 8 + u] = s;
    }
  }
  final out = Float64List(64); // [v][u]
  for (var v = 0; v < 8; v++) {
    for (var u = 0; u < 8; u++) {
      var s = 0.0;
      for (var y = 0; y < gridSize; y++) {
        s += rows[y * 8 + u] * _cosTable[v * gridSize + y];
      }
      out[v * 8 + u] = s;
    }
  }
  return out;
}

/// Pearson correlation of two normalised grids (−1…1).
double correlation(Float64List a, Float64List b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s / a.length;
}

/// Mean absolute brightness difference (0–255).
double meanAbsDiff(Float64List a, Float64List b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += (a[i] - b[i]).abs();
  }
  return s / a.length;
}

int bitCount(int v) {
  var n = 0;
  while (v != 0) {
    v &= v - 1;
    n++;
  }
  return n;
}
