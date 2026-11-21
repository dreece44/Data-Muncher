import 'dart:math' as math;
import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart' show Thumbnail;

/// The four directions edges are measured across. Motion blur smears along
/// one of them; focus blur widens all four.
enum EdgeDirection {
  horizontal('left–right', 1, 0),
  vertical('up–down', 0, 1),
  diagonal('diagonal ↘', 1, 1),
  antiDiagonal('diagonal ↙', -1, 1);

  const EdgeDirection(this.label, this.dx, this.dy);

  final String label;

  /// One step across an edge, in thumbnail pixels.
  final int dx, dy;
}

/// Settings for [BlurMeasurement.fromThumbnail]. Copied from
/// `BlurryPhotoRules` so this file has no dependency on the rules.
final class MeasureSettings {
  const MeasureSettings({
    required this.referenceSize,
    required this.minGradient,
    required this.minEdgeContrast,
    required this.walkTolerance,
    required this.walkPatience,
    required this.maxWalk,
    required this.tiles,
    required this.minTileEdges,
    required this.sharpRegionShare,
    required this.minRegionTiles,
    required this.pixelFloor,
  });

  /// Edge widths are reported in pixels of the photo shown with its long
  /// side this big (or at its own size, if smaller).
  final int referenceSize;
  final double minGradient;
  final int minEdgeContrast;
  final int walkTolerance;
  final int walkPatience;
  final int maxWalk;
  final int tiles;
  final int minTileEdges;
  final double sharpRegionShare;
  final int minRegionTiles;

  /// Width (in thumbnail pixels) a perfectly sharp edge still measures,
  /// because it falls between pixels. Taken off every width in quadrature,
  /// the way blurs add up.
  final double pixelFloor;
}

/// How blurry one photo is, measured from the width of its edges.
///
/// Every strong edge is crossed in the direction its brightness changes,
/// and the distance from 10% to 90% of the change is its width: about one
/// pixel for an in-focus edge, many for a blurred one. Widths are gathered
/// per tile of a [MeasureSettings.tiles]² grid and per [EdgeDirection].
/// Each tile counts as soft as its softest direction (so motion blur along
/// one direction shows), and the photo is judged by its *sharpest region*,
/// so a sharp subject in front of a soft background (portrait mode, panning
/// shots) doesn't count as blurry.
final class BlurMeasurement {
  BlurMeasurement({
    required this.width,
    required this.height,
    required this.analysisSize,
    required this.edgeCount,
    required this.tilesJudged,
    required this.blurWidth,
    required this.medianWidth,
    required this.directionWidths,
    required this.spread,
    required this.brightness,
  });

  /// Size of the original image.
  final int width;
  final int height;

  /// Side of the square thumbnail measured.
  final int analysisSize;

  /// Edges that passed the contrast test and were measured.
  final int edgeCount;

  /// Tiles with enough edges in two or more directions to be judged.
  final int tilesJudged;

  /// How soft even the sharpest part of the photo is, in its softest
  /// direction (reference pixels). The number every rule compares; 0 when
  /// the photo isn't [judgeable].
  final double blurWidth;

  /// Median width of every measured edge (reference pixels). Includes soft
  /// backgrounds, so only used to spot sharp-subject photos.
  final double medianWidth;

  /// For each direction with enough tiles: the width of the sharpest
  /// region's edges across that direction alone (reference pixels).
  final Map<EdgeDirection, double> directionWidths;

  /// Brightness spread (standard deviation, 0–255). Near zero is blank.
  final double spread;

  /// Average brightness (0–255).
  final double brightness;

  /// Whether there's enough structure to judge sharpness at all.
  bool get judgeable => tilesJudged > 0 && directionWidths.length >= 2;

  /// The softest direction's sharpest-region width: how far edges are
  /// smeared along the direction of any motion.
  double get motionWidth => directionWidths.values.reduce(math.max);

  /// The crispest direction's sharpest-region width.
  double get crispWidth => directionWidths.values.reduce(math.min);

  /// The direction [motionWidth] was measured across.
  EdgeDirection get softestDirection =>
      directionWidths.entries.reduce((a, b) => b.value > a.value ? b : a).key;

  /// [motionWidth] over [crispWidth]: near 1 for focus blur, large for
  /// motion blur. The crisp direction is floored at a quarter pixel so a
  /// perfectly sharp one doesn't divide by zero.
  double get directionality => motionWidth / math.max(crispWidth, 0.25);

  /// Blurriness 0–100 for ranking: the share of an edge's width that is
  /// blur rather than the [sharpWidth] an in-focus edge has.
  double score(double sharpWidth) => blurWidth <= 0
      ? 0
      : (100 * (1 - sharpWidth / blurWidth)).clamp(0, 100).toDouble();

  String get evidence {
    String f(double v) => v.toStringAsFixed(2);
    final directions = [
      for (final d in EdgeDirection.values)
        if (directionWidths[d] != null) '${d.label} ${f(directionWidths[d]!)}'
    ].join(', ');
    return 'blur width ${f(blurWidth)}; by direction: $directions; '
        'all edges median ${f(medianWidth)}; $edgeCount edges, '
        '$tilesJudged tiles judged at ${analysisSize}px; '
        'spread ${spread.toStringAsFixed(1)}';
  }

  Map<String, Object?> toJson() {
    double r(double v) => double.parse(v.toStringAsFixed(2));
    return {
      'width': width,
      'height': height,
      'analysisSize': analysisSize,
      'edgeCount': edgeCount,
      'tilesJudged': tilesJudged,
      'medianWidth': r(medianWidth),
      if (judgeable) 'blurWidth': r(blurWidth),
      'directionWidths': {
        for (final e in directionWidths.entries) e.key.name: r(e.value)
      },
      'spread': r(spread),
      'brightness': r(brightness),
    };
  }

  /// Measures a square greyscale [thumbnail] (the decoders don't keep
  /// aspect ratio, so widths are converted back using the source size).
  factory BlurMeasurement.fromThumbnail(
      Thumbnail thumbnail, MeasureSettings s) {
    final n = thumbnail.size;
    final luma = thumbnail.luma;
    final w = thumbnail.sourceWidth, h = thumbnail.sourceHeight;

    // One thumbnail pixel across, in reference pixels. Reference pixels are
    // the photo's own if it's small, so small photos aren't judged on
    // blur that only upscaling would add.
    final long = math.max(w, h);
    final refPerSource = math.min(s.referenceSize, long) / long;
    final sx = w / n * refPerSource, sy = h / n * refPerSource;
    final diagonal = math.sqrt(sx * sx + sy * sy);
    final stepLength = {
      EdgeDirection.horizontal: sx,
      EdgeDirection.vertical: sy,
      EdgeDirection.diagonal: diagonal,
      EdgeDirection.antiDiagonal: diagonal,
    };

    final perTile = <int, Map<EdgeDirection, List<double>>>{};
    final all = <double>[];
    final profile = Float64List(2 * s.maxWalk + 1);

    int at(int x, int y) => luma[y * n + x];
    bool inside(int x, int y) => x >= 0 && y >= 0 && x < n && y < n;
    // Brightness change across q in direction d (central difference).
    double along(int x, int y, EdgeDirection d) {
      final x0 = x - d.dx, y0 = y - d.dy, x1 = x + d.dx, y1 = y + d.dy;
      if (!inside(x0, y0) || !inside(x1, y1)) return 0;
      return (at(x1, y1) - at(x0, y0)) / 2;
    }

    for (var y = 1; y < n - 1; y++) {
      for (var x = 1; x < n - 1; x++) {
        final gx = (at(x + 1, y) - at(x - 1, y)) / 2;
        final gy = (at(x, y + 1) - at(x, y - 1)) / 2;
        if (gx * gx + gy * gy < s.minGradient * s.minGradient) continue;

        // Cross the edge along the nearest of the four directions.
        var angle = math.atan2(gy, gx);
        if (angle < 0) angle += math.pi;
        final bucket = ((angle / (math.pi / 4)).round()) % 4;
        final d = const [
          EdgeDirection.horizontal,
          EdgeDirection.diagonal,
          EdgeDirection.vertical,
          EdgeDirection.antiDiagonal,
        ][bucket];

        // Only the steepest point of each crossing.
        final g = along(x, y, d);
        if (g.abs() < s.minGradient / 2 ||
            g.abs() < along(x - d.dx, y - d.dy, d).abs() ||
            g.abs() <= along(x + d.dx, y + d.dy, d).abs()) {
          continue;
        }
        final sign = g > 0 ? 1 : -1;

        // Walk to where the brightness stops rising (forward) and stops
        // falling (backward), allowing for small wobbles from noise.
        int walk(int dir) {
          final m = sign * dir;
          var best = at(x, y) * m, bestK = 0;
          for (var k = 1; k <= s.maxWalk; k++) {
            final qx = x + dir * k * d.dx, qy = y + dir * k * d.dy;
            if (!inside(qx, qy)) break;
            final v = at(qx, qy) * m;
            if (v > best) {
              best = v;
              bestK = k;
            } else if (best - v > s.walkTolerance ||
                k - bestK > s.walkPatience) {
              break;
            }
          }
          return bestK;
        }

        final forward = walk(1), back = walk(-1);
        final lo = at(x - back * d.dx, y - back * d.dy) * sign;
        final hi = at(x + forward * d.dx, y + forward * d.dy) * sign;
        final contrast = hi - lo;
        if (contrast < s.minEdgeContrast) continue;

        // 10%–90% rise distance, interpolated between pixels.
        final len = back + forward + 1;
        for (var k = 0; k < len; k++) {
          final o = k - back;
          profile[k] = (at(x + o * d.dx, y + o * d.dy) * sign - lo).toDouble();
        }
        double crossing(double target) {
          for (var k = 1; k < len; k++) {
            if (profile[k] >= target) {
              final rise = profile[k] - profile[k - 1];
              return rise <= 0
                  ? k.toDouble()
                  : k - 1 + (target - profile[k - 1]) / rise;
            }
          }
          return (len - 1).toDouble();
        }

        final px = crossing(0.9 * contrast) - crossing(0.1 * contrast);
        final step = stepLength[d]!;
        final raw = math.max(px, 0.0) * step;
        final floor = s.pixelFloor * step;
        final width = math.sqrt(math.max(0, raw * raw - floor * floor));
        all.add(width);
        final tile = (y * s.tiles ~/ n) * s.tiles + x * s.tiles ~/ n;
        ((perTile[tile] ??= {})[d] ??= []).add(width);
      }
    }

    // Each tile is as soft as its softest direction, judged only where it
    // has edges in two or more directions: a tile with only up–down edges
    // can't show left–right motion blur. The sharpest region is the best
    // [sharpRegionShare] of those tiles.
    final tiles = <Map<EdgeDirection, double>>[];
    for (final t in perTile.values) {
      final medians = {
        for (final e in t.entries)
          if (e.value.length >= s.minTileEdges) e.key: _median(e.value)
      };
      if (medians.length >= 2) tiles.add(medians);
    }
    double softest(Map<EdgeDirection, double> t) => t.values.reduce(math.max);
    tiles.sort((a, b) => softest(a).compareTo(softest(b)));
    final k = math.max(1, (tiles.length * s.sharpRegionShare).ceil());
    final region = tiles.length < s.minRegionTiles
        ? const <Map<EdgeDirection, double>>[]
        : tiles.take(k).toList();

    // Separately, the sharpest region in each direction on its own: the
    // best tiles' widths across that direction. Motion blur leaves one
    // direction soft everywhere while another stays crisp.
    final byDirectionRegion = <EdgeDirection, double>{};
    for (final d in EdgeDirection.values) {
      final medians = [
        for (final t in perTile.values)
          if ((t[d]?.length ?? 0) >= s.minTileEdges) _median(t[d]!)
      ]..sort();
      if (medians.length < s.minRegionTiles) continue;
      final kd = math.max(1, (medians.length * s.sharpRegionShare).ceil());
      byDirectionRegion[d] = medians.take(kd).reduce((a, b) => a + b) / kd;
    }

    var sum = 0.0, squares = 0.0;
    for (final v in luma) {
      sum += v;
      squares += v * v;
    }
    final mean = sum / luma.length;
    return BlurMeasurement(
      width: w,
      height: h,
      analysisSize: n,
      edgeCount: all.length,
      tilesJudged: tiles.length,
      blurWidth: region.isEmpty
          ? 0
          : region.map(softest).reduce((a, b) => a + b) / region.length,
      medianWidth: all.isEmpty ? 0 : _median(all),
      directionWidths: byDirectionRegion,
      spread: math.sqrt(math.max(0, squares / luma.length - mean * mean)),
      brightness: mean,
    );
  }
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}
