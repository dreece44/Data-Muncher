import 'package:image/image.dart' as img;
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  ImageFeatures features(img.Image image) => ImageFeatures.fromThumbnail(
      PureDartThumbnailDecoder.decodeSync(jpg(image), 64)!);

  group('image fingerprints', () {
    test('match for re-saved, resized and slightly noisy copies', () {
      final original = features(scene(1));
      for (final copy in [
        features(scene(1)),
        features(img.copyResize(scene(1), width: 200, height: 150)),
        features(jitter(scene(1), noise: 4, brightness: 6)),
      ]) {
        expect(hammingDistance(original.coarseHash, copy.coarseHash),
            lessThanOrEqualTo(const ScanRules().nearDuplicateCoarseDistance));
        expect(hammingDistance(original.fineHash, copy.fineHash),
            lessThanOrEqualTo(const ScanRules().nearDuplicateFineDistance));
      }
    });

    test('differ for different photos', () {
      final a = features(scene(1)), b = features(scene(2));
      expect(hammingDistance(a.coarseHash, b.coarseHash),
          greaterThan(const ScanRules().nearDuplicateCoarseDistance));
    });

    test('tell apart two different receipts in the same layout', () {
      final a = features(receipt(1)), b = features(receipt(2));
      expect(hammingDistance(a.fineHash, b.fineHash),
          greaterThan(const ScanRules().nearDuplicateFineDistance));
    });

    test('measure flat images as having almost no detail', () {
      expect(features(flat(10)).stdDev, lessThan(1));
      expect(features(scene(1)).stdDev, greaterThan(20));
    });
  });

  group('DuplicatePhotoDetector', () {
    Future<List<Finding>> run(Map<String, List<int>> files) async =>
        (await scan(FakeDevice(files),
                detectors: [const DuplicatePhotoDetector()]))
            .findings;

    test('groups exact copies and keeps one', () async {
      final bytes = jpg(scene(1));
      final findings = await run({
        'DCIM/IMG_1.jpg': bytes,
        'WhatsApp/IMG_1.jpg': bytes,
        'DCIM/other.jpg': jpg(scene(2)),
      });
      final group = findings.single;
      expect(ids([group]), {'DCIM/IMG_1.jpg', 'WhatsApp/IMG_1.jpg'});
      expect(group.reason, contains('identical copies'));
      expect(group.removable, hasLength(1));
      expect(group.reclaimableBytes, bytes.length);
    });

    test('groups near-identical shots and keeps the highest resolution',
        () async {
      final findings = await run({
        'a_small.jpg': jpg(img.copyResize(scene(1), width: 280, height: 210)),
        'b_full.jpg': jpg(scene(1)),
        'c_burst.jpg': jpg(jitter(
            img.copyResize(scene(1), width: 300, height: 225),
            noise: 3,
            brightness: 5)),
        'unrelated.jpg': jpg(scene(9)),
      });
      final group = findings.single;
      expect(ids([group]), {'a_small.jpg', 'b_full.jpg', 'c_burst.jpg'});
      expect(group.reason, contains('near-identical'));
      expect(group.keep!.id, 'b_full.jpg');
    });

    test('does not group different receipts', () async {
      final findings = await run({
        'receipt_a.jpg': jpg(receipt(1)),
        'receipt_a_again.jpg': jpg(jitter(receipt(1), noise: 2)),
        'receipt_b.jpg': jpg(receipt(2)),
      });
      expect(ids(findings), {'receipt_a.jpg', 'receipt_a_again.jpg'});
    });

    test('leaves blank photos and tiny icons alone', () async {
      final findings = await run({
        'black1.jpg': jpg(flat(5)),
        'black2.jpg': jpg(flat(5)),
        'icon1.png': png(scene(3, width: 64, height: 64)),
        'icon2.png': png(scene(3, width: 64, height: 64)),
      });
      expect(findings, isEmpty);
    });
  });

  group('BlankPhotoDetector', () {
    test('reports black, white and flat-colour photos, not real ones',
        () async {
      final report = await scan(
        FakeDevice({
          'pocket.jpg': jpg(jitter(flat(8), noise: 3)),
          'white.png': png(flat(255)),
          'grey.jpg': jpg(flat(128)),
          'real.jpg': jpg(scene(1)),
          'small_flat_icon.png': png(flat(0, width: 48, height: 48)),
        }),
        detectors: [const BlankPhotoDetector()],
      );
      final reasons = {
        for (final f in report.findings) f.items.single.id: f.reason,
      };
      expect(reasons.keys, {'pocket.jpg', 'white.png', 'grey.jpg'});
      expect(reasons['pocket.jpg'], contains('black'));
      expect(reasons['white.png'], contains('white'));
      expect(reasons['grey.jpg'], contains('flat colour'));
    });
  });
}
