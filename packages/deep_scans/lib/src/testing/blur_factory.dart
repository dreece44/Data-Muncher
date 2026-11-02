import 'dart:math';

import 'package:image/image.dart' as img;

import 'photo_factory.dart';

/// Synthetic photos for the blurry-photo test area and tests: the same
/// kinds of scene as [landscapeScene], spoiled in the ways phone photos get
/// spoiled (missed focus, camera shake, a moving subject) and look-alikes
/// that must not be called blurry (portrait-mode backgrounds, fog, night
/// shots, small or heavily compressed copies).

/// What a decent phone lens does to a perfectly sharp synthetic scene: a
/// touch of softness plus sensor noise, so "sharp" test photos aren't
/// unrealistically crisp.
img.Image cameraSharp(img.Image scene, int seed, {int noise = 3}) =>
    adjustPhoto(
        img.gaussianBlur(img.Image.from(scene), radius: 1), seed, noise);

/// Out of focus: a Gaussian blur of [radius] pixels, then sensor noise.
img.Image outOfFocus(img.Image scene, int radius, int seed, {int noise = 3}) =>
    adjustPhoto(
        img.gaussianBlur(img.Image.from(scene), radius: radius), seed, noise);

/// Camera shake or a moving subject: every pixel averaged along a
/// [length]-pixel line at [angle] degrees (0 = left–right).
img.Image motionBlur(img.Image scene, int length, double angle, int seed,
    {int noise = 3}) {
  final w = scene.width, h = scene.height;
  final out = img.Image(width: w, height: h);
  final dx = cos(angle * pi / 180), dy = sin(angle * pi / 180);
  final offsets = [
    for (var t = 0; t < length; t++)
      (
        ((t - (length - 1) / 2) * dx).round(),
        ((t - (length - 1) / 2) * dy).round()
      )
  ];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var r = 0, g = 0, b = 0;
      for (final (ox, oy) in offsets) {
        final p =
            scene.getPixel((x + ox).clamp(0, w - 1), (y + oy).clamp(0, h - 1));
        r += p.r.toInt();
        g += p.g.toInt();
        b += p.b.toInt();
      }
      final k = offsets.length;
      out.setPixelRgb(x, y, r ~/ k, g ~/ k, b ~/ k);
    }
  }
  return adjustPhoto(out, seed, noise);
}

/// Portrait mode: the middle of [scene] stays sharp, everything around it
/// is blurred with [radius]. Only the subject's share of the frame
/// ([subjectShare] of each side) is in focus.
img.Image portraitMode(img.Image scene, int radius, int seed,
    {double subjectShare = 0.4}) {
  final background = img.gaussianBlur(img.Image.from(scene), radius: radius);
  final sw = (scene.width * subjectShare).round();
  final sh = (scene.height * subjectShare).round();
  final x0 = (scene.width - sw) ~/ 2, y0 = (scene.height - sh) ~/ 2;
  final subject = img.copyCrop(
      img.gaussianBlur(img.Image.from(scene), radius: 1),
      x: x0,
      y: y0,
      width: sw,
      height: sh);
  return adjustPhoto(
      img.compositeImage(background, subject, dstX: x0, dstY: y0), seed, 3);
}

/// A panning shot: the middle band (the moving subject the camera
/// followed) is sharp; the background is streaked left–right.
img.Image panningShot(img.Image scene, int length, int seed) {
  final streaked = motionBlur(scene, length, 0, seed, noise: 0);
  final sw = scene.width * 2 ~/ 5, sh = scene.height * 2 ~/ 5;
  final x0 = (scene.width - sw) ~/ 2, y0 = (scene.height - sh) ~/ 2;
  final subject = img.copyCrop(
      img.gaussianBlur(img.Image.from(scene), radius: 1),
      x: x0,
      y: y0,
      width: sw,
      height: sh);
  return adjustPhoto(
      img.compositeImage(streaked, subject, dstX: x0, dstY: y0), seed, 3);
}

/// Fog, a clear sky or a plain wall: smooth brightness changes and nothing
/// with an edge, so there's no way to tell whether it's in focus.
img.Image featureless(int seed, int w, int h) {
  final r = Random(seed);
  final im = img.Image(width: w, height: h);
  final top = 150 + r.nextInt(60), bottom = 90 + r.nextInt(60);
  final cx = r.nextDouble() * w, cy = r.nextDouble() * h;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final base = top + (bottom - top) * y / h;
      final glow = 25 * exp(-(pow(x - cx, 2) + pow(y - cy, 2)) / (w * w / 4));
      final v = (base + glow).round().clamp(0, 255);
      im.setPixelRgb(x, y, v, v, (v + 12).clamp(0, 255));
    }
  }
  return adjustPhoto(im, seed, 2);
}

/// A night street: dark, noisy, with small bright lights and lit windows.
/// [blurRadius] above 0 makes it an out-of-focus night shot.
img.Image nightScene(int seed, int w, int h, {int blurRadius = 0}) {
  final r = Random(seed);
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(14, 14, 22));
  for (var i = 0; i < 14; i++) {
    final x = r.nextInt(w), bw = w ~/ 14 + r.nextInt(w ~/ 8);
    final top = h ~/ 4 + r.nextInt(h ~/ 3);
    img.fillRect(im,
        x1: x, y1: top, x2: x + bw, y2: h, color: img.ColorRgb8(30, 28, 36));
    for (var k = 0; k < 10; k++) {
      final wx = x + r.nextInt(bw), wy = top + r.nextInt(h - top);
      img.fillRect(im,
          x1: wx,
          y1: wy,
          x2: wx + w ~/ 90,
          y2: wy + h ~/ 60,
          color: img.ColorRgb8(230, 200, 120));
    }
  }
  for (var i = 0; i < 30; i++) {
    img.fillCircle(im,
        x: r.nextInt(w),
        y: h * 2 ~/ 3 + r.nextInt(h ~/ 3),
        radius: 2 + r.nextInt(5),
        color: img.ColorRgb8(255, 240, 200));
  }
  final focused = blurRadius > 0
      ? img.gaussianBlur(im, radius: blurRadius)
      : img.gaussianBlur(im, radius: 1);
  return adjustPhoto(focused, seed, 6);
}
