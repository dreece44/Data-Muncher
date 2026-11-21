import 'dart:typed_data';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:image/image.dart' as img;
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

import 'support/fake_device.dart';

/// Rule behaviour on small in-memory photos. The full scenarios are checked
/// against the generated test area in blurry_test_area_test.dart.
void main() {
  const rules = BlurryPhotoRules();
  final scene = reframe(landscapeScene(1, 1900, 1400), .5, .5, 1600, 1200);
  final sharp = cameraSharp(scene, 1);

  BlurMeasurement measure(img.Image photo, {int quality = 90}) {
    final bytes = Uint8List.fromList(img.encodeJpg(photo, quality: quality));
    var thumb = PureDartThumbnailDecoder.decodeSync(bytes, rules.analysisSize)!;
    final shorter = thumb.sourceWidth < thumb.sourceHeight
        ? thumb.sourceWidth
        : thumb.sourceHeight;
    if (shorter < rules.analysisSize) {
      thumb = PureDartThumbnailDecoder.decodeSync(bytes, shorter)!;
    }
    return BlurMeasurement.fromThumbnail(thumb, rules.measureSettings);
  }

  Future<BlurryPhotoResult> scan(Map<String, List<int>> files,
          {BlurryPhotoRules rules = const BlurryPhotoRules()}) =>
      BlurryPhotoScan(device: FakeDevice(files), rules: rules).run();

  String? ruleOf(BlurryPhotoResult r, String path) {
    for (final v in r.verdicts) {
      if (v.item.id == path) return v.rule.code;
    }
    for (final v in r.analysis.health) {
      if (v.item.id == path) return v.rule.code;
    }
    return null;
  }

  Set<String> notes(BlurryPhotoResult r, String path) => {
        for (final o in r.analysis.observations)
          if (o.ids.contains(path)) o.kind.name
      };

  List<int> jpg(img.Image photo) => img.encodeJpg(photo, quality: 90);

  group('Measurement', () {
    test('a sharp photo measures under the sharp width', () {
      final m = measure(sharp);
      expect(m.judgeable, isTrue);
      expect(m.blurWidth, lessThan(rules.softWidth));
      expect(m.score(rules.sharpWidth), lessThan(40));
    });

    test('blur width grows with the amount of focus blur', () {
      final widths = [
        for (final r in [0, 3, 6, 9, 14])
          measure(r == 0 ? sharp : outOfFocus(scene, r, 1)).blurWidth
      ];
      for (var i = 1; i < widths.length; i++) {
        expect(widths[i], greaterThan(widths[i - 1]), reason: '$widths');
      }
      expect(widths[2], greaterThan(rules.blurryWidth));
      expect(widths[4], greaterThan(rules.severeWidth));
    });

    test('motion blur is soft in one direction only', () {
      final m = measure(motionBlur(scene, 14, 0, 1));
      expect(m.softestDirection, EdgeDirection.horizontal);
      expect(m.directionality, greaterThan(rules.motionRatio));
      final focus = measure(outOfFocus(scene, 9, 1));
      expect(focus.directionality, lessThan(rules.motionRatio));
    });

    test('a soft background does not hide a sharp subject', () {
      final m = measure(portraitMode(scene, 10, 1));
      expect(m.medianWidth, greaterThan(rules.blurryWidth));
      expect(m.blurWidth, lessThan(rules.softWidth));
    });

    test('small photos are measured at their own size, not upscaled', () {
      final small = cameraSharp(
          reframe(landscapeScene(2, 760, 560), .5, .5, 640, 480), 2);
      final m = measure(small);
      expect(m.analysisSize, 480);
      expect(m.blurWidth, lessThan(rules.blurryWidth));
    });

    test('heavy JPEG compression is not mistaken for blur', () {
      expect(measure(sharp, quality: 25).blurWidth, lessThan(rules.softWidth));
    });

    test('a featureless photo has nothing to judge', () {
      expect(measure(featureless(1, 1600, 1200)).judgeable, isFalse);
    });
  });

  group('Rules', () {
    test('B01 / B02 / B03 by how and how much the photo is blurred', () async {
      // Different scenes: in-memory files share one timestamp, so a sharp
      // photo of the same scene would make each a blurry attempt (B04).
      img.Image other(int seed) =>
          reframe(landscapeScene(seed, 1900, 1400), .5, .5, 1600, 1200);
      final r = await scan({
        'DCIM/severe.jpg': jpg(outOfFocus(scene, 14, 1)),
        'DCIM/blurry.jpg': jpg(outOfFocus(other(2), 7, 2)),
        'DCIM/shake.jpg': jpg(motionBlur(other(3), 14, 0, 3)),
        'DCIM/sharp.jpg': jpg(cameraSharp(other(4), 4)),
      });
      expect(ruleOf(r, 'DCIM/severe.jpg'), 'B01');
      expect(ruleOf(r, 'DCIM/blurry.jpg'), 'B02');
      expect(ruleOf(r, 'DCIM/shake.jpg'), 'B03');
      expect(ruleOf(r, 'DCIM/sharp.jpg'), isNull);
      expect(r.analysis.ranking.first.item.id, 'DCIM/severe.jpg');
      expect(r.analysis.ranking.last.item.id, 'DCIM/sharp.jpg');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('B04 needs a sharper shot of the same scene', () async {
      final r = await scan({
        'DCIM/attempt.jpg': jpg(outOfFocus(scene, 4, 1)),
        'DCIM/retake.jpg': jpg(cameraSharp(
            reframe(landscapeScene(1, 1900, 1400), .52, .5, 1600, 1200), 2)),
        'DCIM/other_soft.jpg': jpg(outOfFocus(
            reframe(landscapeScene(5, 1900, 1400), .5, .5, 1600, 1200), 4, 3)),
      });
      expect(ruleOf(r, 'DCIM/attempt.jpg'), 'B04');
      final verdict = r.verdicts.firstWhere((v) => v.rule.code == 'B04');
      expect(verdict.retake!.item.id, 'DCIM/retake.jpg');
      final finding = verdict.toFinding(blurryCategoryStandIn);
      expect(finding.keep!.id, 'DCIM/retake.jpg');
      expect(finding.removable.single.id, 'DCIM/attempt.jpg');
      // Equally soft, but no sharper shot of its scene: not flagged.
      expect(ruleOf(r, 'DCIM/other_soft.jpg'), isNull);
      expect(ruleOf(r, 'DCIM/retake.jpg'), isNull);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('B04 rejects a different receipt in the same layout', () async {
      // Receipt 155 slightly soft vs receipt 117 sharp: alike enough at low
      // resolution to pass the duplicate scan's near-identical-shot test.
      final soft = img.encodeJpg(outOfFocus(receiptPhoto(155), 3, 155));
      final fp = PhotoFingerprint.fromThumbnail(
          PureDartThumbnailDecoder.decodeSync(
              Uint8List.fromList(soft), rules.analysisSize)!);
      final other = img.encodeJpg(cameraSharp(receiptPhoto(117), 117));
      final fpOther = PhotoFingerprint.fromThumbnail(
          PureDartThumbnailDecoder.decodeSync(
              Uint8List.fromList(other), rules.analysisSize)!);
      expect(
          comparePhotos(fp, fpOther, const DuplicatePhotoRules(),
                  shotAllowed: true)
              ?.rule,
          DuplicateRule.d06SimilarShot);

      final r = await scan({
        'DCIM/receipt_155.jpg': soft,
        'DCIM/receipt_117.jpg': other,
        'DCIM/receipt_155_retake.jpg':
            img.encodeJpg(cameraSharp(receiptPhoto(155, dx: .01), 7)),
      });
      // The real retake is found; the look-alike was considered and refused.
      expect(ruleOf(r, 'DCIM/receipt_155.jpg'), 'B04');
      final verdict = r.verdicts.single;
      expect(verdict.retake!.item.id, 'DCIM/receipt_155_retake.jpg');
      expect(verdict.retake!.detailAgreement,
          greaterThanOrEqualTo(rules.retakeDetailAgreement));
      expect(notes(r, 'DCIM/receipt_155.jpg'), contains('retakeRejected'));

      final alone = await scan({
        'DCIM/receipt_155.jpg': soft,
        'DCIM/receipt_117.jpg': other,
      });
      expect(alone.verdicts, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a disabled rule falls through; min confidence drops likely ones',
        () async {
      final files = {
        'DCIM/attempt.jpg': jpg(outOfFocus(scene, 6, 1)),
        'DCIM/retake.jpg': jpg(sharp),
      };
      final normal = await scan(files);
      expect(ruleOf(normal, 'DCIM/attempt.jpg'), 'B04');
      final noB04 = await scan(files,
          rules: const BlurryPhotoRules(
              disabledRules: {BlurRule.b04BlurryAttempt}));
      expect(ruleOf(noB04, 'DCIM/attempt.jpg'), 'B02');
      expect(notes(noB04, 'DCIM/attempt.jpg'), contains('suppressed'));
      final certainOnly = await scan(files,
          rules: const BlurryPhotoRules(
              disabledRules: {BlurRule.b04BlurryAttempt},
              minConfidence: Confidence.certain));
      expect(ruleOf(certainOnly, 'DCIM/attempt.jpg'), isNull);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('screenshots, icons, blank and featureless photos are left out',
        () async {
      final flat = img.Image(width: 800, height: 600);
      img.fill(flat, color: img.ColorRgb8(10, 10, 10));
      final r = await scan({
        'Pictures/Screenshots/Screenshot_1.png':
            img.encodePng(outOfFocus(scene, 9, 1, noise: 0)),
        'Pictures/icon.png': img.encodePng(img.copyResize(sharp, width: 120)),
        'DCIM/pocket.jpg': jpg(flat),
        'DCIM/fog.jpg': jpg(featureless(2, 1600, 1200)),
      });
      expect(r.verdicts, isEmpty);
      expect(notes(r, 'Pictures/Screenshots/Screenshot_1.png'), {'screenshot'});
      expect(notes(r, 'Pictures/icon.png'), {'tooSmall'});
      expect(notes(r, 'DCIM/pocket.jpg'), {'blank'});
      expect(notes(r, 'DCIM/fog.jpg'), {'lowDetail'});
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('empty and unreadable photos get the empty & unreadable rules',
        () async {
      final good = jpg(sharp);
      final r = await scan({
        'Download/empty.jpg': const [],
        'Download/half.jpg': [
          ...good.sublist(0, good.length * 6 ~/ 10),
          ...List.filled(good.length - good.length * 6 ~/ 10, 0)
        ],
        'Download/photo.jpg.crdownload': good.sublist(0, good.length ~/ 3),
        'Download/page.jpg':
            '<!DOCTYPE html><html><body>Expired</body></html>'.codeUnits,
        'Documents/empty.txt': const [],
      });
      expect(ruleOf(r, 'Download/empty.jpg'), 'E01');
      expect(ruleOf(r, 'Download/half.jpg'), 'U06');
      expect(ruleOf(r, 'Download/photo.jpg.crdownload'), 'U03');
      expect(ruleOf(r, 'Download/page.jpg'), 'U05');
      // Not a photo: left to the empty & unreadable scan's own report.
      expect(ruleOf(r, 'Documents/empty.txt'), isNull);
      expect(r.verdicts, isEmpty);
      expect(r.analysis.photosMeasured, 0);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the storage permission gate applies', () async {
      final device = FakeDevice({'DCIM/a.jpg': jpg(sharp)},
          permissions: {ScanPermission.storage: PermissionState.denied});
      await expectLater(BlurryPhotoScan(device: device).run(),
          throwsA(isA<PermissionDeniedException>()));
      expect(device.memory.accessCount, 0);
    });
  });
}
