import 'dart:math';
import 'dart:typed_data';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:image/image.dart' as img;
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

import 'support/fake_device.dart';

/// Rule behaviour on small in-memory photos. The full scenarios are checked
/// against the generated test area in duplicate_test_area_test.dart.
void main() {
  const rules = DuplicatePhotoRules();
  final scene = landscapeScene(1, 950, 700);
  final photo = reframe(scene, .5, .5, 800, 600);

  PhotoFingerprint fp(List<int> bytes) => PhotoFingerprint.fromThumbnail(
      PureDartThumbnailDecoder.decodeSync(Uint8List.fromList(bytes), 256)!);
  final original = fp(encodeJpeg(photo, 92));

  DuplicateRule? rule(img.Image other,
          {bool shotAllowed = false, bool bothOriginals = false}) =>
      comparePhotos(original, fp(encodeJpeg(other, 90)), rules,
              shotAllowed: shotAllowed, bothOriginals: bothOriginals)
          ?.rule;

  group('Fingerprint', () {
    test('every rotation/mirror hash comes from one DCT exactly', () {
      for (final t in PhotoTransform.values) {
        expect(original.full.hash(t), original.full.transformed(t).hash(),
            reason: t.name);
      }
    });

    test('borders are found and trimmed; sharpness ignores them', () {
      final boxed = fp(encodeJpeg(letterboxSquare(photo), 90));
      expect(boxed.trimmed, isNotNull);
      expect(boxed.trimmedAspect, closeTo(800 / 600, 0.05));
      expect(boxed.sharpness,
          closeTo(original.sharpness, original.sharpness * .3));
      expect(original.trimmed, isNull);
    });
  });

  group('Pair rules', () {
    test('D02 resized, re-compressed and converted copies', () {
      expect(
          rule(img.copyResize(photo, width: 400)), DuplicateRule.d02ReEncoded);
      expect(
          comparePhotos(original, fp(img.encodePng(photo)), rules,
                  shotAllowed: false)
              ?.rule,
          DuplicateRule.d02ReEncoded);
    });

    test('D03 every rotation and mirror', () {
      expect(rule(img.copyRotate(photo, angle: 90)), DuplicateRule.d03Turned);
      expect(rule(img.copyRotate(photo, angle: 180)), DuplicateRule.d03Turned);
      expect(rule(img.flipHorizontal(img.Image.from(photo))),
          DuplicateRule.d03Turned);
      expect(rule(img.flipVertical(img.Image.from(photo))),
          DuplicateRule.d03Turned);
    });

    test('D04 copy with borders; D05 brightened copy', () {
      expect(rule(letterboxSquare(photo)), DuplicateRule.d04Bordered);
      expect(rule(adjustPhoto(photo, 1, 0, brightness: 25, contrast: 1.15)),
          DuplicateRule.d05Edited);
    });

    test('D06 needs photos taken close together', () {
      final burst =
          adjustPhoto(reframe(scene, .5 + .01 * 800 / 150, .5, 800, 600), 2, 4);
      expect(rule(burst, shotAllowed: true), DuplicateRule.d06SimilarShot);
      final check = comparePhotos(original, fp(encodeJpeg(burst, 90)), rules,
          shotAllowed: false, shotBlockedReason: 'taken 3 days apart');
      expect(check?.rule, isNull);
      expect(check?.note, 'taken 3 days apart');
    });

    test(
        'D06 two first-hand camera files alike to the pixel are shots, not '
        'copies', () {
      final next = adjustPhoto(photo, 3, 2);
      expect(rule(next, shotAllowed: true), DuplicateRule.d02ReEncoded);
      expect(rule(next, shotAllowed: true, bothOriginals: true),
          DuplicateRule.d06SimilarShot);
    });

    test('D06 blurry retake of the same framing', () {
      expect(
          rule(img.gaussianBlur(img.Image.from(photo), radius: 4),
              shotAllowed: true),
          DuplicateRule.d06SimilarShot);
    });

    test('different receipts in the same layout never match', () {
      final a = fp(encodeJpeg(receiptPhoto(11), 90));
      for (final seed in [12, 13, 14]) {
        final b = fp(encodeJpeg(receiptPhoto(seed), 90));
        expect(comparePhotos(a, b, rules, shotAllowed: true)?.rule, isNull,
            reason: 'receipt $seed');
      }
    });

    test('a reframed photo of the same place is not a duplicate', () {
      expect(rule(reframe(scene, 1, .5, 800, 600), shotAllowed: true), isNull);
    });
  });

  group('Pipeline', () {
    Future<DuplicatePhotoResult> run(Map<String, List<int>> files,
        {DuplicatePhotoRules rules = const DuplicatePhotoRules(),
        Set<String> unreadable = const {}}) {
      final device = FakeDevice(files);
      device.memory.unreadable.addAll(unreadable);
      return DuplicatePhotoScan(device: device, rules: rules).run();
    }

    final jpg = encodeJpeg(photo, 92);
    final raw = [for (var i = 0; i < 20000; i++) (i * 7919) % 251];

    test('identical copies of formats that cannot be decoded are found',
        () async {
      final r = await run({'DCIM/a.dng': raw, 'Backup/a.dng': raw});
      expect(r.groups.single.duplicates.single.rule, DuplicateRule.d01Exact);
      expect(r.groups.single.keeper.item.id, 'DCIM/a.dng');
    });

    test('blank and icon-sized photos are left out, even when identical',
        () async {
      final black =
          encodeJpeg(adjustPhoto(img.Image(width: 400, height: 300), 1, 0), 90);
      final icon = img.encodePng(img.Image(width: 64, height: 64)
        ..forEach((p) => p..r = Random(p.x * p.y).nextInt(256)));
      final r = await run(
          {'a.jpg': black, 'b.jpg': black, 'i.png': icon, 'j.png': icon});
      expect(r.groups, isEmpty);
      expect(r.analysis.observations.map((o) => o.kind).toSet(),
          {PhotoObservationKind.blank, PhotoObservationKind.tooSmall});
    });

    test('result does not depend on file order', () async {
      final files = {
        'DCIM/Camera/a.jpg': jpg,
        'Pictures/WhatsApp/b.jpg':
            encodeJpeg(img.copyResize(photo, width: 400), 70),
        'Pictures/c.jpg': encodeJpeg(img.copyRotate(photo, angle: 90), 90),
      };
      final forward = await run(files);
      final backward =
          await run(Map.fromEntries(files.entries.toList().reversed));
      String shape(DuplicatePhotoResult r) => [
            for (final m in r.groups.single.members)
              '${m.item.id}:${m.rule?.code}'
          ].join(',');
      expect(shape(backward), shape(forward));
      expect(forward.groups.single.keeper.item.id, 'DCIM/Camera/a.jpg');
    });

    test('a chain of gradually reframed shots is split, not merged', () async {
      // MemoryStorageSource gives every file the same time: all are shots.
      img.Image at(double s) =>
          adjustPhoto(reframe(scene, .2 + s * 800 / 150, .5, 800, 600), 5, 3);
      final r = await run({
        'a.jpg': encodeJpeg(at(0), 90),
        'b.jpg': encodeJpeg(at(.012), 90),
        'c.jpg': encodeJpeg(at(.024), 90),
      });
      expect(r.groups.single.members, hasLength(2));
      expect(r.analysis.observations.map((o) => o.kind),
          contains(PhotoObservationKind.split));
    });

    group('D06 fine-detail check', () {
      // MemoryStorageSource gives every file the same time: all are shots.
      List<int> receipt(int seed, {double dx = 0, double dy = 0}) =>
          encodeJpeg(cameraSharp(receiptPhoto(seed, dx: dx, dy: dy), seed), 90);

      test('different receipts in the same layout pass D06 on layout alone',
          () {
        for (final (a, b) in [(155, 117), (152, 156)]) {
          expect(
              comparePhotos(fp(receipt(a)), fp(receipt(b)), rules,
                      shotAllowed: true, bothOriginals: true)
                  ?.rule,
              DuplicateRule.d06SimilarShot,
              reason: 'receipts $a/$b');
        }
      });

      test('receipts 155 and 117 are not grouped', () async {
        final files = {
          'DCIM/Camera/r155.jpg': receipt(155),
          'DCIM/Camera/r117.jpg': receipt(117),
        };
        final r = await run(files);
        expect(r.groups, isEmpty);
        final noted = r.analysis.observations
            .where((o) => o.kind == PhotoObservationKind.detailDiffers);
        expect(noted.single.ids.toSet(), files.keys.toSet());
        expect(r.analysis.detailChecks, 1);

        // The check is what keeps them apart.
        final unchecked = await run(files,
            rules: const DuplicatePhotoRules(shotDetailAgreement: -1));
        expect(unchecked.groups.single.duplicates.single.rule,
            DuplicateRule.d06SimilarShot);
      });

      test('receipts 152 and 156 are not grouped', () async {
        final r = await run({
          'DCIM/Camera/r152.jpg': receipt(152),
          'DCIM/Camera/r156.jpg': receipt(156),
        });
        expect(r.groups, isEmpty);
      });

      test('a retake of the same receipt, moved and blurred, still groups',
          () async {
        final r = await run({
          'DCIM/Camera/a.jpg': receipt(155),
          'DCIM/Camera/b.jpg': encodeJpeg(
              img.gaussianBlur(receiptPhoto(155, dx: .01, dy: .005), radius: 4),
              90),
        });
        final member = r.groups.single.duplicates.single;
        expect(member.rule, DuplicateRule.d06SimilarShot);
        expect(member.check!.detailAgreement,
            greaterThan(rules.shotDetailAgreement));
        expect(r.groups.single.keeper.item.id, 'DCIM/Camera/a.jpg');
      });
    });

    test('minConfidence and disabled rules', () async {
      final files = {
        'a.jpg': jpg,
        'b.jpg': encodeJpeg(letterboxSquare(photo), 90),
        'c.jpg': encodeJpeg(img.copyResize(photo, width: 400), 80),
      };
      final certain = await run(files,
          rules: const DuplicatePhotoRules(minConfidence: Confidence.certain));
      expect(certain.groups.single.duplicates.map((m) => m.rule),
          [DuplicateRule.d02ReEncoded]);
      final noResized = await run(files,
          rules: const DuplicatePhotoRules(
              disabledRules: {DuplicateRule.d02ReEncoded}));
      expect(noResized.groups.single.duplicates.map((m) => m.rule),
          [DuplicateRule.d04Bordered]);
    });

    test('refuses to scan, and reads nothing, without storage access',
        () async {
      final device = FakeDevice({'a.jpg': jpg},
          permissions: {ScanPermission.storage: PermissionState.denied});
      await expectLater(DuplicatePhotoScan(device: device).run(),
          throwsA(isA<PermissionDeniedException>()));
      expect(device.memory.accessCount, 0);
    });

    test('drops into ScanEngine next to the other detectors', () async {
      final device = FakeDevice({
        'DCIM/a.jpg': jpg,
        'Download/a (1).jpg': jpg,
        'notes.txt': [],
      });
      final report = await ScanEngine(device: device, detectors: [
        const EmptyFileDetector(),
        DuplicatePhotoAnalyzer().detector(),
      ]).scan();
      final dup = report.findings
          .singleWhere((f) => f.category == WasteCategory.duplicatePhoto);
      expect(dup.keep?.id, 'DCIM/a.jpg');
      expect(dup.removable.single.id, 'Download/a (1).jpg');
    });
  });
}
