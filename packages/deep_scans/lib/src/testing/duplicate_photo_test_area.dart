import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../duplicate_photos/scan.dart';
import 'blur_factory.dart' show cameraSharp;
import 'photo_factory.dart';
import 'empty_unreadable_test_area.dart' show testAreaMarker;

/// A generated duplicate-photo test area: [filesDir] is the folder to scan,
/// [manifest] the `expected.json` with the groups and singles.
final class DuplicateTestArea {
  const DuplicateTestArea(this.root, this.groups, this.singles);

  final String root;
  final List<ExpectedGroup> groups;
  final List<ExpectedSingle> singles;

  String get filesDir => p.join(root, 'files');
  String get manifest => p.join(root, 'expected.json');
  int get fileCount =>
      groups.fold(0, (n, g) => n + g.paths.length) + singles.length;
}

/// Builds the duplicate photo test area in [root]: a fake phone's photo
/// folders with planted duplicate groups (one per scenario from the project
/// doc) and look-alikes that must stay apart.
///
/// Refuses to overwrite a non-empty folder it didn't make.
Future<DuplicateTestArea> buildDuplicatePhotoTestArea(String root) async {
  root = p.absolute(root);
  final dir = Directory(root);
  if (dir.existsSync() && dir.listSync().isNotEmpty) {
    if (!File(p.join(root, testAreaMarker)).existsSync()) {
      throw StateError('$root already exists and was not made by this tool');
    }
    dir.deleteSync(recursive: true);
  }
  Directory(p.join(root, 'files')).createSync(recursive: true);
  File(p.join(root, testAreaMarker)).writeAsStringSync('');

  final b = _Builder(p.join(root, 'files'));
  _plant(b);

  File(p.join(root, 'expected.json'))
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'scan': 'duplicate_photos',
    'rulesetVersion': duplicatePhotoRulesetVersion,
    'scanFolder': 'files',
    'groups': [for (final g in b.groups) g.toJson()],
    'singles': [for (final s in b.singles) s.toJson()],
  }));
  return DuplicateTestArea(root, b.groups, b.singles);
}

/// Reads a duplicate test area's `expected.json`.
(List<ExpectedGroup>, List<ExpectedSingle>) readExpectedGroups(
    String manifestPath) {
  final json =
      jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, Object?>;
  return (
    [
      for (final g in json['groups']! as List)
        ExpectedGroup.fromJson(g as Map<String, Object?>)
    ],
    [
      for (final s in json['singles']! as List)
        ExpectedSingle.fromJson(s as Map<String, Object?>)
    ],
  );
}

final class _Builder {
  _Builder(this.root);
  final String root;
  final groups = <ExpectedGroup>[];
  final singles = <ExpectedSingle>[];

  void write(String path, List<int> bytes, DateTime modified) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    file.setLastModifiedSync(modified);
  }

  /// Writes a group: the photo to keep, then (path, rule, bytes, time) for
  /// each duplicate.
  void group(String name, String why, (String, List<int>, DateTime) keep,
      List<(String, String, List<int>, DateTime)> members) {
    write(keep.$1, keep.$2, keep.$3);
    for (final m in members) {
      write(m.$1, m.$3, m.$4);
    }
    groups.add(ExpectedGroup(
        name: name,
        why: why,
        keep: keep.$1,
        members: {for (final m in members) m.$1: m.$2}));
  }

  void single(String path, List<int> bytes, DateTime modified, String why) {
    write(path, bytes, modified);
    singles.add(ExpectedSingle(path, why));
  }
}

void _plant(_Builder b) {
  // --- Alexa: the hike shot, copied every way a phone copies photos -------
  final hikeScene = landscapeScene(1, 1900, 1400);
  final hike = reframe(hikeScene, .5, .5, 1600, 1200);
  final hikeOriginal = _withCameraDetails(_jpg(hike, 92));
  final t0 = DateTime(2026, 9, 12, 10, 15);
  b.group(
    'hike (Alexa)',
    'One camera original and six copies: identical download, WhatsApp '
        'copy, PNG conversion, rotated, letterboxed for Instagram, brightened',
    ('DCIM/Camera/IMG_20260912_101500.jpg', hikeOriginal, t0),
    [
      (
        'Download/IMG_20260912_101500 (1).jpg',
        'D01',
        hikeOriginal,
        t0.add(const Duration(days: 2))
      ),
      (
        'Pictures/WhatsApp/IMG-20260913-WA0001.jpg',
        'D02',
        _jpg(img.copyResize(hike, width: 800), 70),
        t0.add(const Duration(days: 1))
      ),
      (
        'Pictures/hike_converted.png',
        'D02',
        img.encodePng(img.copyResize(hike, width: 1000)),
        t0.add(const Duration(days: 3))
      ),
      (
        'Pictures/Edited/hike_rotated.jpg',
        'D03',
        _jpg(img.copyRotate(hike, angle: 90), 90),
        t0.add(const Duration(days: 1))
      ),
      (
        'Pictures/Instagram/hike_square.jpg',
        'D04',
        _jpg(letterboxSquare(hike), 88),
        t0.add(const Duration(days: 1))
      ),
      (
        'Pictures/Edited/hike_brighter.jpg',
        'D05',
        _jpg(adjustPhoto(hike, 4, 0, brightness: 25, contrast: 1.15), 90),
        t0.add(const Duration(days: 1))
      ),
    ],
  );
  b.single(
      'DCIM/Camera/IMG_20260912_102000.jpg',
      _jpg(reframe(hikeScene, .5 + 0.08 * 1600 / 300, .5, 1600, 1200), 92),
      t0.add(const Duration(minutes: 5)),
      'Same place five minutes later, framed 8% differently: a new photo');

  // --- Alexa: food burst, one sharp frame ---------------------------------
  final food = landscapeScene(2, 1900, 1400);
  final tb = DateTime(2026, 9, 14, 12, 30);
  img.Image frame(double shift, int seed) => adjustPhoto(
      reframe(food, .5 + shift * 1600 / 300, .5, 1600, 1200), seed, 4);
  b.group(
    'food burst (Alexa)',
    'Three burst frames a second apart; the first and last are blurry',
    (
      'DCIM/Camera/IMG_20260914_123001.jpg',
      _jpg(frame(.007, 2), 92),
      tb.add(const Duration(seconds: 1))
    ),
    [
      (
        'DCIM/Camera/IMG_20260914_123000.jpg',
        'D06',
        _jpg(img.gaussianBlur(frame(0, 1), radius: 3), 92),
        tb
      ),
      (
        'DCIM/Camera/IMG_20260914_123002.jpg',
        'D06',
        _jpg(img.gaussianBlur(frame(.014, 3), radius: 2), 92),
        tb.add(const Duration(seconds: 2))
      ),
    ],
  );
  b.single(
      'DCIM/Camera/IMG_20260921_123000.jpg',
      _jpg(
          adjustPhoto(
              reframe(food, .5 + .02 * 1600 / 300, .5, 1600, 1200), 9, 4,
              brightness: -20),
          92),
      tb.add(const Duration(days: 7)),
      'Same view a week later, in evening light and framed 2% differently: '
          'similar, but a different moment');

  // --- Ethan: the same receipt shot three times, two other receipts -------
  final tr = DateTime(2026, 9, 14, 9);
  b.group(
    'receipt retakes (Ethan)',
    'Receipt photographed three times because of focus; keep the clear one',
    ('DCIM/Camera/IMG_20260914_090000.jpg', _jpg(receiptPhoto(11), 90), tr),
    [
      (
        'DCIM/Camera/IMG_20260914_090005.jpg',
        'D06',
        _jpg(img.gaussianBlur(receiptPhoto(11), radius: 4), 90),
        tr.add(const Duration(seconds: 5))
      ),
      (
        'DCIM/Camera/IMG_20260914_090012.jpg',
        'D06',
        _jpg(adjustPhoto(receiptPhoto(11, dx: .01, dy: .005), 3, 5), 90),
        tr.add(const Duration(seconds: 12))
      ),
    ],
  );
  b.single(
      'DCIM/Camera/IMG_20260914_090100.jpg',
      _jpg(receiptPhoto(12), 90),
      tr.add(const Duration(minutes: 1)),
      'A different receipt in the same layout, a minute later');
  b.single(
      'DCIM/Camera/IMG_20260914_090200.jpg',
      _jpg(receiptPhoto(13), 90),
      tr.add(const Duration(minutes: 2)),
      'Another different receipt in the same layout');
  // The worst look-alikes found: on the 32×32 grid these pass even D06
  // (pHash 4, correlation 0.97, edges 0.94); only their text differs.
  final tl = DateTime(2026, 9, 16, 18, 40);
  for (final (seed, minutes, why) in [
    (155, 0, 'Receipt in the same layout as the next one'),
    (117, 3, 'Different receipt that passes D06 on layout alone'),
    (152, 6, 'Another receipt in the same layout'),
    (156, 8, 'Different receipt that passes D06 on layout alone'),
  ]) {
    final t = tl.add(Duration(minutes: minutes));
    b.single(
        'DCIM/Camera/IMG_${_stamp(t)}.jpg',
        _jpg(cameraSharp(receiptPhoto(seed), seed), 90),
        t,
        '$why: fine detail tells them apart');
  }

  // --- Jasmine: a wedding shot delivered, mirrored for an album, backed up -
  final wedding = reframe(landscapeScene(3, 2300, 1600), .5, .5, 2000, 1333);
  final weddingOriginal = _withCameraDetails(_jpg(wedding, 92));
  final tw = DateTime(2026, 6, 14, 15, 30);
  const shoot = 'Pictures/Weddings/Smith 2026-06-14';
  b.group(
    'wedding shoot (Jasmine)',
    'Original, the web copy sent to the client, a mirrored album copy and '
        'an identical backup',
    ('$shoot/DSC_0412.jpg', weddingOriginal, tw),
    [
      (
        '$shoot/Client/DSC_0412_web.jpg',
        'D02',
        _jpg(img.copyResize(wedding, width: 1200), 80),
        tw.add(const Duration(days: 2))
      ),
      (
        '$shoot/Album/DSC_0412_mirror.jpg',
        'D03',
        _jpg(img.flipHorizontal(img.Image.from(wedding)), 90),
        tw.add(const Duration(days: 3))
      ),
      (
        'Backup/Weddings/DSC_0412.jpg',
        'D01',
        weddingOriginal,
        tw.add(const Duration(days: 6))
      ),
    ],
  );

  // --- Screenshots: a re-saved copy, and a different chat in the same app --
  final ts = DateTime(2026, 9, 13, 14, 15);
  final chat = _chat(21);
  b.group(
    'screenshot copy',
    'A screenshot and a JPEG copy of it saved from a chat',
    (
      'Pictures/Screenshots/Screenshot_20260913-141500.png',
      img.encodePng(chat),
      ts
    ),
    [
      (
        'Download/Screenshot_20260913-141500.jpg',
        'D02',
        _jpg(chat, 85),
        ts.add(const Duration(hours: 2))
      ),
    ],
  );
  b.single(
      'Pictures/Screenshots/Screenshot_20260913-141530.png',
      img.encodePng(_chat(22)),
      ts.add(const Duration(seconds: 30)),
      'A different chat in the same app layout, 30 seconds later');

  // --- RAW files the device can't decode: identical copies only -----------
  final raw = _noise(60000, 5);
  final traw = DateTime(2026, 8, 1, 7);
  b.group('RAW backup', 'A RAW file and its identical backup (not decodable)', (
    'DCIM/RAW/IMG_0001.dng',
    raw,
    traw
  ), [
    ('Backup/RAW/IMG_0001.dng', 'D01', raw, traw.add(const Duration(days: 1))),
  ]);

  // --- Timmy: family vacation photos backed up twice ----------------------
  for (final (seed, time) in [
    (7, DateTime(2025, 7, 4, 18, 30)),
    (8, DateTime(2025, 7, 5, 10, 15)),
  ]) {
    final name = 'IMG_${_stamp(time)}.jpg';
    final bytes = _withCameraDetails(_jpg(
        reframe(landscapeScene(seed, 1900, 1400), .5, .5, 1600, 1200), 90));
    b.group('vacation backup $name (Timmy)', 'Photo and its identical backup', (
      'DCIM/Camera/$name',
      bytes,
      time
    ), [
      (
        'Backup/Vacation 2025/$name',
        'D01',
        bytes,
        time.add(const Duration(days: 30))
      ),
    ]);
  }

  // --- Must stay apart ------------------------------------------------------
  final tx = DateTime(2026, 9, 18, 9);
  b.single(
      'DCIM/Camera/IMG_20260918_090000.jpg',
      _jpg(reframe(landscapeScene(5, 1900, 1400), .5, .5, 1600, 1200), 90),
      tx,
      'Unrelated photo');
  b.single(
      'DCIM/Camera/IMG_20260918_091000.jpg',
      _jpg(reframe(landscapeScene(6, 1900, 1400), .5, .5, 1600, 1200), 90),
      tx.add(const Duration(minutes: 10)),
      'Unrelated photo ten minutes later');
  final pocket = _jpg(adjustPhoto(_flat(1600, 1200, 8), 5, 3), 90);
  final tp = DateTime(2026, 9, 15, 22);
  b.single('DCIM/Camera/IMG_20260915_220000.jpg', pocket, tp,
      'Blank pocket shot: left to the blank-photo scan');
  b.single(
      'Backup/IMG_20260915_220000.jpg',
      pocket,
      tp.add(const Duration(days: 1)),
      'Identical copy of the blank pocket shot: still not a duplicate group');
  final sticker = img.encodePng(_stickerImage());
  b.single('Pictures/Stickers/sticker_01.png', sticker, tp,
      '150×150 sticker: too small to be a photo');
  b.single('Pictures/Stickers/sticker_01 (1).png', sticker, tp,
      'Identical sticker: too small to be a photo');
}

// --- Picture makers ---------------------------------------------------------
img.Image _chat(int seed) {
  const w = 1080, h = 2340;
  final r = Random(seed);
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(236, 229, 221));
  img.fillRect(im,
      x1: 0, y1: 0, x2: w, y2: 230, color: img.ColorRgb8(7, 94, 84));
  var y = 280;
  while (y < h - 260) {
    final mine = r.nextBool();
    final width = 300 + r.nextInt(500);
    final lines = 1 + r.nextInt(4);
    final height = 40 + lines * 50;
    final x = mine ? w - 40 - width : 40;
    img.fillRect(im,
        x1: x,
        y1: y,
        x2: x + width,
        y2: y + height,
        radius: 24,
        color:
            mine ? img.ColorRgb8(220, 248, 198) : img.ColorRgb8(255, 255, 255));
    for (var l = 0; l < lines; l++) {
      final len = 100 + r.nextInt(width - 140);
      img.fillRect(im,
          x1: x + 30,
          y1: y + 30 + l * 50,
          x2: x + 30 + len,
          y2: y + 55 + l * 50,
          color: img.ColorRgb8(60, 60, 60));
    }
    y += height + 30 + r.nextInt(40);
  }
  img.fillRect(im,
      x1: 0, y1: h - 200, x2: w, y2: h, color: img.ColorRgb8(245, 245, 245));
  return im;
}

img.Image _flat(int w, int h, int v) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(v, v, v));
  return im;
}

img.Image _stickerImage() {
  final r = Random(42);
  final im = img.Image(width: 150, height: 150);
  for (final px in im) {
    px
      ..r = r.nextInt(256)
      ..g = r.nextInt(256)
      ..b = r.nextInt(256);
  }
  return im;
}

Uint8List _jpg(img.Image image, int quality) =>
    img.encodeJpg(image, quality: quality);

/// Adds a minimal EXIF block (as a camera writes) right after the JPEG
/// start marker. Copies made by messaging apps and editors don't have one.
Uint8List _withCameraDetails(Uint8List jpeg) {
  const exif = [
    0xFF, 0xE1, 0x00, 0x16, // APP1, length 22
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // TIFF header
    0x00, 0x00, // no entries
    0x00, 0x00, 0x00, 0x00, // no next directory
  ];
  return Uint8List.fromList(
      [...jpeg.sublist(0, 2), ...exif, ...jpeg.sublist(2)]);
}

List<int> _noise(int length, int seed) {
  final r = Random(seed);
  return [for (var i = 0; i < length; i++) r.nextInt(256)];
}

String _stamp(DateTime t) => '${t.year}'
    '${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}_'
    '${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}00';
