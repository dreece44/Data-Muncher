import 'dart:typed_data';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:image/image.dart' as img;
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

import 'support/fake_device.dart';

/// Rule behaviour on small in-memory images. The full scenarios are checked
/// against the generated test area in screenshot_test_area_test.dart.
void main() {
  const rules = ScreenshotRules();
  // Half-size phone screens keep the tests quick.
  const w = 540, h = 1170;
  Uint8List png(img.Image i) => img.encodePng(i);
  Uint8List jpg(img.Image i, [int q = 90]) => img.encodeJpg(i, quality: q);
  final chat = png(phoneScreenshot(PhoneApp.chat, 1, w: w, h: h));
  final camera = exifJpeg(jpg(cameraLike(2, 800, 600)), cameraExif);

  Future<ScreenshotResult> scan(Map<String, List<int>> files,
          {ScreenshotRules rules = const ScreenshotRules(),
          DateTime Function()? clock,
          StorageSource Function(MemoryStorageSource)? wrap}) =>
      ScreenshotScan(
              device: FakeDevice(files, wrap: wrap), rules: rules, clock: clock)
          .run();

  String? ruleOf(ScreenshotResult r, String path) {
    for (final v in r.verdicts) {
      if (v.item.id == path) return v.rule.code;
    }
    for (final h in r.analysis.health) {
      if (h.item.id == path) return h.verdict.rule.code;
    }
    return null;
  }

  Set<String> notes(ScreenshotResult r, String path) => {
        for (final o in r.analysis.observations)
          if (o.id == path) o.kind.name
      };

  ScreenshotVerdict verdict(ScreenshotResult r, String path) =>
      r.verdicts.singleWhere((v) => v.item.id == path);

  group('Names (S01)', () {
    ScreenshotName? match(String name, [List<String> folders = const []]) =>
        matchScreenshotName(name, folders, rules.namePatterns);

    test('each tool’s naming is recognised, with app and time', () {
      final samsung = match('Screenshot_20260913-201500_Instagram.jpg')!;
      expect(samsung.tool, 'Android');
      expect(samsung.app, 'Instagram');
      expect(samsung.taken, DateTime(2026, 9, 13, 20, 15));
      expect(match('Screenshot_2026-09-13-20-15-00-123_com.whatsapp.jpg')!.app,
          'com.whatsapp');
      expect(match('Screenshot_20260913_201500.png')!.tool, 'Android');
      expect(match('Screenshot 2026-10-06 154500.png')!.tool,
          'Windows Snipping Tool');
      expect(match('Screenshot (12).png')!.tool, 'Windows');
      expect(match('Screenshot from 2026-10-10 09-30-00.png')!.tool, 'GNOME');
      expect(match('Bildschirmfoto 2026-10-10 um 09.30.00.png')!.tool,
          'localised');
    });

    test('macOS names: old and new, AM/PM and the narrow space', () {
      expect(match('Screen Shot 2019-03-04 at 4.15.10 PM.png')!.taken,
          DateTime(2019, 3, 4, 16, 15, 10));
      expect(match('Screenshot 2026-09-29 at 10.02.11 AM.png')!.taken,
          DateTime(2026, 9, 29, 10, 2, 11));
      expect(match('Screenshot 2026-09-29 at 12.30.00 AM (2).png')!.taken,
          DateTime(2026, 9, 29, 0, 30));
    });

    test('Game Bar names only count in a Captures folder', () {
      const name = 'Starfall Odyssey 2026-10-08 21-14-03.png';
      expect(match(name, ['videos', 'captures'])!.app, 'Starfall Odyssey');
      expect(match(name, ['documents']), isNull);
    });

    test('photo names and loose mentions are not tool names', () {
      expect(match('IMG_20260913_101500.jpg'), isNull);
      expect(match('screenshot ideas.png'), isNull);
      expect(match('Screenshot_1.png'), isNull);
      expect(looseScreenshotWords.hasMatch('Screenshot_1'), isTrue);
      expect(looseScreenshotWords.hasMatch('IMG_4821'), isFalse);
    });
  });

  group('Metadata (S02, X01)', () {
    test('camera exposure data is read from Exif', () {
      final m = readImageMetadata(camera);
      expect(m.make, 'samsung');
      expect(m.cameraTags, containsAll(['ExposureTime', 'FNumber', 'ISO']));
      expect(m.cameraEvidence, contains('samsung SM-S921B'));
      // Make and model alone (some apps copy them) aren't camera evidence.
      final copied = readImageMetadata(exifJpeg(jpg(cameraLike(3, 400, 300)),
          const ExifFields(make: 'samsung', model: 'SM-S921B')));
      expect(copied.cameraEvidence, isNull);
    });

    test('screenshot marks from iOS, macOS and capture tools', () {
      final note = png(noteScreenshot(4, w: 300, h: 650));
      String? marker(Uint8List bytes) =>
          readImageMetadata(bytes).screenshotMarker(rules.toolWords);
      expect(
          marker(pngWithText(
              note, {'XML:com.adobe.xmp': screenshotXmp(300, 650)})),
          'XMP UserComment "Screenshot"');
      expect(marker(pngWithText(note, {'Software': 'gnome-screenshot'})),
          'PNG Software "gnome-screenshot"');
      expect(
          marker(
              pngWithExif(note, const ExifFields(userComment: 'Screenshot'))),
          'Exif UserComment "Screenshot"');
      expect(
          marker(xmpJpeg(
              jpg(noteScreenshot(4, w: 300, h: 650)), screenshotXmp(300, 650))),
          isNotNull);
      expect(marker(pngWithText(note, {'Software': 'GIMP 2.10'})), isNull);
      expect(marker(camera), isNull);
    });

    test('damaged or missing metadata reads as none', () {
      expect(
          readImageMetadata(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1]))
              .toJson(),
          isEmpty);
      expect(readImageMetadata(Uint8List(0)).toJson(), isEmpty);
      final cut = pngWithText(chat, {'Software': 'ShareX'});
      expect(() => readImageMetadata(Uint8List.sublistView(cut, 0, 40)),
          returnsNormally);
    });

    test('image size comes from the header', () {
      expect(readImageSize(chat), (w, h));
      expect(readImageSize(camera), (800, 600));
      expect(readImageSize(Uint8List(10)), isNull);
    });
  });

  group('Measurement', () {
    ScreenMeasurement m(img.Image i, [bool asJpg = false]) =>
        measureScreen(asJpg ? jpg(i) : png(i), rules.measureSettings)!;

    test('a phone screenshot has a status bar and an app background', () {
      for (final app in PhoneApp.values) {
        final s = m(phoneScreenshot(app, 5, w: w, h: h), true);
        expect(s.statusBar, isTrue, reason: '${app.name}: ${s.evidence}');
        expect(s.dominantShare, greaterThan(rules.uiDominantShare),
            reason: app.name);
      }
    });

    test('camera pictures, wallpapers and graphics have no status bar', () {
      for (final picture in [
        cameraLike(6, w, h),
        flatGraphic(7, w, 960),
        adjustPhoto(receiptPhoto(8), 8, 2),
      ]) {
        final s = m(picture, true);
        expect(s.statusBar, isFalse, reason: s.evidence);
      }
      expect(m(cameraLike(6, w, h), true).dominantShare,
          lessThan(rules.uiDominantShare));
    });

    test('blank and empty screens cross the blank share; a note does not', () {
      final black = m(blankScreen(w, h, img.ColorRgb8(0, 0, 0)), true);
      expect(black.dominantShare, greaterThanOrEqualTo(rules.blankShare));
      expect(black.colorName, 'black');
      final bars =
          m(blankScreen(w, h, img.ColorRgb8(255, 255, 255), bars: true), true);
      expect(bars.contentDominantShare, greaterThanOrEqualTo(rules.blankShare));
      final desktop = m(blankDesktop(w: 960, h: 540));
      expect(
          desktop.contentDominantShare, greaterThanOrEqualTo(rules.blankShare));
      expect(desktop.dominantShare, lessThan(rules.blankShare));
      final note = m(noteScreenshot(9, w: w, h: h));
      expect(note.contentDominantShare, lessThan(rules.blankShare));
      expect(note.contentDominantShare, greaterThan(0.95));
    });

    test("data that won't decode measures as null", () {
      expect(
          measureScreen(
              Uint8List.fromList(chat.sublist(0, 100)), rules.measureSettings),
          isNull);
    });
  });

  group('Rules', () {
    test('S01–S06 on one phone', () async {
      final r = await scan({
        'Pictures/Screenshots/Screenshot_20260913-201500_Chrome.jpg':
            jpg(phoneScreenshot(PhoneApp.article, 10, w: w, h: h)),
        'Exports/IMG_4821.PNG': pngWithText(
            png(phoneScreenshot(PhoneApp.settings, 11, w: w, h: h)),
            {'XML:com.adobe.xmp': screenshotXmp(w, h)}),
        'Pictures/Screenshots/edited.png': png(img.copyCrop(
            phoneScreenshot(PhoneApp.feed, 12, w: w, h: h),
            x: 0,
            y: 300,
            width: 500,
            height: 480)),
        'Pictures/WhatsApp/IMG-20261003-WA0011.jpg':
            jpg(phoneScreenshot(PhoneApp.chat, 13, w: w, h: h), 70),
        'Pictures/Screenshots/Screenshot_20260918-220000_Netflix.jpg':
            jpg(blankScreen(w, h, img.ColorRgb8(0, 0, 0))),
        'Pictures/Screenshots/Screenshot_20260919-071500.png':
            png(blankScreen(w, h, img.ColorRgb8(255, 255, 255), bars: true)),
      });
      expect(
          ruleOf(
              r, 'Pictures/Screenshots/Screenshot_20260913-201500_Chrome.jpg'),
          'S01');
      expect(ruleOf(r, 'Exports/IMG_4821.PNG'), 'S02');
      expect(ruleOf(r, 'Pictures/Screenshots/edited.png'), 'S03');
      expect(ruleOf(r, 'Pictures/WhatsApp/IMG-20261003-WA0011.jpg'), 'S04');
      final blank = verdict(
          r, 'Pictures/Screenshots/Screenshot_20260918-220000_Netflix.jpg');
      expect(blank.rule.code, 'S05');
      expect(blank.identifiedBy, ScreenshotRule.s01SystemName);
      expect(blank.signals.map((s) => s.rule.code), ['S01', 'S03']);
      expect(blank.reason, contains('black'));
      expect(ruleOf(r, 'Pictures/Screenshots/Screenshot_20260919-071500.png'),
          'S06');
      final chrome = verdict(
          r, 'Pictures/Screenshots/Screenshot_20260913-201500_Chrome.jpg');
      expect(chrome.app, 'Chrome');
      expect(chrome.kind, ScreenKind.phone);
      expect(chrome.reason, 'Phone screenshot of Chrome, taken 13 Sep 2026');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a blank image with no screenshot signal is not S05', () async {
      final r = await scan({
        'Download/black.png': png(blankScreen(w, h, img.ColorRgb8(0, 0, 0))),
      });
      expect(r.verdicts, isEmpty);
    });

    test('camera data overrides the name and folder (X01)', () async {
      final r = await scan({
        'Pictures/Screenshots/IMG_1.jpg': camera,
        'Pictures/Screenshots/Screenshot_20260913-201500.jpg': camera,
        'DCIM/Camera/IMG_2.jpg': camera,
      });
      expect(r.verdicts, isEmpty);
      expect(notes(r, 'Pictures/Screenshots/IMG_1.jpg'), {'cameraPhoto'});
      expect(notes(r, 'Pictures/Screenshots/Screenshot_20260913-201500.jpg'),
          {'cameraPhoto'});
      // No screenshot signal: ruled out by its header, never decoded.
      expect(notes(r, 'DCIM/Camera/IMG_2.jpg'), isEmpty);
      expect(r.analysis.imagesDecoded, 0);
      expect(r.analysis.skippedByHeader, 1);
    });

    test(
        'unsignalled landscape images are not decoded; phone-shaped flat '
        'graphics are noted (X03)', () async {
      final r = await scan({
        'Download/photo.jpg': jpg(cameraLike(14, 800, 600), 60),
        'Download/slide.png': png(flatGraphic(15, 960, 540)),
        'Pictures/story.png': png(flatGraphic(16, 540, 960)),
        'Download/portrait.jpg': jpg(cameraLike(17, 450, 800), 60),
      });
      expect(r.verdicts, isEmpty);
      expect(r.analysis.skippedByHeader, 2);
      expect(r.analysis.imagesDecoded, 2);
      expect(notes(r, 'Pictures/story.png'), {'possibleScreenshot'});
      expect(notes(r, 'Download/portrait.jpg'), isEmpty);
    });

    test('recent screenshots are held back (X02), blank ones are not',
        () async {
      final files = {
        'Pictures/Screenshots/Screenshot_1.png': chat,
        'Pictures/Screenshots/Screenshot_2.png':
            png(blankScreen(w, h, img.ColorRgb8(0, 0, 0))),
      };
      // MemoryStorageSource files are modified 2026-01-01.
      DateTime soon() => DateTime(2026, 1, 1, 12);
      final r = await scan(files, clock: soon);
      expect(ruleOf(r, 'Pictures/Screenshots/Screenshot_1.png'), isNull);
      expect(notes(r, 'Pictures/Screenshots/Screenshot_1.png'), {'recent'});
      expect(ruleOf(r, 'Pictures/Screenshots/Screenshot_2.png'), 'S05');
      final all = await scan(files,
          clock: soon,
          rules: const ScreenshotRules(recentWindow: Duration.zero));
      expect(ruleOf(all, 'Pictures/Screenshots/Screenshot_1.png'), 'S03');
    });

    test('switching rules off falls through; min confidence drops likely',
        () async {
      final files = {
        'Pictures/Screenshots/Screenshot_20260913-201500.png': chat,
        'Pictures/Screenshots/Screenshot_20260918-220000.png':
            png(blankScreen(w, h, img.ColorRgb8(0, 0, 0))),
        'Pictures/WhatsApp/IMG-1.jpg':
            jpg(phoneScreenshot(PhoneApp.chat, 18, w: w, h: h)),
      };
      final noS01 = await scan(files,
          rules: const ScreenshotRules(
              disabledRules: {ScreenshotRule.s01SystemName}));
      expect(
          ruleOf(noS01, 'Pictures/Screenshots/Screenshot_20260913-201500.png'),
          'S03');
      expect(
          notes(noS01, 'Pictures/Screenshots/Screenshot_20260913-201500.png'),
          contains('suppressed'));
      final noBlank = await scan(files,
          rules: const ScreenshotRules(disabledRules: {
            ScreenshotRule.s05Blank,
            ScreenshotRule.s06EmptyScreen
          }));
      expect(
          ruleOf(
              noBlank, 'Pictures/Screenshots/Screenshot_20260918-220000.png'),
          'S01');
      final certain = await scan(files,
          rules: const ScreenshotRules(minConfidence: Confidence.certain));
      expect(ruleOf(certain, 'Pictures/WhatsApp/IMG-1.jpg'), isNull);
      expect(
          ruleOf(
              certain, 'Pictures/Screenshots/Screenshot_20260913-201500.png'),
          'S01');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('Empty and unreadable screenshots', () {
    test(
        'broken screenshot files get the empty & unreadable rules; other '
        'broken images are left out', () async {
      final damaged = Uint8List.fromList(chat);
      damaged[damaged.length ~/ 2] ^= 0xFF;
      final r = await scan({
        'Pictures/Screenshots/Screenshot_20261001-101010.png': const [],
        'Pictures/Screenshots/Screenshot_20261002-111111.png':
            chat.sublist(0, chat.length * 2 ~/ 3),
        'Download/Screenshot_20261012-090000.png.part':
            chat.sublist(0, chat.length ~/ 3),
        'Pictures/Screenshots/Screenshot_20261015-170000.png': damaged,
        'DCIM/Camera/IMG_1.jpg': const [],
        'Download/meme.png': chat.sublist(0, chat.length ~/ 2),
      });
      expect(ruleOf(r, 'Pictures/Screenshots/Screenshot_20261001-101010.png'),
          'E01');
      expect(ruleOf(r, 'Pictures/Screenshots/Screenshot_20261002-111111.png'),
          'U06');
      expect(ruleOf(r, 'Download/Screenshot_20261012-090000.png.part'), 'U03');
      expect(ruleOf(r, 'Pictures/Screenshots/Screenshot_20261015-170000.png'),
          'U07');
      expect(ruleOf(r, 'DCIM/Camera/IMG_1.jpg'), isNull);
      expect(ruleOf(r, 'Download/meme.png'), isNull);
      expect(r.verdicts, isEmpty);
      final batch = r.analysis.batches.single;
      expect(batch.id, 'unreadable');
      expect(batch.preselect, isTrue);
      expect(batch.items.length, 4);
    });
  });

  group('Edges', () {
    test("contents that can't be read are judged by name and folder (X05)",
        () async {
      final r = await scan({
        'Pictures/Screenshots/Screenshot_20260913-201500.png': chat,
        'Pictures/IMG_1.png': chat,
      }, wrap: (m) => _NoContentSource(m));
      expect(ruleOf(r, 'Pictures/Screenshots/Screenshot_20260913-201500.png'),
          'S01');
      expect(notes(r, 'Pictures/Screenshots/Screenshot_20260913-201500.png'),
          {'contentNotRead'});
      expect(ruleOf(r, 'Pictures/IMG_1.png'), isNull);
    });

    test('screen recordings are noted, not flagged (X04)', () async {
      final r = await scan({
        'Movies/Screen_Recording_20261020-161000.mp4': [
          ...ftyp,
          ...box('moov', List.filled(100, 1)),
          ...box('mdat', List.filled(2000, 7)),
        ],
      });
      expect(r.verdicts, isEmpty);
      expect(notes(r, 'Movies/Screen_Recording_20261020-161000.mp4'),
          {'screenRecording'});
    });

    test('batches group by kind of screen and pre-select blank ones', () async {
      final r = await scan({
        'Pictures/Screenshots/Screenshot_20260913-201500_Chrome.jpg':
            jpg(phoneScreenshot(PhoneApp.article, 19, w: w, h: h)),
        'Pictures/Screenshots/Screenshot (12).png':
            png(desktopScreenshot(DesktopApp.document, 20, w: 960, h: 540)),
        'Pictures/Screenshots/Screenshot (13).png':
            png(blankDesktop(w: 960, h: 540)),
      });
      expect([for (final b in r.analysis.batches) b.id],
          ['empty', 'phone', 'computer']);
      expect(r.analysis.batches.first.preselect, isTrue);
      expect(r.analysis.batches[1].apps, {'Chrome': 1});
      expect(r.report.findings.length, 3);
    });

    test('the storage permission gate applies', () async {
      final device = FakeDevice({'Pictures/Screenshots/Screenshot_1.png': chat},
          permissions: {ScanPermission.storage: PermissionState.denied});
      await expectLater(ScreenshotScan(device: device).run(),
          throwsA(isA<PermissionDeniedException>()));
      expect(device.memory.accessCount, 0);
    });
  });
}

/// Like the iOS photo library: items are listed but their bytes can't be
/// read.
final class _NoContentSource implements StorageSource {
  _NoContentSource(this.inner);
  final StorageSource inner;

  @override
  Stream<StorageItem> listItems({void Function(ScanIssue)? onIssue}) =>
      inner.listItems(onIssue: onIssue);
  @override
  bool canReadContent(StorageItem item) => false;
  @override
  bool canDecodeThumbnail(StorageItem item) => inner.canDecodeThumbnail(item);
  @override
  Future<Uint8List> readRange(StorageItem item, int start, int end) =>
      throw StateError('read');
  @override
  Stream<List<int>> openRead(StorageItem item) => throw StateError('read');
  @override
  Future<Thumbnail?> loadThumbnail(StorageItem item, int size) =>
      inner.loadThumbnail(item, size);
}
