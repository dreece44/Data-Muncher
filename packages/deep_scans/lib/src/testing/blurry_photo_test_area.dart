import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../blurry_photos/scan.dart';
import 'blur_factory.dart';
import 'empty_unreadable_test_area.dart' show testAreaMarker;
import 'photo_factory.dart';

/// A generated blurry-photo test area: [filesDir] is the folder to scan,
/// [manifest] the `expected.json` with what each photo should get.
final class BlurryTestArea {
  const BlurryTestArea(this.root, this.photos, this.rankingOrder);

  final String root;
  final List<ExpectedPhoto> photos;

  /// Photos (paths, blurriest first) whose relative order the ranking must
  /// keep.
  final List<String> rankingOrder;

  String get filesDir => p.join(root, 'files');
  String get manifest => p.join(root, 'expected.json');
}

/// Builds the blurry photo test area in [root]: a fake phone's camera roll
/// with blurry photos from each scenario in the project doc, look-alikes
/// that must not be flagged (portrait mode, panning, fog, night shots,
/// small or compressed copies, screenshots), and photo files that are
/// empty or unreadable (failed downloads, damaged files).
///
/// Refuses to overwrite a non-empty folder it didn't make.
Future<BlurryTestArea> buildBlurryPhotoTestArea(String root) async {
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
    'scan': 'blurry_photos',
    'rulesetVersion': blurryPhotoRulesetVersion,
    'scanFolder': 'files',
    'rankingOrder': b.rankingOrder,
    'photos': [for (final e in b.photos) e.toJson()],
  }));
  return BlurryTestArea(root, b.photos, b.rankingOrder);
}

/// Reads a blurry test area's `expected.json`: the photos and the ranking
/// order.
(List<ExpectedPhoto>, List<String>) readExpectedPhotos(String manifestPath) {
  final json =
      jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, Object?>;
  return (
    [
      for (final e in json['photos']! as List)
        ExpectedPhoto.fromJson(e as Map<String, Object?>)
    ],
    [
      for (final path in json['rankingOrder'] as List? ?? const [])
        path as String
    ],
  );
}

final class _Builder {
  _Builder(this.root);
  final String root;
  final photos = <ExpectedPhoto>[];
  final rankingOrder = <String>[];

  void write(String path, List<int> bytes, DateTime modified, String why,
      {String? expect, String? observation, String? sharperRetake}) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    file.setLastModifiedSync(modified);
    photos.add(ExpectedPhoto(
        path: path,
        why: why,
        rule: expect,
        observation: observation,
        sharperRetake: sharperRetake));
  }
}

const _w = 1600, _h = 1200;

/// A scene framed like a phone photo.
img.Image _scene(int seed, {double fx = .5, double fy = .5}) =>
    reframe(landscapeScene(seed, 1900, 1400), fx, fy, _w, _h);

void _plant(_Builder b) {
  // --- Alexa: the Yosemite weekend ("blurry photo attempts") --------------
  final day1 = DateTime(2026, 9, 12, 10, 15);
  final hike = _scene(1);
  b.write(
      'DCIM/Camera/IMG_20260912_101500.jpg',
      _camera(_jpg(outOfFocus(hike, 4, 11), 92)),
      day1,
      'Hike shot that missed focus, retaken 4 s later. Only slightly soft, '
          'which alone is not flagged; the sharp retake makes it a blurry attempt',
      expect: 'B04',
      sharperRetake: 'DCIM/Camera/IMG_20260912_101504.jpg');
  b.write(
      'DCIM/Camera/IMG_20260912_101504.jpg',
      _camera(_jpg(cameraSharp(_scene(1, fx: .52), 12), 92)),
      day1.add(const Duration(seconds: 4)),
      'The sharp retake of the hike shot');
  b.write(
      'DCIM/Camera/IMG_20260912_143000.jpg',
      _camera(_jpg(outOfFocus(_scene(7), 14, 13), 92)),
      day1.add(const Duration(hours: 4, minutes: 15)),
      'Bakery window, focus missed completely',
      expect: 'B01');
  b.write(
      'DCIM/Camera/IMG_20260912_131000.jpg',
      _camera(_jpg(motionBlur(_scene(8), 14, 0, 14), 92)),
      day1.add(const Duration(hours: 2, minutes: 55)),
      'Lunch plate with camera shake: smeared left–right, sharp up–down',
      expect: 'B03');
  b.write(
      'DCIM/Camera/IMG_20260912_160500.jpg',
      _camera(_jpg(outOfFocus(_scene(9), 7, 15), 92)),
      day1.add(const Duration(hours: 5, minutes: 50)),
      'Trail sign, noticeably out of focus with no retake',
      expect: 'B02');
  b.write(
      'DCIM/Camera/IMG_20260912_164000.jpg',
      _camera(_jpg(outOfFocus(_scene(3), 3, 16), 92)),
      day1.add(const Duration(hours: 6, minutes: 25)),
      'Only a touch soft: fine to look at, must not be flagged');
  final burst = day1.add(const Duration(hours: 2, minutes: 50));
  b.write(
      'DCIM/Camera/IMG_20260912_130500.jpg',
      _camera(_jpg(cameraSharp(_scene(4), 17), 92)),
      burst,
      'Food burst, frame 1: both frames sharp, so neither is an attempt');
  b.write(
      'DCIM/Camera/IMG_20260912_130501.jpg',
      _camera(_jpg(cameraSharp(_scene(4, fx: .51), 18), 92)),
      burst.add(const Duration(seconds: 1)),
      'Food burst, frame 2');
  b.write(
      'DCIM/Camera/IMG_20260912_131500.jpg',
      _camera(_jpg(portraitMode(_scene(10), 10, 19), 92)),
      day1.add(const Duration(hours: 3)),
      'Portrait mode dessert: sharp subject, blurred background',
      observation: 'sharpSubject');
  b.write(
      'DCIM/Camera/IMG_20260913_070000.jpg',
      _camera(_jpg(featureless(5, _w, _h), 92)),
      DateTime(2026, 9, 13, 7),
      'Morning fog over the valley: nothing to judge focus by',
      observation: 'lowDetail');
  b.write(
      'Pictures/Screenshots/Screenshot_20260913-201500.png',
      img.encodePng(outOfFocus(_chat(20), 6, 20, noise: 0)),
      DateTime(2026, 9, 13, 20, 15),
      'Screenshot of a blurry recipe video: not a camera photo',
      observation: 'screenshot');

  // --- Gerald: a day with the grandchildren ("found blurry photos") -------
  final day2 = DateTime(2026, 9, 20, 13);
  b.write(
      'DCIM/Camera/IMG_20260920_130000.jpg',
      _camera(_jpg(motionBlur(_scene(11), 40, 0, 21), 92)),
      day2,
      'Mini-golf swing with heavy camera shake',
      expect: 'B01');
  b.write(
      'DCIM/Camera/IMG_20260920_151500.jpg',
      _camera(_jpg(cameraSharp(_scene(12), 22), 92)),
      day2.add(const Duration(hours: 2, minutes: 15)),
      'Ice cream: sharp');
  b.write(
      'DCIM/Camera/IMG_20260920_190000.jpg',
      _camera(_jpg(motionBlur(_scene(13), 18, 45, 23), 92)),
      day2.add(const Duration(hours: 6)),
      'Food fight at dinner: the kids moved diagonally mid-shot',
      expect: 'B03');
  b.write(
      'DCIM/Camera/IMG_20260920_200000.jpg',
      _camera(_jpg(nightScene(24, _w, _h), 92)),
      day2.add(const Duration(hours: 7)),
      'Night street on the way home: dark and noisy but sharp');
  b.write(
      'DCIM/Camera/IMG_20260920_200500.jpg',
      _camera(_jpg(nightScene(25, _w, _h, blurRadius: 8), 92)),
      day2.add(const Duration(hours: 7, minutes: 5)),
      'Night street, out of focus',
      expect: 'B02');
  b.write(
      'DCIM/Camera/IMG_20260920_210000.jpg',
      _camera(_jpg(adjustPhoto(_flat(_w, _h, 8), 26, 3), 90)),
      day2.add(const Duration(hours: 8)),
      'Pocket shot: black, left to the blank-photo scan',
      observation: 'blank');

  // --- Ethan: receipts "taken multiple times because of focus issues" ----
  final day3 = DateTime(2026, 10, 14, 9, 30);
  b.write(
      'DCIM/Camera/IMG_20261014_093000.jpg',
      _camera(_jpg(outOfFocus(receiptPhoto(42), 4, 31), 90)),
      day3,
      'Receipt 0042, blurry (B02 on its own); retaken 20 s later, which '
          'makes it a blurry attempt',
      expect: 'B04',
      sharperRetake: 'DCIM/Camera/IMG_20261014_093020.jpg');
  b.write(
      'DCIM/Camera/IMG_20261014_093020.jpg',
      _camera(_jpg(cameraSharp(receiptPhoto(42, dx: .01), 32), 90)),
      day3.add(const Duration(seconds: 20)),
      'Receipt 0042 retake: sharp');
  b.write(
      'DCIM/Camera/IMG_20261014_093200.jpg',
      _camera(_jpg(outOfFocus(receiptPhoto(43), 4, 33), 90)),
      day3.add(const Duration(minutes: 2)),
      'Receipt 0043, blurry and never retaken. Receipt 0044, sharp and '
          'taken 2 min later in the same layout, is a different receipt and '
          'must not count as its retake',
      expect: 'B02');
  b.write(
      'DCIM/Camera/IMG_20261014_093400.jpg',
      _camera(_jpg(cameraSharp(receiptPhoto(44), 34), 90)),
      day3.add(const Duration(minutes: 4)),
      'Receipt 0044: sharp, a different receipt from 0043');
  // The hardest look-alike: once 0155 is a little soft, receipt 0117 (sharp,
  // a minute later, same table and layout) passes even the duplicate photo
  // scan's near-identical-shot test. Only the fine-detail check shows the
  // text is different, so 0155 must not become a "blurry attempt".
  b.write(
      'DCIM/Camera/IMG_20261014_101000.jpg',
      _camera(_jpg(outOfFocus(receiptPhoto(155), 3, 155), 90)),
      day3.add(const Duration(minutes: 40)),
      'Receipt 0155, slightly soft. Receipt 0117 a minute later looks the '
          'same at low resolution but is a different receipt',
      observation: 'retakeRejected');
  b.write(
      'DCIM/Camera/IMG_20261014_101100.jpg',
      _camera(_jpg(cameraSharp(receiptPhoto(117), 117), 90)),
      day3.add(const Duration(minutes: 41)),
      'Receipt 0117: sharp');

  // Empty and unreadable photos ("several empty files from failed
  // downloads"), reported under the empty & unreadable rules.
  final good = _jpg(cameraSharp(_scene(35), 35), 90);
  final failed = DateTime(2026, 10, 14, 11);
  b.write('Download/receipt_0045.jpg', const [], failed,
      'Failed download left a 0-byte photo',
      expect: 'E01');
  b.write(
      'Download/IMG-20261014-WA0003.jpg',
      [
        ...good.sublist(0, good.length * 6 ~/ 10),
        ...List.filled(good.length - good.length * 6 ~/ 10, 0)
      ],
      failed,
      'Download reserved the full size and stopped at 60%',
      expect: 'U06');
  b.write(
      'Download/invoice_scan.jpg.crdownload',
      good.sublist(0, good.length ~/ 3),
      failed,
      'Browser download that never finished',
      expect: 'U03');
  b.write('DCIM/Camera/IMG_20261014_094500.jpg', List.filled(8000, 0), failed,
      'Camera file that is all zero bytes',
      expect: 'U04');
  b.write(
      'Pictures/WhatsApp/IMG-20261013-WA0007.jpg',
      utf8.encode('<!DOCTYPE html><html><head><title>Media expired</title>'
          '</head><body><p>This media is no longer available.</p></body>'
          '</html>'),
      failed,
      'An error page saved under a photo name',
      expect: 'U05');
  final scrambled = Uint8List.fromList(_jpg(cameraSharp(_scene(36), 36), 90));
  final sos = _indexOf(scrambled, const [0xFF, 0xDA]);
  final r = Random(37);
  for (var i = sos + 20; i < scrambled.length - 2; i++) {
    scrambled[i] = scrambled[i - 1] == 0xFF ? 0 : r.nextInt(256);
  }
  b.write('DCIM/Camera/IMG_20261014_095000.jpg', scrambled, failed,
      'Markers intact but the picture data is scrambled',
      expect: 'U08');
  final damaged =
      Uint8List.fromList(img.encodePng(img.copyResize(_scene(38), width: 800)));
  damaged[damaged.length ~/ 2] ^= 0xFF;
  b.write('Pictures/receipt_crop.png', damaged, failed,
      'One flipped byte: the PNG checksum fails',
      expect: 'U07');

  // --- Jasmine: wedding deliveries (look-alikes) --------------------------
  final day4 = DateTime(2026, 10, 3, 12, 30);
  b.write(
      'Pictures/Weddings/Smith/DSC_0101.jpg',
      _camera(_jpg(portraitMode(_scene(41), 12, 41, subjectShare: .3), 92)),
      day4,
      'Bride portrait at f/1.8: only the subject is in focus',
      observation: 'sharpSubject');
  b.write(
      'Pictures/Weddings/Smith/DSC_0140.jpg',
      _camera(_jpg(panningShot(_scene(42), 30, 42), 92)),
      day4.add(const Duration(minutes: 40)),
      'Panning shot of the wedding car: car sharp, background streaked',
      observation: 'sharpSubject');
  b.write(
      'Pictures/WhatsApp/IMG-20261004-WA0012.jpg',
      _jpg(img.copyResize(cameraSharp(_scene(43), 43), width: 800), 60),
      day4.add(const Duration(days: 1)),
      'Delivery copy sent over WhatsApp: small and compressed, still sharp');
  b.write(
      'Pictures/Weddings/Smith/DSC_0150_web.jpg',
      _jpg(cameraSharp(_scene(44), 44), 30),
      day4.add(const Duration(hours: 2)),
      'Heavily compressed web copy: blocky, but not blurry');
  b.write(
      'Pictures/Old phone/IMG_0042.jpg',
      _jpg(
          cameraSharp(
              reframe(landscapeScene(45, 760, 560), .5, .5, 640, 480), 45),
          90),
      DateTime(2012, 6, 2, 15),
      'Old 640×480 phone photo: judged at its own size, so not called blurry');

  // --- Timmy: screenshots and stickers ------------------------------------
  b.write(
      'Pictures/Screenshots/Screenshot_20261020-161000.png',
      img.encodePng(_chat(51)),
      DateTime(2026, 10, 20, 16, 10),
      'Sharp screenshot of a chat: not a camera photo',
      observation: 'screenshot');
  b.write(
      'Pictures/Stickers/sticker_07.png',
      img.encodePng(_sticker()),
      DateTime(2026, 10, 20, 16, 12),
      '150×150 sticker: too small to be a photo',
      observation: 'tooSmall');

  b.rankingOrder.addAll([
    'DCIM/Camera/IMG_20260912_143000.jpg', // focus missed completely
    'DCIM/Camera/IMG_20260912_160500.jpg', // noticeably out of focus
    'DCIM/Camera/IMG_20260912_164000.jpg', // a touch soft
    'DCIM/Camera/IMG_20260912_101504.jpg', // sharp
  ]);
}

// --- Picture makers ---------------------------------------------------------

/// A phone chat screenshot: status bar, title bar, message bubbles.
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
  return im;
}

img.Image _flat(int w, int h, int v) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(v, v, v));
  return im;
}

img.Image _sticker() {
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

/// Adds a minimal EXIF block right after the JPEG start marker, as a phone
/// camera writes.
Uint8List _camera(Uint8List jpeg) {
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

int _indexOf(List<int> data, List<int> pattern) {
  outer:
  for (var i = 0; i + pattern.length <= data.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}
