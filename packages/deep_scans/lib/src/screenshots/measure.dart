import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Settings for [measureScreen], taken from `ScreenshotRules`.
final class ScreenMeasureSettings {
  const ScreenMeasureSettings({
    required this.maxSamples,
    required this.flatTolerance,
    required this.colorTolerance,
    required this.topBarShare,
    required this.bottomBarShare,
    required this.markContrast,
  });

  final int maxSamples;
  final int flatTolerance;
  final int colorTolerance;
  final double topBarShare;
  final double bottomBarShare;
  final int markContrast;
}

/// What the pixels of a possible screenshot look like. Measured on the
/// full-size image, sampled on a grid without resizing: resizing would
/// average neighbouring pixels and hide exactly the flat, single-colour
/// areas that tell a rendered screen from a camera picture.
final class ScreenMeasurement {
  const ScreenMeasurement({
    required this.width,
    required this.height,
    required this.samples,
    required this.flatShare,
    required this.dominantShare,
    required this.contentDominantShare,
    required this.dominantColor,
    required this.meanLuma,
    required this.statusBar,
    required this.statusBarDetail,
  });

  final int width, height;

  /// Pixels sampled.
  final int samples;

  /// Share of sampled pixels identical (within `flatTolerance`) to their
  /// right and lower neighbours. Rendered UI: large flat areas. Camera
  /// pictures: sensor noise means almost none.
  final double flatShare;

  /// Share of the frame within `colorTolerance` of its most common colour.
  final double dominantShare;

  /// The same, leaving out the top and bottom bands where system bars sit
  /// (status bar, gesture bar, taskbar, menu bar).
  final double contentDominantShare;

  /// The most common colour, 0xRRGGBB.
  final int dominantColor;

  /// Mean brightness 0–255.
  final double meanLuma;

  /// A phone status bar across the top: small marks at the left (clock)
  /// and right (signal, battery), none in the middle or at the top edge.
  final bool statusBar;
  final String statusBarDetail;

  bool get portrait => height > width;

  /// Height over width (portrait) or width over height (landscape), ≥ 1.
  double get aspect =>
      math.max(width, height) / math.max(1, math.min(width, height));

  String get colorName {
    if (meanLuma < 40) return 'black';
    if (meanLuma > 215) return 'white';
    return '#${dominantColor.toRadixString(16).padLeft(6, '0')}';
  }

  Map<String, Object?> toJson() => {
        'width': width,
        'height': height,
        'samples': samples,
        'flatShare': _r(flatShare),
        'dominantShare': _r(dominantShare),
        'contentDominantShare': _r(contentDominantShare),
        'dominantColor': '#${dominantColor.toRadixString(16).padLeft(6, '0')}',
        'meanLuma': _r(meanLuma, 1),
        'statusBar': statusBar,
        'statusBarDetail': statusBarDetail,
      };

  String get evidence => '$width×$height, flat ${_pc(flatShare)}, '
      'dominant colour ${_pc(dominantShare)} (content '
      '${_pc(contentDominantShare)}), status bar: $statusBarDetail';
}

String _pc(double v) => '${(v * 100).toStringAsFixed(1)}%';
double _r(double v, [int digits = 4]) =>
    double.parse(v.toStringAsFixed(digits));

/// Decodes [bytes] and measures them. Returns null if they don't decode.
/// Pure and synchronous, so it can run on a background isolate.
ScreenMeasurement? measureScreen(Uint8List bytes, ScreenMeasureSettings s) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return null; // Corrupt data makes the decoders throw all sorts of errors.
  }
  if (decoded == null || decoded.width < 2 || decoded.height < 2) return null;
  var image = decoded;
  if (image.format != img.Format.uint8 ||
      image.numChannels != 3 ||
      image.hasPalette) {
    image = image.convert(
        format: img.Format.uint8, numChannels: 3, noAnimation: true);
  }
  final w = image.width, h = image.height;
  final px = image.getBytes(order: img.ChannelOrder.rgb);
  return _measure(px, w, h, s);
}

ScreenMeasurement _measure(
    Uint8List px, int w, int h, ScreenMeasureSettings s) {
  final step = math.max(1, math.sqrt(w * h / s.maxSamples).floor());
  final top = (h * s.topBarShare).round();
  final bottom = h - (h * s.bottomBarShare).round();

  int at(int x, int y) => (y * w + x) * 3;
  bool near(int a, int b, int tol) =>
      (px[a] - px[b]).abs() <= tol &&
      (px[a + 1] - px[b + 1]).abs() <= tol &&
      (px[a + 2] - px[b + 2]).abs() <= tol;
  int key(int o) => (px[o] >> 3) << 10 | (px[o + 1] >> 3) << 5 | px[o + 2] >> 3;

  // Pass 1: flatness, brightness, and the colour histogram.
  final hist = Int32List(1 << 15);
  var samples = 0, flat = 0;
  var luma = 0.0;
  for (var y = 0; y < h; y += step) {
    for (var x = 0; x < w; x += step) {
      final o = at(x, y);
      samples++;
      hist[key(o)]++;
      luma += 0.299 * px[o] + 0.587 * px[o + 1] + 0.114 * px[o + 2];
      if (x + 1 < w &&
          y + 1 < h &&
          near(o, at(x + 1, y), s.flatTolerance) &&
          near(o, at(x, y + 1), s.flatTolerance)) {
        flat++;
      }
    }
  }

  // The dominant colour: the mean of the fullest histogram bin, so a flat
  // colour split across two bins by JPEG wobble still counts as one.
  final (dr, dg, db) = _dominant(px, w, h, step, 0, h, hist, key);

  // Pass 2: share near the dominant colour, whole frame and content area.
  bool isDominant(int o) =>
      (px[o] - dr).abs() <= s.colorTolerance &&
      (px[o + 1] - dg).abs() <= s.colorTolerance &&
      (px[o + 2] - db).abs() <= s.colorTolerance;
  var dominant = 0, content = 0, contentDominant = 0;
  for (var y = 0; y < h; y += step) {
    final inContent = y >= top && y < bottom;
    for (var x = 0; x < w; x += step) {
      final o = at(x, y);
      final d = isDominant(o);
      if (d) dominant++;
      if (inContent) {
        content++;
        if (d) contentDominant++;
      }
    }
  }

  final (bar, barDetail) = h > w
      ? _statusBar(px, w, top, math.max(1, step ~/ 2), s, key)
      : (false, 'landscape: not checked');

  return ScreenMeasurement(
    width: w,
    height: h,
    samples: samples,
    flatShare: flat / samples,
    dominantShare: dominant / samples,
    contentDominantShare: content == 0 ? 0 : contentDominant / content,
    dominantColor: dr << 16 | dg << 8 | db,
    meanLuma: luma / samples,
    statusBar: bar,
    statusBarDetail: barDetail,
  );
}

(int, int, int) _dominant(Uint8List px, int w, int h, int step, int y0, int y1,
    Int32List hist, int Function(int) key) {
  var best = 0;
  for (var k = 1; k < hist.length; k++) {
    if (hist[k] > hist[best]) best = k;
  }
  var r = 0, g = 0, b = 0, n = 0;
  for (var y = y0; y < y1; y += step) {
    for (var x = 0; x < w; x += step) {
      final o = (y * w + x) * 3;
      if (key(o) == best) {
        r += px[o];
        g += px[o + 1];
        b += px[o + 2];
        n++;
      }
    }
  }
  return n == 0 ? (0, 0, 0) : (r ~/ n, g ~/ n, b ~/ n);
}

/// Looks for a phone status bar in the top [band] rows: small marks (the
/// clock; signal and battery icons) clustered at both sides, nothing in the
/// middle, and none touching the top edge. The bar's background isn't
/// required to be plain: maps and photo viewers draw under it.
(bool, String) _statusBar(Uint8List px, int w, int band, int step,
    ScreenMeasureSettings s, int Function(int) key) {
  if (band < 8) return (false, 'too short');
  final hist = Int32List(1 << 15);
  for (var y = 0; y < band; y += step) {
    for (var x = 0; x < w; x += step) {
      hist[key((y * w + x) * 3)]++;
    }
  }
  final (br, bg, bb) = _dominant(px, w, band, step, 0, band, hist, key);
  const bins = 20;
  final marksIn = List<int>.filled(bins, 0);
  final edge = math.max(1, band ~/ 10);
  var total = 0, marks = 0, atEdge = 0;
  for (var y = 0; y < band; y += step) {
    for (var x = 0; x < w; x += step) {
      final o = (y * w + x) * 3;
      total++;
      final diff = math.max((px[o] - br).abs(),
          math.max((px[o + 1] - bg).abs(), (px[o + 2] - bb).abs()));
      if (diff >= s.markContrast) {
        marks++;
        marksIn[x * bins ~/ w]++;
        if (y < edge) atEdge++;
      }
    }
  }
  final markShare = marks / total;
  int sum(int from, int to) =>
      marksIn.sublist(from, to).fold(0, (a, b) => a + b);
  final left = sum(0, 7), right = sum(13, bins), middle = sum(7, 13);
  final detail = 'marks ${_pc(markShare)} (left $left, middle $middle, '
      'right $right, at top edge $atEdge)';
  final found = markShare >= 0.003 &&
      markShare <= 0.3 &&
      math.min(left, right) >= marks * 0.15 &&
      middle <= marks * 0.1 &&
      atEdge <= marks * 0.1;
  return (found, found ? 'found, $detail' : 'none, $detail');
}
