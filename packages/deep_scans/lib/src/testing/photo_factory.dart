import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Synthetic photos for the duplicate-photo test area and tests: scenes
/// with photo-like structure that can be reframed, re-lit, blurred and
/// copied in controlled ways.

/// A photo-like scene: sky and ground gradients, large objects, fine
/// detail. Bigger than the photo so windows into it act like reframing.
img.Image landscapeScene(int seed, int w, int h) {
  final r = Random(seed);
  final im = img.Image(width: w, height: h);
  final sky = [r.nextInt(120) + 100, r.nextInt(120) + 100, 255];
  final ground = [r.nextInt(150), r.nextInt(150) + 60, r.nextInt(100)];
  final horizon = h * (0.35 + r.nextDouble() * 0.3);
  for (var y = 0; y < h; y++) {
    final above = y < horizon;
    final t = above ? y / horizon : (y - horizon) / (h - horizon);
    final c = above ? sky : ground;
    final k = above ? 1 - 0.4 * t : 1 - 0.5 * t;
    final color = img.ColorRgb8(
        (c[0] * k).round(), (c[1] * k).round(), (c[2] * k).round());
    img.drawLine(im, x1: 0, y1: y, x2: w - 1, y2: y, color: color);
  }
  img.Color col() =>
      img.ColorRgb8(r.nextInt(256), r.nextInt(256), r.nextInt(256));
  for (var i = 0; i < 6; i++) {
    img.fillCircle(im,
        x: r.nextInt(w),
        y: (horizon + r.nextInt((h - horizon).round())).round(),
        radius: w ~/ 12 + r.nextInt(w ~/ 6),
        color: col());
  }
  for (var i = 0; i < 10; i++) {
    final x = r.nextInt(w), y = r.nextInt(h);
    img.fillRect(im,
        x1: x,
        y1: y,
        x2: x + w ~/ 30 + r.nextInt(w ~/ 8),
        y2: y + h ~/ 30 + r.nextInt(h ~/ 6),
        color: col());
  }
  for (var i = 0; i < 80; i++) {
    img.fillCircle(im,
        x: r.nextInt(w),
        y: r.nextInt(h),
        radius: 2 + r.nextInt(w ~/ 80 + 1),
        color: col());
  }
  return im;
}

img.Image reframe(img.Image c, double fx, double fy, int w, int h) =>
    img.copyCrop(c,
        x: (fx * (c.width - w)).round(),
        y: (fy * (c.height - h)).round(),
        width: w,
        height: h);

/// Sensor noise plus optional brightness/contrast change.
img.Image adjustPhoto(img.Image s, int seed, int noise,
    {int brightness = 0, double contrast = 1}) {
  final r = Random(seed);
  final o = img.Image.from(s);
  for (final px in o) {
    int v(num c) => (((c - 128) * contrast + 128) +
            brightness +
            r.nextInt(2 * noise + 1) -
            noise)
        .round()
        .clamp(0, 255);
    px
      ..r = v(px.r)
      ..g = v(px.g)
      ..b = v(px.b);
  }
  return o;
}

/// The photo on a white square, as apps that need square posts add.
img.Image letterboxSquare(img.Image photo) {
  final side = photo.width > photo.height ? photo.height : photo.width;
  final square = img.Image(width: side, height: side);
  img.fill(square, color: img.ColorRgb8(255, 255, 255));
  final scaled = img.copyResize(photo, width: side);
  return img.compositeImage(square, scaled, dstY: (side - scaled.height) ~/ 2);
}

/// A receipt on a wooden table: white paper with "text" bars. Different
/// seeds give different text in the same layout.
img.Image receiptPhoto(int seed, {double dx = 0, double dy = 0}) {
  const w = 900, h = 1200;
  final r = Random(seed);
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(140, 95, 60));
  final ox = (dx * w).round(), oy = (dy * h).round();
  img.fillRect(im,
      x1: 225 + ox,
      y1: 90 + oy,
      x2: 675 + ox,
      y2: 1110 + oy,
      color: img.ColorRgb8(245, 245, 240));
  for (var y = 150; y < 1050; y += 36) {
    var x = 255;
    while (x < 645) {
      final word = 15 + r.nextInt(75);
      if (x + word > 645) break;
      img.fillRect(im,
          x1: x + ox,
          y1: y + oy,
          x2: x + word + ox,
          y2: y + 12 + oy,
          color: img.ColorRgb8(30, 30, 30));
      x += word + 12;
    }
  }
  return im;
}

/// A phone chat screenshot: status bar, title bar, message bubbles.
Uint8List encodeJpeg(img.Image image, int quality) =>
    img.encodeJpg(image, quality: quality);
