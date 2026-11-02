import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../screenshots/scan.dart';
import 'empty_unreadable_test_area.dart' show testAreaMarker;
import 'photo_factory.dart';
import 'screenshot_factory.dart';

/// A generated screenshot test area: [filesDir] is the folder to scan,
/// [manifest] the `expected.json` with what each image should get.
final class ScreenshotTestArea {
  const ScreenshotTestArea(this.root, this.images);

  final String root;
  final List<ExpectedScreenshot> images;

  String get filesDir => p.join(root, 'files');
  String get manifest => p.join(root, 'expected.json');
}

/// Builds the screenshot test area in [root]: a fake phone and computer
/// with screenshots from each scenario in the project doc (Alexa's camera
/// roll, Ethan's exports, Timmy's school and game captures), screenshots
/// that are blank or empty, screenshot files that are empty or unreadable
/// (storage full mid-save, cut-off downloads, damaged files), and
/// look-alikes that must not be flagged (camera photos, a photo of a
/// screen, wallpapers, exported graphics).
///
/// One screenshot is planted as taken an hour before [now] (default: the
/// real time), so it's held back as recent for two days after the area is
/// built; `expected.json` records when that ends.
///
/// Refuses to overwrite a non-empty folder it didn't make.
Future<ScreenshotTestArea> buildScreenshotTestArea(String root,
    {DateTime? now}) async {
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
  _plant(b, now ?? DateTime.now());

  File(p.join(root, 'expected.json'))
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'scan': 'screenshots',
    'rulesetVersion': screenshotRulesetVersion,
    'scanFolder': 'files',
    'images': [for (final e in b.images) e.toJson()],
  }));
  return ScreenshotTestArea(root, b.images);
}

/// Reads a screenshot test area's `expected.json`.
List<ExpectedScreenshot> readExpectedScreenshots(String manifestPath) {
  final json =
      jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, Object?>;
  return [
    for (final e in json['images']! as List)
      ExpectedScreenshot.fromJson(e as Map<String, Object?>)
  ];
}

final class _Builder {
  _Builder(this.root);
  final String root;
  final images = <ExpectedScreenshot>[];

  void write(String path, List<int> bytes, DateTime modified, String why,
      {String? expect,
      String? kind,
      String? observation,
      DateTime? recentUntil,
      String? thenExpect}) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    file.setLastModifiedSync(modified);
    images.add(ExpectedScreenshot(
        path: path,
        why: why,
        rule: expect,
        kind: kind,
        observation: observation,
        recentUntil: recentUntil,
        thenRule: thenExpect));
  }
}

// Samsung phones save screenshots as JPEG at the screen's size.
const _pw = 1080, _ph = 2340;

void _plant(_Builder b, DateTime now) {
  // --- Alexa: "screenshots she never got around to deleting" -------------
  // A Samsung phone: JPEG screenshots named with the app on screen.
  b.write(
      'Pictures/Screenshots/Screenshot_20260913-201500_Instagram.jpg',
      _jpg(phoneScreenshot(PhoneApp.feed, 1, w: _pw, h: _ph)),
      DateTime(2026, 9, 13, 20, 15),
      'Instagram post from a bakery she wanted to remember',
      expect: 'S01',
      kind: 'phone');
  b.write(
      'Pictures/Screenshots/Screenshot_20260914-083000_Chrome.jpg',
      _jpg(phoneScreenshot(PhoneApp.article, 2, w: _pw, h: _ph)),
      DateTime(2026, 9, 14, 8, 30),
      'A recipe page',
      expect: 'S01',
      kind: 'phone');
  b.write(
      'Pictures/Screenshots/Screenshot_20260915-121500_WhatsApp.jpg',
      _jpg(phoneScreenshot(PhoneApp.chat, 3, w: _pw, h: _ph)),
      DateTime(2026, 9, 15, 12, 15),
      'Group chat planning the Yosemite trip',
      expect: 'S01',
      kind: 'phone');
  b.write(
      'Pictures/Screenshots/Screenshot_20260916-093000_Maps.jpg',
      _jpg(phoneScreenshot(PhoneApp.maps, 4, w: _pw, h: _ph)),
      DateTime(2026, 9, 16, 9, 30),
      'Trail map',
      expect: 'S01',
      kind: 'phone');
  b.write(
      'DCIM/Screenshots/Screenshot_20260920-190000.png',
      img.encodePng(
          phoneScreenshot(PhoneApp.chat, 5, w: _pw, h: _ph, dark: true)),
      DateTime(2026, 9, 20, 19),
      'Dark-mode chat, saved as PNG in DCIM/Screenshots as some phones do',
      expect: 'S01',
      kind: 'phone');
  b.write(
      'Pictures/Screenshots/Screenshot_20260918-220000_Netflix.jpg',
      _jpg(blankScreen(_pw, _ph, img.ColorRgb8(0, 0, 0))),
      DateTime(2026, 9, 18, 22),
      'Netflix blocks screenshots: the phone saved a black frame',
      expect: 'S05',
      kind: 'phone');
  b.write(
      'Pictures/Screenshots/Screenshot_20260919-071500_Chrome.jpg',
      _jpg(blankScreen(_pw, _ph, img.ColorRgb8(255, 255, 255), bars: true)),
      DateTime(2026, 9, 19, 7, 15),
      'Taken before the page loaded: a white screen with only the status bar',
      expect: 'S06',
      kind: 'phone');
  final cut =
      img.encodePng(phoneScreenshot(PhoneApp.settings, 6, w: _pw, h: _ph));
  b.write(
      'Pictures/Screenshots/Screenshot_20261001-101010.png',
      const [],
      DateTime(2026, 10, 1, 10, 10),
      '"Storage full" while saving: the screenshot is 0 bytes',
      expect: 'E01');
  b.write(
      'Pictures/Screenshots/Screenshot_20261002-111111.png',
      cut.sublist(0, cut.length * 2 ~/ 3),
      DateTime(2026, 10, 2, 11, 11),
      'Storage ran out partway through saving: cut off',
      expect: 'U06');
  b.write(
      'Pictures/Screenshots/crop_bakery_hours.png',
      img.encodePng(img.copyCrop(phoneScreenshot(PhoneApp.article, 7),
          x: 100, y: 900, width: 800, height: 760)),
      DateTime(2026, 9, 14, 8, 32),
      'A cropped screenshot, renamed, still in the Screenshots folder',
      expect: 'S03',
      kind: 'unknown');
  b.write(
      'Pictures/WhatsApp/IMG-20261003-WA0011.jpg',
      _jpg(
          img.copyResize(phoneScreenshot(PhoneApp.chat, 8, w: _pw, h: _ph),
              width: 720),
          70),
      DateTime(2026, 10, 3, 18, 5),
      "A friend's screenshot received over WhatsApp: renamed, shrunk, "
          're-compressed, no metadata. Only the pixels say screenshot',
      expect: 'S04',
      kind: 'phone');
  b.write(
      'DCIM/Camera/IMG_20260913_101500.jpg',
      _camera(cameraLike(11, 1600, 1200)),
      DateTime(2026, 9, 13, 10, 15),
      'A camera photo of the bakery');
  b.write(
      'Pictures/Screenshots/IMG_20260912_143000.jpg',
      _camera(cameraLike(12, 1600, 1200)),
      DateTime(2026, 9, 12, 14, 30),
      'A camera photo moved into the Screenshots folder: camera data wins',
      observation: 'cameraPhoto');
  b.write(
      'Download/wallpaper_mountains.jpg',
      _jpg(cameraLike(13, _pw, _ph), 88),
      DateTime(2026, 9, 25, 21),
      'A downloaded wallpaper at the exact screen size: a picture, no UI');
  b.write(
      'Pictures/Instagram/story_bakesale.png',
      img.encodePng(flatGraphic(14, 1080, 1920)),
      DateTime(2026, 9, 27, 16),
      'A designed story graphic: flat colours at a phone shape, but no '
          'status bar',
      observation: 'possibleScreenshot');
  b.write(
      'Pictures/WhatsApp/IMG-20261004-WA0002.jpg',
      _jpg(cameraLike(15, 900, 1600), 60),
      DateTime(2026, 10, 4, 9),
      'A portrait photo received over WhatsApp: no metadata, phone-shaped, '
          'but a photo');
  final justNow = DateTime(now.year, now.month, now.day, now.hour)
      .subtract(const Duration(hours: 1));
  String two(int n) => n.toString().padLeft(2, '0');
  b.write(
      'Pictures/Screenshots/Screenshot_${justNow.year}${two(justNow.month)}'
          '${two(justNow.day)}-${two(justNow.hour)}0000_Wallet.jpg',
      _jpg(phoneScreenshot(PhoneApp.ticket, 16, w: _pw, h: _ph)),
      justNow,
      'A boarding pass captured an hour before the area was built: '
          'probably still needed',
      observation: 'recent',
      recentUntil: justNow.add(const Duration(days: 2)),
      thenExpect: 'S01');

  // --- Ethan: phone exports and broken screenshot files ------------------
  final settings =
      img.encodePng(phoneScreenshot(PhoneApp.settings, 21, w: 1179, h: 2556));
  b.write(
      'Documents/Exports/iPhone/IMG_4821.PNG',
      pngWithText(settings, {'XML:com.adobe.xmp': screenshotXmp(1179, 2556)}),
      DateTime(2026, 10, 9, 14),
      'An iPhone screenshot exported to the computer: named like a photo, '
          'but iOS marked it "Screenshot"',
      expect: 'S02',
      kind: 'phone');
  b.write(
      'Documents/Exports/iPhone/IMG_4822.JPG',
      exifJpeg(
          _jpg(adjustPhoto(receiptPhoto(22), 22, 3), 90),
          const ExifFields(
              make: 'Apple',
              model: 'iPhone 15',
              exposureTime: (1, 60),
              fNumber: (16, 10),
              focalLength: (60, 10),
              iso: 100)),
      DateTime(2026, 10, 9, 14, 2),
      'A photo of a receipt from the same export');
  final shared =
      img.encodePng(phoneScreenshot(PhoneApp.article, 23, w: 720, h: 1600));
  b.write(
      'Download/Screenshot_20261012-090000.png.part',
      shared.sublist(0, shared.length ~/ 3),
      DateTime(2026, 10, 12, 9),
      'A screenshot downloaded from a chat that never finished',
      expect: 'U03');
  final scrambled = Uint8List.fromList(
      _jpg(phoneScreenshot(PhoneApp.chat, 24, w: _pw, h: _ph)));
  final sos = _indexOf(scrambled, const [0xFF, 0xDA]);
  final r = Random(24);
  for (var i = sos + 20; i < scrambled.length - 2; i++) {
    scrambled[i] = scrambled[i - 1] == 0xFF ? 0 : r.nextInt(256);
  }
  b.write(
      'Pictures/Screenshots/Screenshot_20261013-154500_Outlook.jpg',
      scrambled,
      DateTime(2026, 10, 13, 15, 45),
      'Picture data scrambled by a failing memory card',
      expect: 'U08');
  b.write(
      'Pictures/Screenshots/Screenshot_20261014-080000.png',
      img.encodePng(noteScreenshot(25, w: _pw, h: _ph)),
      DateTime(2026, 10, 14, 8),
      'The office Wi-Fi password: one line on a white note. Mostly blank, '
          'but not empty',
      expect: 'S01',
      kind: 'phone');
  b.write(
      'Download/invoice_0042_scan.png',
      img.encodePng(adjustPhoto(receiptPhoto(26), 26, 2)),
      DateTime(2026, 10, 14, 9),
      'A scanned invoice: portrait and mostly white, but a scan');
  final damaged = Uint8List.fromList(
      img.encodePng(phoneScreenshot(PhoneApp.settings, 27, w: 720, h: 1600)));
  damaged[damaged.length ~/ 2] ^= 0xFF;
  b.write('Pictures/Screenshots/Screenshot_20261015-170000.png', damaged,
      DateTime(2026, 10, 15, 17), 'One flipped byte: the PNG checksum fails',
      expect: 'U07');
  b.write(
      'OneDrive/Pictures/Screenshots/Screenshot 2026-10-16 091500.png',
      List.filled(40000, 0),
      DateTime(2026, 10, 16, 9, 15),
      'A OneDrive screenshot whose data never synced: all zero bytes',
      expect: 'U04');

  // --- Timmy: "screenshots of his computer he used for school projects" --
  b.write(
      'Pictures/Screenshots/Screenshot 2026-10-06 154500.png',
      img.encodePng(desktopScreenshot(DesktopApp.slides, 31)),
      DateTime(2026, 10, 6, 15, 45),
      'Snipping Tool capture of his history slides',
      expect: 'S01',
      kind: 'computer');
  b.write(
      'Pictures/Screenshots/Screenshot (12).png',
      img.encodePng(desktopScreenshot(DesktopApp.document, 32)),
      DateTime(2026, 10, 7, 11),
      'Win+PrtScn capture of an essay draft',
      expect: 'S01',
      kind: 'computer');
  b.write(
      'Pictures/Screenshots/Screenshot (13).png',
      img.encodePng(blankDesktop()),
      DateTime(2026, 10, 7, 21),
      'A full-screen video that blocks capture: black but for the taskbar',
      expect: 'S06',
      kind: 'computer');
  b.write(
      'Videos/Captures/Starfall Odyssey 2026-10-08 21-14-03.png',
      img.encodePng(gameScreenshot(33)),
      DateTime(2026, 10, 8, 21, 14, 3),
      'Xbox Game Bar screenshot of the game he records',
      expect: 'S01',
      kind: 'computer');
  b.write(
      'Videos/Captures/Starfall Odyssey 2026-10-08 21-20-00.mp4',
      _mp4(),
      DateTime(2026, 10, 8, 21, 20),
      'A Game Bar clip: a screen recording, left to the old-video scan',
      observation: 'screenRecording');
  b.write(
      'Desktop/School/Screen Shot 2019-03-04 at 4.15.10 PM.png',
      img.encodePng(desktopScreenshot(DesktopApp.browser, 34,
          w: 1440, h: 900, taskbar: false)),
      DateTime(2019, 3, 4, 16, 15, 10),
      'Old Mac screenshot copied from a previous laptop',
      expect: 'S01',
      kind: 'computer');
  b.write(
      'Desktop/School/Screenshot 2026-09-29 at 10.02.11 AM.png',
      pngWithText(
          img.encodePng(desktopScreenshot(DesktopApp.code, 35,
              w: 1440, h: 900, taskbar: false)),
          {'XML:com.adobe.xmp': screenshotXmp(1440, 900)}),
      DateTime(2026, 9, 29, 10, 2, 11),
      'macOS screenshot of a coding assignment (narrow space before AM, '
          'as recent macOS writes it)',
      expect: 'S01',
      kind: 'computer');
  b.write(
      'Documents/School/Lab/Screenshot from 2026-10-10 09-30-00.png',
      pngWithText(img.encodePng(desktopScreenshot(DesktopApp.browser, 36)),
          {'Software': 'gnome-screenshot'}),
      DateTime(2026, 10, 10, 9, 30),
      'Captured on the school lab Linux machine',
      expect: 'S01',
      kind: 'computer');
  b.write(
      'Documents/School/Lab/Screenshot from 2026-10-10 09-31-12.png',
      pngWithText(
          img.encodePng(blankScreen(1920, 1080, img.ColorRgb8(255, 255, 255))),
          {'Software': 'gnome-screenshot'}),
      DateTime(2026, 10, 10, 9, 31, 12),
      'A capture taken while the screen was redrawing: all white',
      expect: 'S05',
      kind: 'computer');
  b.write(
      'Documents/School/history_notes.png',
      pngWithText(img.encodePng(desktopScreenshot(DesktopApp.document, 37)),
          {'Software': 'ShareX'}),
      DateTime(2026, 10, 11, 20),
      'A ShareX capture he renamed: only the tool mark says screenshot',
      expect: 'S02',
      kind: 'computer');
  b.write(
      'Pictures/Steam/screenshots/20261009213000_1.jpg',
      _jpg(gameScreenshot(38)),
      DateTime(2026, 10, 9, 21, 30),
      "Steam's screenshot folder: named by date only",
      expect: 'S03',
      kind: 'computer');
  b.write(
      'Documents/School/project_diagram.png',
      img.encodePng(flatGraphic(39, 1920, 1080)),
      DateTime(2026, 10, 12, 19),
      'A diagram exported from his slides at 1920×1080: screen-sized and '
          'flat, but not a screenshot');
  b.write(
      'DCIM/Camera/IMG_20261007_101500.jpg',
      _camera(photoOfScreen(40, 1600, 1200)),
      DateTime(2026, 10, 7, 10, 15),
      'A photo of the classroom screen taken with the camera, not a '
          'screenshot');

  // --- Broken images that aren't screenshots: the empty & unreadable scan
  // reports them; this scan leaves them out.
  b.write(
      'DCIM/Camera/IMG_20261014_094500.jpg',
      const [],
      DateTime(2026, 10, 14, 9, 45),
      'A 0-byte camera photo: not a screenshot, left to the empty & '
          'unreadable scan');
  final meme = img.encodePng(flatGraphic(41, 600, 600));
  b.write(
      'Download/meme_cut.png',
      meme.sublist(0, meme.length ~/ 2),
      DateTime(2026, 10, 15, 12),
      'A cut-off download that is not a screenshot');
}

Uint8List _jpg(img.Image image, [int quality = 90]) =>
    img.encodeJpg(image, quality: quality);

/// A camera JPEG: the picture with make, model and exposure details.
Uint8List _camera(img.Image image) => exifJpeg(_jpg(image, 92), cameraExif);

/// A small, well-formed MP4: ftyp, moov, mdat.
List<int> _mp4() {
  List<int> box(String type, List<int> payload) {
    final size = 8 + payload.length;
    return [
      size >> 24 & 0xFF, size >> 16 & 0xFF, size >> 8 & 0xFF, size & 0xFF, //
      ...type.codeUnits, ...payload,
    ];
  }

  final r = Random(5);
  return [
    ...box('ftyp', 'isom\x00\x00\x02\x00isommp41'.codeUnits),
    ...box('moov', List.filled(400, 1)),
    ...box('mdat', [for (var i = 0; i < 8000; i++) r.nextInt(256)]),
  ];
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
