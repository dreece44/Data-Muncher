import 'dart:math' as math;
import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart' show Thumbnail;

import '../duplicate_photos/fingerprint.dart';

/// One scanned page, ready for F05: the photo fingerprint (layout-level
/// match, shared with the duplicate photo scan) and a contrast-normalised
/// greyscale copy for the detail test.
final class ScanPage {
  ScanPage._(this.size, this.luma, this.fingerprint);

  /// [thumbnail] should be at least 256 px; 512 keeps text detail.
  factory ScanPage.fromThumbnail(Thumbnail thumbnail,
      {double borderMaxStdDev = 6, double borderMaxShare = 0.35}) {
    final l = thumbnail.luma;
    final sorted = Uint8List.fromList(l)..sort();
    final lo = sorted[(sorted.length * 0.02).floor()];
    final hi = sorted[(sorted.length * 0.98).floor()];
    final range = math.max(1, hi - lo);
    return ScanPage._(
      thumbnail.size,
      Uint8List.fromList(
          [for (final v in l) ((v - lo) * 255 / range).round().clamp(0, 255)]),
      PhotoFingerprint.fromThumbnail(thumbnail,
          borderMaxStdDev: borderMaxStdDev, borderMaxShare: borderMaxShare),
    );
  }

  final int size;

  /// Brightness stretched so the darkest 2% are 0 and the lightest 2% 255:
  /// exposure differences between scans don't count.
  final Uint8List luma;
  final PhotoFingerprint fingerprint;

  double get sharpness => fingerprint.sharpness;
  int get pixels => fingerprint.pixels;
}

/// The detail test's result for one pair of pages.
final class PageDetail {
  const PageDetail(this.worstTile, this.shiftX, this.shiftY);

  /// Mean brightness difference (0–1) in the most different tile, after
  /// aligning the pages. Rescans of one paper stay low everywhere; a
  /// different document in the same layout has some tiles where the
  /// writing differs.
  final double worstTile;

  /// The alignment found, in pixels at the page's analysis size.
  final int shiftX, shiftY;

  String get evidence => 'worst tile Δ${worstTile.toStringAsFixed(3)}, '
      'aligned by ($shiftX, $shiftY) px';
}

/// Aligns [b] to [a] (searching up to [maxShift] of the page size in each
/// direction) and measures the most different tile, comparing at half the
/// analysis size so the alignment is accurate to half a pixel.
PageDetail comparePageDetail(ScanPage a, ScanPage b,
    {double maxShift = 0.05, int tilesAcross = 24}) {
  final n = a.size;
  assert(b.size == n && n % 4 == 0);
  final coarseA = _down(a.luma, n, 4, 0, 0);
  final coarseB = _down(b.luma, n, 4, 0, 0);
  final m = n ~/ 4;
  final reach = math.max(1, (m * maxShift).ceil());

  // Whole-pixel alignment at a quarter of the size…
  var best = double.infinity;
  var cx = 0, cy = 0;
  for (var sy = -reach; sy <= reach; sy++) {
    for (var sx = -reach; sx <= reach; sx++) {
      final d = _meanDiff(coarseA, coarseB, m, sx, sy, reach + 1);
      if (d < best) {
        best = d;
        cx = sx;
        cy = sy;
      }
    }
  }
  // …refined to a quarter of a pixel there.
  best = double.infinity;
  var rx = cx * 4, ry = cy * 4;
  for (var sy = cy * 4 - 3; sy <= cy * 4 + 3; sy++) {
    for (var sx = cx * 4 - 3; sx <= cx * 4 + 3; sx++) {
      final d =
          _meanDiff(coarseA, _down(b.luma, n, 4, sx, sy), m, 0, 0, reach + 1);
      if (d < best) {
        best = d;
        rx = sx;
        ry = sy;
      }
    }
  }

  final h = n ~/ 2;
  final fa = _down(a.luma, n, 2, 0, 0), fb = _down(b.luma, n, 2, rx, ry);
  final tile = math.max(2, h ~/ tilesAcross);
  final margin = (h * maxShift).ceil();
  var worst = 0.0;
  for (var ty = margin; ty + tile <= h - margin; ty += tile) {
    for (var tx = margin; tx + tile <= h - margin; tx += tile) {
      var sum = 0.0;
      for (var y = ty; y < ty + tile; y++) {
        for (var x = tx; x < tx + tile; x++) {
          sum += (fa[y * h + x] - fb[y * h + x]).abs();
        }
      }
      worst = math.max(worst, sum / (tile * tile * 255));
    }
  }
  return PageDetail(worst, rx, ry);
}

/// [g] (n×n) shifted by (sx, sy) and area-averaged by [f].
Float64List _down(Uint8List g, int n, int f, int sx, int sy) {
  final m = n ~/ f;
  final out = Float64List(m * m);
  for (var y = 0; y < m; y++) {
    for (var x = 0; x < m; x++) {
      var s = 0;
      for (var j = 0; j < f; j++) {
        final yy = (y * f + j + sy).clamp(0, n - 1) * n;
        for (var i = 0; i < f; i++) {
          s += g[yy + (x * f + i + sx).clamp(0, n - 1)];
        }
      }
      out[y * m + x] = s / (f * f);
    }
  }
  return out;
}

double _meanDiff(
    Float64List a, Float64List b, int n, int sx, int sy, int margin) {
  var s = 0.0;
  var c = 0;
  for (var y = margin; y < n - margin; y++) {
    final row = (y + sy) * n + sx;
    for (var x = margin; x < n - margin; x++) {
      s += (a[y * n + x] - b[row + x]).abs();
      c++;
    }
  }
  return s / c;
}
