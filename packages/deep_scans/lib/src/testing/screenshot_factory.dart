import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'photo_factory.dart';

/// Synthetic screenshots for the screenshot test area and tests: phone and
/// computer screens drawn the way apps draw them (flat colours, system
/// bars, text as solid bars), plus the metadata screenshot tools and
/// cameras write, so every screenshot signal can be planted on its own.

// --- Phone screens ----------------------------------------------------------

/// What a phone screen holds.
enum PhoneApp { chat, feed, article, maps, settings, ticket }

/// A phone screenshot of [app], [w]×[h], with a status bar on top and a
/// gesture bar at the bottom.
img.Image phoneScreenshot(PhoneApp app, int seed,
    {int w = 1080, int h = 2400, bool dark = false}) {
  final r = Random(seed);
  final bg = dark ? img.ColorRgb8(18, 18, 18) : img.ColorRgb8(255, 255, 255);
  final ink = dark ? img.ColorRgb8(230, 230, 230) : img.ColorRgb8(33, 33, 33);
  final im = img.Image(width: w, height: h);
  img.fill(im, color: bg);
  final bar = (h * 0.035).round();
  final title = (h * 0.07).round();
  final top = bar + title;
  final u = w / 1080; // layout unit: 1 at 1080 px wide

  switch (app) {
    case PhoneApp.chat:
      img.fill(im,
          color:
              dark ? img.ColorRgb8(11, 20, 26) : img.ColorRgb8(236, 229, 221));
      img.fillRect(im,
          x1: 0, y1: 0, x2: w, y2: top, color: img.ColorRgb8(7, 94, 84));
      _textLine(im, (120 * u).round(), bar + title ~/ 3, (360 * u).round(),
          (title / 3).round(), img.ColorRgb8(255, 255, 255));
      var y = top + (40 * u).round();
      while (y < h - (260 * u).round()) {
        final mine = r.nextBool();
        final bw = ((300 + r.nextInt(500)) * u).round();
        final lines = 1 + r.nextInt(4);
        final bh = ((40 + lines * 50) * u).round();
        final x = mine ? w - (40 * u).round() - bw : (40 * u).round();
        img.fillRect(im,
            x1: x,
            y1: y,
            x2: x + bw,
            y2: y + bh,
            radius: (24 * u).round(),
            color: mine
                ? (dark
                    ? img.ColorRgb8(0, 92, 75)
                    : img.ColorRgb8(220, 248, 198))
                : (dark
                    ? img.ColorRgb8(32, 44, 51)
                    : img.ColorRgb8(255, 255, 255)));
        for (var l = 0; l < lines; l++) {
          final len = ((100 + r.nextInt(max(1, bw ~/ u - 140))) * u).round();
          _textLine(im, x + (30 * u).round(), y + ((30 + l * 50) * u).round(),
              len, (25 * u).round(), ink);
        }
        y += bh + ((30 + r.nextInt(40)) * u).round();
      }
      // Message box.
      img.fillRect(im,
          x1: (20 * u).round(),
          y1: h - (230 * u).round(),
          x2: w - (20 * u).round(),
          y2: h - (110 * u).round(),
          radius: (60 * u).round(),
          color:
              dark ? img.ColorRgb8(32, 44, 51) : img.ColorRgb8(255, 255, 255));
    case PhoneApp.feed:
      _titleBar(im, bar, title, bg, ink, u);
      var y = top;
      var post = 0;
      while (y < h - (200 * u).round()) {
        // Header: avatar and name.
        img.fillCircle(im,
            x: (80 * u).round(),
            y: y + (70 * u).round(),
            radius: (40 * u).round(),
            color:
                img.ColorRgb8(r.nextInt(200), r.nextInt(200), r.nextInt(200)));
        _textLine(im, (140 * u).round(), y + (55 * u).round(),
            ((200 + r.nextInt(200)) * u).round(), (28 * u).round(), ink);
        y += (140 * u).round();
        // The photo in the post: a real-looking picture inside the UI.
        final ph = min(w, h - (200 * u).round() - y);
        if (ph > 0) {
          final photo = cameraLike(seed * 10 + post++, w, ph);
          img.compositeImage(im, photo, dstY: y);
        }
        y += ph + (30 * u).round();
        for (var l = 0; l < 2; l++) {
          _textLine(im, (40 * u).round(), y,
              ((400 + r.nextInt(500)) * u).round(), (26 * u).round(), ink);
          y += (50 * u).round();
        }
        y += (40 * u).round();
      }
    case PhoneApp.article:
      _titleBar(im, bar, title, bg, ink, u);
      var y = top + (60 * u).round();
      // Headline, a hero picture, then paragraphs.
      for (var l = 0; l < 2; l++) {
        _textLine(im, (50 * u).round(), y, ((700 + r.nextInt(250)) * u).round(),
            (52 * u).round(), ink);
        y += (80 * u).round();
      }
      y += (30 * u).round();
      final hero = cameraLike(seed + 500, w, (600 * u).round());
      img.compositeImage(im, hero, dstY: y);
      y += hero.height + (60 * u).round();
      while (y < h - (180 * u).round()) {
        final lines = 3 + r.nextInt(5);
        for (var l = 0; l < lines && y < h - (180 * u).round(); l++) {
          final len = l == lines - 1
              ? ((200 + r.nextInt(500)) * u).round()
              : ((900 + r.nextInt(80)) * u).round();
          _textLine(im, (50 * u).round(), y, len, (28 * u).round(), ink);
          y += (52 * u).round();
        }
        y += (40 * u).round();
      }
    case PhoneApp.maps:
      img.fill(im, color: img.ColorRgb8(232, 234, 237));
      // Parks, water, roads, a route and pins.
      for (var i = 0; i < 6; i++) {
        final x = r.nextInt(w), y = r.nextInt(h);
        img.fillRect(im,
            x1: x,
            y1: y,
            x2: x + (150 + r.nextInt(350)) * u ~/ 1,
            y2: y + (150 + r.nextInt(450)) * u ~/ 1,
            color: i.isEven
                ? img.ColorRgb8(197, 232, 197)
                : img.ColorRgb8(170, 218, 255));
      }
      for (var i = 0; i < 14; i++) {
        final horizontal = i.isEven;
        final at = r.nextInt(horizontal ? h : w);
        img.fillRect(im,
            x1: horizontal ? 0 : at,
            y1: horizontal ? at : 0,
            x2: horizontal ? w : at + (18 * u).round(),
            y2: horizontal ? at + (18 * u).round() : h,
            color: img.ColorRgb8(255, 255, 255));
      }
      var px = w ~/ 4, py = h * 3 ~/ 4;
      for (var i = 0; i < 6; i++) {
        final nx = (px + r.nextInt(w ~/ 3) - w ~/ 8).clamp(0, w - 1);
        final ny = (py - r.nextInt(h ~/ 6)).clamp(0, h - 1);
        img.drawLine(im,
            x1: px,
            y1: py,
            x2: nx,
            y2: ny,
            color: img.ColorRgb8(66, 133, 244),
            thickness: 14 * u);
        px = nx;
        py = ny;
      }
      img.fillCircle(im,
          x: px,
          y: py,
          radius: (30 * u).round(),
          color: img.ColorRgb8(219, 68, 55));
      img.fillRect(im,
          x1: (30 * u).round(),
          y1: bar + (30 * u).round(),
          x2: w - (30 * u).round(),
          y2: bar + (160 * u).round(),
          radius: (65 * u).round(),
          color: img.ColorRgb8(255, 255, 255));
      _textLine(im, (120 * u).round(), bar + (80 * u).round(),
          (420 * u).round(), (30 * u).round(), img.ColorRgb8(95, 99, 104));
    case PhoneApp.settings:
      _titleBar(im, bar, title, bg, ink, u);
      var y = top + (30 * u).round();
      while (y < h - (200 * u).round()) {
        img.fillCircle(im,
            x: (90 * u).round(),
            y: y + (55 * u).round(),
            radius: (34 * u).round(),
            color:
                img.ColorRgb8(60 + r.nextInt(150), 60 + r.nextInt(150), 200));
        _textLine(im, (170 * u).round(), y + (30 * u).round(),
            ((250 + r.nextInt(300)) * u).round(), (30 * u).round(), ink);
        _textLine(
            im,
            (170 * u).round(),
            y + (75 * u).round(),
            ((300 + r.nextInt(300)) * u).round(),
            (22 * u).round(),
            img.ColorRgb8(120, 120, 120));
        y += (150 * u).round();
      }
    case PhoneApp.ticket:
      _titleBar(im, bar, title, bg, ink, u);
      img.fillRect(im,
          x1: (60 * u).round(),
          y1: top + (80 * u).round(),
          x2: w - (60 * u).round(),
          y2: h - (300 * u).round(),
          radius: (40 * u).round(),
          color: img.ColorRgb8(25, 103, 210));
      for (var l = 0; l < 5; l++) {
        _textLine(
            im,
            (120 * u).round(),
            top + ((160 + l * 90) * u).round(),
            ((300 + r.nextInt(400)) * u).round(),
            (40 * u).round(),
            img.ColorRgb8(255, 255, 255));
      }
      // A QR code.
      final q = (520 * u).round(), qx = (w - q) ~/ 2, qy = h ~/ 2;
      img.fillRect(im,
          x1: qx - 30,
          y1: qy - 30,
          x2: qx + q + 30,
          y2: qy + q + 30,
          color: img.ColorRgb8(255, 255, 255));
      final cell = q ~/ 29;
      for (var cy = 0; cy < 29; cy++) {
        for (var cx = 0; cx < 29; cx++) {
          if (r.nextBool()) {
            img.fillRect(im,
                x1: qx + cx * cell,
                y1: qy + cy * cell,
                x2: qx + (cx + 1) * cell - 1,
                y2: qy + (cy + 1) * cell - 1,
                color: img.ColorRgb8(0, 0, 0));
          }
        }
      }
  }
  phoneStatusBar(im, dark: dark || app == PhoneApp.chat);
  phoneGestureBar(im, dark: dark);
  return im;
}

/// A screen with nothing on it but [color]: what a phone saves when an app
/// blocks screenshots (black), or a page that hadn't loaded yet (white).
/// With [bars], the status and gesture bars are still drawn over it.
img.Image blankScreen(int w, int h, img.Color color, {bool bars = false}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: color);
  if (bars) {
    final dark = color.luminanceNormalized < 0.5;
    phoneStatusBar(im, dark: dark);
    phoneGestureBar(im, dark: dark);
  }
  return im;
}

/// One line of text on an otherwise empty note: a Wi-Fi password, a
/// confirmation code. Mostly blank, but the line is the point.
img.Image noteScreenshot(int seed, {int w = 1080, int h = 2400}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(255, 255, 255));
  final u = w / 1080;
  final ink = img.ColorRgb8(33, 33, 33);
  _titleBar(im, (h * 0.035).round(), (h * 0.07).round(),
      img.ColorRgb8(255, 255, 255), ink, u);
  _textLine(im, (60 * u).round(), (h * 0.16).round(), (620 * u).round(),
      (44 * u).round(), ink);
  phoneStatusBar(im);
  phoneGestureBar(im);
  return im;
}

/// Android-style status bar: clock on the left, icons and battery on the
/// right, drawn over whatever is at the top of [im].
void phoneStatusBar(img.Image im, {bool dark = false}) {
  final w = im.width, h = (im.height * 0.035).round();
  final u = w / 1080;
  final ink = dark ? img.ColorRgb8(255, 255, 255) : img.ColorRgb8(0, 0, 0);
  final y = h ~/ 3, th = max(4, h ~/ 3);
  // Clock "12:45".
  for (var i = 0; i < 4; i++) {
    final x = ((50 + i * 34 + (i > 1 ? 16 : 0)) * u).round();
    img.fillRect(im,
        x1: x, y1: y, x2: x + (24 * u).round(), y2: y + th, color: ink);
  }
  // Signal, wifi, battery.
  final right = w - (60 * u).round();
  img.fillRect(im,
      x1: right - (70 * u).round(), y1: y, x2: right, y2: y + th, color: ink);
  for (var i = 0; i < 4; i++) {
    final x = right - ((200 - i * 22) * u).round();
    img.fillRect(im,
        x1: x,
        y1: y + th - (th * (i + 1)) ~/ 4,
        x2: x + (14 * u).round(),
        y2: y + th,
        color: ink);
  }
}

/// The gesture pill at the bottom of a modern phone screen.
void phoneGestureBar(img.Image im, {bool dark = false}) {
  final w = im.width, h = im.height;
  final u = w / 1080;
  img.fillRect(im,
      x1: w ~/ 2 - (140 * u).round(),
      y1: h - (40 * u).round(),
      x2: w ~/ 2 + (140 * u).round(),
      y2: h - (28 * u).round(),
      radius: (6 * u).round(),
      color: dark ? img.ColorRgb8(200, 200, 200) : img.ColorRgb8(60, 60, 60));
}

// --- Computer screens -------------------------------------------------------

/// What a computer screen holds.
enum DesktopApp { slides, document, browser, code }

/// A computer screenshot: wallpaper, one app window, and a taskbar.
img.Image desktopScreenshot(DesktopApp app, int seed,
    {int w = 1920, int h = 1080, bool taskbar = true}) {
  final r = Random(seed);
  final im = img.Image(width: w, height: h);
  // Wallpaper: a smooth gradient, as desktop wallpapers often are.
  for (var y = 0; y < h; y++) {
    final t = y / h;
    img.drawLine(im,
        x1: 0,
        y1: y,
        x2: w - 1,
        y2: y,
        color: img.ColorRgb8((20 + 40 * t).round(), (60 + 50 * t).round(),
            (120 + 60 * t).round()));
  }
  final tb = taskbar ? (h * 0.045).round() : 0;
  final u = h / 1080;
  final wx = (w * 0.06).round(), wy = (h * 0.05).round();
  final ww = (w * 0.88).round(), wh = h - tb - wy * 2;
  final ink = img.ColorRgb8(32, 32, 32);
  // Window and title bar.
  img.fillRect(im,
      x1: wx,
      y1: wy,
      x2: wx + ww,
      y2: wy + wh,
      color: img.ColorRgb8(255, 255, 255));
  img.fillRect(im,
      x1: wx,
      y1: wy,
      x2: wx + ww,
      y2: wy + (40 * u).round(),
      color: img.ColorRgb8(243, 243, 243));
  for (var i = 0; i < 3; i++) {
    final x = wx + ww - ((40 + i * 60) * u).round();
    img.fillRect(im,
        x1: x,
        y1: wy + (14 * u).round(),
        x2: x + (16 * u).round(),
        y2: wy + (26 * u).round(),
        color: ink);
  }
  // Toolbar.
  final tool = wy + (40 * u).round();
  img.fillRect(im,
      x1: wx,
      y1: tool,
      x2: wx + ww,
      y2: tool + (90 * u).round(),
      color: switch (app) {
        DesktopApp.slides => img.ColorRgb8(196, 62, 28),
        DesktopApp.document => img.ColorRgb8(43, 87, 154),
        DesktopApp.browser => img.ColorRgb8(222, 225, 230),
        DesktopApp.code => img.ColorRgb8(60, 60, 60),
      });
  for (var i = 0; i < 12; i++) {
    final x = wx + ((30 + i * 70) * u).round();
    img.fillRect(im,
        x1: x,
        y1: tool + (30 * u).round(),
        x2: x + (40 * u).round(),
        y2: tool + (60 * u).round(),
        color: img.ColorRgb8(255, 255, 255));
  }
  final cx = wx, cy = tool + (90 * u).round();
  final cw = ww, ch = wy + wh - cy;
  switch (app) {
    case DesktopApp.slides:
      img.fillRect(im,
          x1: cx,
          y1: cy,
          x2: cx + cw,
          y2: cy + ch,
          color: img.ColorRgb8(230, 230, 230));
      // Slide thumbnails and the slide being edited.
      for (var i = 0; i < 5; i++) {
        final y = cy + ((20 + i * 140) * u).round();
        img.fillRect(im,
            x1: cx + (20 * u).round(),
            y1: y,
            x2: cx + (220 * u).round(),
            y2: y + (112 * u).round(),
            color: img.ColorRgb8(255, 255, 255));
      }
      final sx = cx + (280 * u).round(), sy = cy + (40 * u).round();
      final sw = cw - (330 * u).round(), sh = (sw * 9 / 16).round();
      img.fillRect(im,
          x1: sx,
          y1: sy,
          x2: sx + sw,
          y2: min(cy + ch, sy + sh),
          color: img.ColorRgb8(255, 255, 255));
      _textLine(im, sx + (80 * u).round(), sy + (80 * u).round(),
          (sw * 0.6).round(), (60 * u).round(), ink);
      final chart =
          cameraLike(seed + 7, (sw * 0.4).round(), (sh * 0.5).round());
      img.compositeImage(im, chart,
          dstX: sx + (sw * 0.55).round(), dstY: sy + (sh * 0.35).round());
      for (var l = 0; l < 5; l++) {
        _textLine(im, sx + (80 * u).round(), sy + ((220 + l * 60) * u).round(),
            ((300 + r.nextInt(300)) * u).round(), (26 * u).round(), ink);
      }
    case DesktopApp.document:
      img.fillRect(im,
          x1: cx,
          y1: cy,
          x2: cx + cw,
          y2: cy + ch,
          color: img.ColorRgb8(240, 240, 240));
      final px = cx + cw ~/ 2 - (420 * u).round();
      img.fillRect(im,
          x1: px,
          y1: cy + (20 * u).round(),
          x2: px + (840 * u).round(),
          y2: cy + ch,
          color: img.ColorRgb8(255, 255, 255));
      var y = cy + (90 * u).round();
      while (y < cy + ch - (40 * u).round()) {
        final len = ((500 + r.nextInt(220)) * u).round();
        _textLine(im, px + (60 * u).round(), y, len, (14 * u).round(), ink);
        y += (30 * u).round();
        if (r.nextInt(7) == 0) y += (30 * u).round();
      }
    case DesktopApp.browser:
      var y = cy + (40 * u).round();
      final hero =
          cameraLike(seed + 3, cw - (200 * u).round(), (380 * u).round());
      img.compositeImage(im, hero, dstX: cx + (100 * u).round(), dstY: y);
      y += hero.height + (40 * u).round();
      while (y < cy + ch - (30 * u).round()) {
        _textLine(im, cx + (100 * u).round(), y,
            ((800 + r.nextInt(600)) * u).round(), (18 * u).round(), ink);
        y += (36 * u).round();
      }
    case DesktopApp.code:
      img.fillRect(im,
          x1: cx,
          y1: cy,
          x2: cx + cw,
          y2: cy + ch,
          color: img.ColorRgb8(30, 30, 30));
      var y = cy + (20 * u).round();
      while (y < cy + ch - (20 * u).round()) {
        final indent = r.nextInt(4) * (40 * u).round();
        _textLine(
            im,
            cx + (80 * u).round() + indent,
            y,
            ((150 + r.nextInt(600)) * u).round(),
            (14 * u).round(),
            img.ColorRgb8(100 + r.nextInt(155), 100 + r.nextInt(155),
                100 + r.nextInt(155)));
        y += (26 * u).round();
      }
  }
  if (taskbar) _taskbar(im, tb);
  return im;
}

/// A computer screen that's black apart from the taskbar: a full-screen
/// video whose player blocks screen capture.
img.Image blankDesktop({int w = 1920, int h = 1080}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(0, 0, 0));
  _taskbar(im, (h * 0.045).round());
  return im;
}

/// A frame from a game: a rendered scene (no sensor noise) with a HUD.
img.Image gameScreenshot(int seed, {int w = 1920, int h = 1080}) {
  final im = reframe(landscapeScene(seed, w + 200, h + 150), .5, .5, w, h);
  final r = Random(seed);
  final u = h / 1080;
  // Health bar, minimap, hotbar.
  img.fillRect(im,
      x1: (40 * u).round(),
      y1: (40 * u).round(),
      x2: (440 * u).round(),
      y2: (70 * u).round(),
      color: img.ColorRgb8(40, 40, 40));
  img.fillRect(im,
      x1: (44 * u).round(),
      y1: (44 * u).round(),
      x2: ((44 + 250 + r.nextInt(140)) * u).round(),
      y2: (66 * u).round(),
      color: img.ColorRgb8(200, 30, 30));
  img.fillCircle(im,
      x: w - (160 * u).round(),
      y: (160 * u).round(),
      radius: (120 * u).round(),
      color: img.ColorRgb8(30, 50, 40));
  for (var i = 0; i < 8; i++) {
    final x = w ~/ 2 - (8 * 50 * u).round() + (i * 100 * u).round();
    img.fillRect(im,
        x1: x,
        y1: h - (110 * u).round(),
        x2: x + (90 * u).round(),
        y2: h - (20 * u).round(),
        color: img.ColorRgb8(20, 20, 20));
  }
  return im;
}

void _taskbar(img.Image im, int tb) {
  final w = im.width, h = im.height;
  img.fillRect(im,
      x1: 0, y1: h - tb, x2: w, y2: h, color: img.ColorRgb8(32, 32, 32));
  for (var i = 0; i < 8; i++) {
    final x = w ~/ 2 - 4 * tb + i * tb;
    img.fillRect(im,
        x1: x + tb ~/ 4,
        y1: h - tb + tb ~/ 4,
        x2: x + tb * 3 ~/ 4,
        y2: h - tb ~/ 4,
        color: img.ColorRgb8(80 + i * 20, 140, 220 - i * 15));
  }
  // Clock.
  img.fillRect(im,
      x1: w - tb * 3,
      y1: h - tb + tb ~/ 3,
      x2: w - tb,
      y2: h - tb ~/ 3,
      color: img.ColorRgb8(255, 255, 255));
}

// --- Look-alikes ------------------------------------------------------------

/// A camera picture [w]×[h]: a scene with lens softness and sensor noise.
img.Image cameraLike(int seed, int w, int h) => adjustPhoto(
    img.gaussianBlur(
        reframe(landscapeScene(seed, w + w ~/ 6, h + h ~/ 6), .5, .5, w, h),
        radius: 1),
    seed,
    3);

/// A designed graphic with flat colours but no system bars: a story post,
/// a slide or diagram exported from an app.
img.Image flatGraphic(int seed, int w, int h) {
  final r = Random(seed);
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(250, 214, 165));
  final u = min(w, h) / 1080;
  img.fillCircle(im,
      x: w ~/ 2,
      y: h * 2 ~/ 5,
      radius: (300 * u).round(),
      color: img.ColorRgb8(214, 92, 72));
  for (var i = 0; i < 4; i++) {
    final y = (h * (0.65 + i * 0.06)).round();
    final len = ((500 + r.nextInt(300)) * u).round();
    _textLine(im, (w - len) ~/ 2, y, len, (48 * u).round(),
        img.ColorRgb8(70, 40, 30));
  }
  for (var i = 0; i < 10; i++) {
    img.fillRect(im,
        x1: r.nextInt(w),
        y1: r.nextInt(h),
        x2: r.nextInt(w),
        y2: r.nextInt(h),
        color: img.ColorRgb8(255, 255, 255));
  }
  return im;
}

/// A photo of a computer screen taken with a camera: the screen sits in a
/// room, slightly soft and noisy.
img.Image photoOfScreen(int seed, int w, int h) {
  final room = reframe(landscapeScene(seed, w + 200, h + 150), .5, .5, w, h);
  final screen = img.copyResize(desktopScreenshot(DesktopApp.slides, seed),
      width: w * 2 ~/ 3);
  img.compositeImage(room, screen,
      dstX: w ~/ 6, dstY: (h - screen.height) ~/ 2);
  return adjustPhoto(img.gaussianBlur(room, radius: 1), seed, 4);
}

void _titleBar(
    img.Image im, int bar, int title, img.Color bg, img.Color ink, double u) {
  img.fillRect(im, x1: 0, y1: 0, x2: im.width, y2: bar + title, color: bg);
  _textLine(im, (60 * u).round(), bar + title ~/ 3, (300 * u).round(),
      (title / 3).round(), ink);
  img.drawLine(im,
      x1: 0,
      y1: bar + title,
      x2: im.width,
      y2: bar + title,
      color: img.ColorRgb8(220, 220, 220),
      thickness: max(1, 2 * u));
}

void _textLine(img.Image im, int x, int y, int len, int height, img.Color c) {
  // Words: bars with gaps, as text looks from a distance.
  final r = Random(x * 31 + y);
  var at = x;
  while (at < x + len) {
    final word = min(x + len - at, height + r.nextInt(height * 4));
    img.fillRect(im, x1: at, y1: y, x2: at + word, y2: y + height, color: c);
    at += word + max(2, height ~/ 2);
  }
}

// --- Metadata ---------------------------------------------------------------

/// What a phone or computer camera writes into a JPEG: make, model and
/// exposure details.
const cameraExif = ExifFields(
  make: 'samsung',
  model: 'SM-S921B',
  exposureTime: (1, 120),
  fNumber: (18, 10),
  focalLength: (63, 10),
  iso: 64,
);

/// Fields for [exifJpeg] / [exifTiff]. Unset fields aren't written.
final class ExifFields {
  const ExifFields({
    this.make,
    this.model,
    this.software,
    this.userComment,
    this.exposureTime,
    this.fNumber,
    this.focalLength,
    this.iso,
  });

  final String? make, model, software, userComment;
  final (int, int)? exposureTime, fNumber, focalLength;
  final int? iso;
}

/// A little-endian TIFF block holding [f]: IFD0 (make, model, software) and
/// an Exif IFD (exposure, aperture, focal length, ISO, user comment).
Uint8List exifTiff(ExifFields f) {
  // Entries: (tag, type, count, value bytes).
  final ifd0 = <(int, int, int, List<int>)>[
    if (f.make != null) _ascii(0x010F, f.make!),
    if (f.model != null) _ascii(0x0110, f.model!),
    if (f.software != null) _ascii(0x0131, f.software!),
  ];
  final exif = <(int, int, int, List<int>)>[
    if (f.exposureTime != null) _rational(0x829A, f.exposureTime!),
    if (f.fNumber != null) _rational(0x829D, f.fNumber!),
    if (f.iso != null) (0x8827, 3, 1, [f.iso! & 0xFF, f.iso! >> 8]),
    if (f.focalLength != null) _rational(0x920A, f.focalLength!),
    if (f.userComment != null)
      (
        0x9286,
        7,
        8 + f.userComment!.length,
        [..._latin('ASCII\x00\x00\x00'), ..._latin(f.userComment!)]
      ),
  ];
  final hasExif = exif.isNotEmpty;
  if (hasExif) ifd0.add((0x8769, 4, 1, const [0, 0, 0, 0]));

  final out = BytesBuilder();
  out.add(const [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]);
  int ifdSize(int n) => 2 + n * 12 + 4;
  int dataSize(List<(int, int, int, List<int>)> es) => es.fold(
      0, (s, e) => s + (e.$4.length > 4 ? e.$4.length + (e.$4.length & 1) : 0));
  final ifd0At = 8;
  final ifd0Data = ifd0At + ifdSize(ifd0.length);
  final exifAt = ifd0Data + dataSize(ifd0);
  final exifData = exifAt + ifdSize(exif.length);

  List<int> writeIfd(List<(int, int, int, List<int>)> es, int dataAt) {
    final head = BytesBuilder(), data = BytesBuilder();
    head.add(_u16(es.length));
    var at = dataAt;
    for (final (tag, type, count, value) in es) {
      head
        ..add(_u16(tag))
        ..add(_u16(type))
        ..add(_u32(count));
      if (tag == 0x8769) {
        head.add(_u32(exifAt));
      } else if (value.length <= 4) {
        head.add([...value, ...List.filled(4 - value.length, 0)]);
      } else {
        head.add(_u32(at));
        data.add(value);
        if (value.length.isOdd) data.addByte(0);
        at += value.length + (value.length & 1);
      }
    }
    head.add(_u32(0));
    return [...head.takeBytes(), ...data.takeBytes()];
  }

  out.add(writeIfd(ifd0, ifd0Data));
  if (hasExif) out.add(writeIfd(exif, exifData));
  return out.takeBytes();
}

/// [jpeg] with an Exif APP1 segment holding [f], as a camera writes it.
Uint8List exifJpeg(Uint8List jpeg, ExifFields f) {
  final payload = [..._latin('Exif\x00\x00'), ...exifTiff(f)];
  return _jpegSegment(jpeg, 0xE1, payload);
}

/// [jpeg] with an XMP APP1 segment holding [xmp].
Uint8List xmpJpeg(Uint8List jpeg, String xmp) => _jpegSegment(jpeg, 0xE1,
    [..._latin('http://ns.adobe.com/xap/1.0/\x00'), ...utf8.encode(xmp)]);

/// The XMP packet iOS and macOS write into screenshots.
String screenshotXmp(int w, int h) => '<x:xmpmeta xmlns:x="adobe:ns:meta/" '
    'x:xmptk="XMP Core 6.0.0"><rdf:RDF '
    'xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
    '<rdf:Description rdf:about="" '
    'xmlns:exif="http://ns.adobe.com/exif/1.0/">'
    '<exif:PixelYDimension>$h</exif:PixelYDimension>'
    '<exif:PixelXDimension>$w</exif:PixelXDimension>'
    '<exif:UserComment>Screenshot</exif:UserComment>'
    '</rdf:Description></rdf:RDF></x:xmpmeta>';

/// [png] with text chunks added after IHDR: `tEXt` for each entry, or an
/// `iTXt` for the XMP key (`XML:com.adobe.xmp`), as tools write them.
Uint8List pngWithText(Uint8List png, Map<String, String> text) {
  final chunks = BytesBuilder();
  text.forEach((key, value) {
    if (key == 'XML:com.adobe.xmp') {
      chunks.add(_pngChunk(
          'iTXt', [..._latin(key), 0, 0, 0, 0, 0, ...utf8.encode(value)]));
    } else {
      chunks
          .add(_pngChunk('tEXt', [..._latin(key), 0, ...latin1.encode(value)]));
    }
  });
  const ihdrEnd = 8 + 8 + 13 + 4;
  return Uint8List.fromList([
    ...png.sublist(0, ihdrEnd),
    ...chunks.takeBytes(),
    ...png.sublist(ihdrEnd)
  ]);
}

/// [png] with an `eXIf` chunk holding [f].
Uint8List pngWithExif(Uint8List png, ExifFields f) {
  const ihdrEnd = 8 + 8 + 13 + 4;
  return Uint8List.fromList([
    ...png.sublist(0, ihdrEnd),
    ..._pngChunk('eXIf', exifTiff(f)),
    ...png.sublist(ihdrEnd)
  ]);
}

List<int> _latin(String s) => latin1.encode(s);

Uint8List _jpegSegment(Uint8List jpeg, int marker, List<int> payload) {
  final length = payload.length + 2;
  return Uint8List.fromList([
    ...jpeg.sublist(0, 2),
    0xFF, marker, length >> 8, length & 0xFF, //
    ...payload,
    ...jpeg.sublist(2),
  ]);
}

List<int> _pngChunk(String type, List<int> data) {
  final body = [..._latin(type), ...data];
  return [..._u32be(data.length), ...body, ..._u32be(_crc(body))];
}

(int, int, int, List<int>) _ascii(int tag, String s) {
  final v = [..._latin(s), 0];
  return (tag, 2, v.length, v);
}

(int, int, int, List<int>) _rational(int tag, (int, int) v) =>
    (tag, 5, 1, [..._u32(v.$1), ..._u32(v.$2)]);

List<int> _u16(int v) => [v & 0xFF, v >> 8 & 0xFF];
List<int> _u32(int v) =>
    [v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF];
List<int> _u32be(int v) =>
    [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];

final List<int> _crcTable = () {
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
