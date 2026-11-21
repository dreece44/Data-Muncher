import 'dart:math' as math;
import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart' show Thumbnail;

/// Side of the grid fine detail is compared at.
const _detailSize = 256;

/// Side of the grid the two photos are first aligned at.
const _coarseSize = 64;

/// Whether a sharp photo really is a retake of a blurry one, judged on fine
/// detail: the sharper photo is blurred to match, the two are aligned
/// (retakes are rarely framed identically), and only what's left after
/// removing the overall layout is compared.
///
/// The perceptual-hash comparison that finds candidates looks at the
/// layout, and blur hides everything else: two different receipts on the
/// same table look the same to it once one is blurred. Their text doesn't
/// line up, which this catches.
///
/// [blurry] and [sharp] are square thumbnails of the same size;
/// [extraBlur] is how much blur (Gaussian sigma, thumbnail pixels) to add
/// to [sharp] so the two match. Returns the correlation (−1…1) of the
/// photos' fine detail at the best alignment within [maxShift] (share of
/// the frame).
double detailAgreement(Thumbnail blurry, Thumbnail sharp, double extraBlur,
    {double maxShift = 0.05}) {
  final n = blurry.size;
  final m = math.min(_detailSize, n);
  final a = _resize(blurry.luma, n, m);
  var b = _resize(sharp.luma, sharp.size, m);
  final sigma = extraBlur * m / n;
  if (sigma > 0.3) b = _gaussian(b, m, sigma);

  // Align on the overall picture at coarse scale...
  final ca = _resize(_toBytes(a), m, _coarseSize);
  final cb = _resize(_toBytes(b), m, _coarseSize);
  final coarseShift = math.max(1, (maxShift * _coarseSize).round());
  var best = (0, 0);
  var bestScore = -2.0;
  for (var dy = -coarseShift; dy <= coarseShift; dy++) {
    for (var dx = -coarseShift; dx <= coarseShift; dx++) {
      final s = _ncc(ca, cb, _coarseSize, dx, dy, coarseShift);
      if (s > bestScore) {
        bestScore = s;
        best = (dx, dy);
      }
    }
  }

  // ...then compare fine detail, refining the alignment around it.
  final da = _detail(a, m), db = _detail(b, m);
  final scale = m ~/ _coarseSize;
  final margin = math.max(1, (maxShift * m).round()) + scale;
  var agreement = -1.0;
  for (var dy = -scale; dy <= scale; dy++) {
    for (var dx = -scale; dx <= scale; dx++) {
      agreement = math.max(agreement,
          _ncc(da, db, m, best.$1 * scale + dx, best.$2 * scale + dy, margin));
    }
  }
  return agreement;
}

/// Area-average resize of an n×n image to m×m.
Float64List _resize(List<num> src, int n, int m) {
  if (n == m) return Float64List.fromList([for (final v in src) v.toDouble()]);
  final out = Float64List(m * m);
  final f = n / m;
  for (var y = 0; y < m; y++) {
    final y0 = y * f, y1 = y0 + f;
    for (var x = 0; x < m; x++) {
      final x0 = x * f, x1 = x0 + f;
      var sum = 0.0, area = 0.0;
      for (var sy = y0.floor(); sy < y1.ceil() && sy < n; sy++) {
        final wy = math.min(y1, sy + 1.0) - math.max(y0, sy.toDouble());
        for (var sx = x0.floor(); sx < x1.ceil() && sx < n; sx++) {
          final w = wy * (math.min(x1, sx + 1.0) - math.max(x0, sx.toDouble()));
          sum += src[sy * n + sx] * w;
          area += w;
        }
      }
      out[y * m + x] = sum / area;
    }
  }
  return out;
}

List<num> _toBytes(Float64List v) => v;

/// Separable Gaussian blur.
Float64List _gaussian(Float64List src, int m, double sigma) {
  final r = (sigma * 3).ceil();
  final kernel = [
    for (var i = -r; i <= r; i++) math.exp(-i * i / (2 * sigma * sigma))
  ];
  final total = kernel.reduce((x, y) => x + y);
  final tmp = Float64List(m * m), out = Float64List(m * m);
  for (var y = 0; y < m; y++) {
    for (var x = 0; x < m; x++) {
      var s = 0.0;
      for (var k = -r; k <= r; k++) {
        s += src[y * m + (x + k).clamp(0, m - 1)] * kernel[k + r];
      }
      tmp[y * m + x] = s / total;
    }
  }
  for (var y = 0; y < m; y++) {
    for (var x = 0; x < m; x++) {
      var s = 0.0;
      for (var k = -r; k <= r; k++) {
        s += tmp[(y + k).clamp(0, m - 1) * m + x] * kernel[k + r];
      }
      out[y * m + x] = s / total;
    }
  }
  return out;
}

/// The image minus its local average: edges and texture without the
/// overall layout (paper on a table, sky over ground).
Float64List _detail(Float64List src, int m) {
  final r = math.max(2, m ~/ 40);
  // Summed-area table for fast box averages.
  final sat = Float64List((m + 1) * (m + 1));
  for (var y = 0; y < m; y++) {
    var row = 0.0;
    for (var x = 0; x < m; x++) {
      row += src[y * m + x];
      sat[(y + 1) * (m + 1) + x + 1] = sat[y * (m + 1) + x + 1] + row;
    }
  }
  final out = Float64List(m * m);
  for (var y = 0; y < m; y++) {
    final y0 = math.max(0, y - r), y1 = math.min(m, y + r + 1);
    for (var x = 0; x < m; x++) {
      final x0 = math.max(0, x - r), x1 = math.min(m, x + r + 1);
      final sum = sat[y1 * (m + 1) + x1] -
          sat[y0 * (m + 1) + x1] -
          sat[y1 * (m + 1) + x0] +
          sat[y0 * (m + 1) + x0];
      out[y * m + x] = src[y * m + x] - sum / ((y1 - y0) * (x1 - x0));
    }
  }
  return out;
}

/// Normalised cross-correlation of a and b shifted by (dx, dy), over the
/// frame minus [margin] on every side.
double _ncc(Float64List a, Float64List b, int m, int dx, int dy, int margin) {
  var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
  var count = 0;
  for (var y = margin; y < m - margin; y++) {
    final by = y + dy;
    if (by < 0 || by >= m) continue;
    for (var x = margin; x < m - margin; x++) {
      final bx = x + dx;
      if (bx < 0 || bx >= m) continue;
      final va = a[y * m + x], vb = b[by * m + bx];
      sa += va;
      sb += vb;
      saa += va * va;
      sbb += vb * vb;
      sab += va * vb;
      count++;
    }
  }
  if (count == 0) return -1;
  final cov = sab / count - sa / count * sb / count;
  final va = saa / count - math.pow(sa / count, 2);
  final vb = sbb / count - math.pow(sb / count, 2);
  if (va <= 1e-9 || vb <= 1e-9) return 0;
  return cov / math.sqrt(va * vb);
}
