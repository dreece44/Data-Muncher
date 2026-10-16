import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:datamuncher/rules.dart';

img.Image solid(int v) {
  final im = img.Image(width: 128, height: 128);
  img.fill(im, color: img.ColorRgb8(v, v, v));
  return im;
}

/// High-contrast checkerboard = very sharp.
img.Image checker({int cell = 2}) {
  final im = img.Image(width: 128, height: 128);
  for (var y = 0; y < 128; y++) {
    for (var x = 0; x < 128; x++) {
      final v = ((x ~/ cell + y ~/ cell) % 2 == 0) ? 255 : 0;
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  return im;
}

/// Left-to-right gradient: different hash from the checkerboard, but smooth (blurry).
img.Image gradient() {
  final im = img.Image(width: 128, height: 128);
  for (var y = 0; y < 128; y++) {
    for (var x = 0; x < 128; x++) {
      im.setPixelRgb(x, y, x * 2, x * 2, x * 2);
    }
  }
  return im;
}

List<WasteCategory> cats(WasteClassifier c, String id, img.Image? im, {bool isImage = true, int dur = 0}) =>
    c.classify(AssetFeatures.fromImage(id, im, isImage: isImage, durationSec: dur)).map((v) => v.category).toList();

void main() {
  test('R1 unreadable file is empty', () {
    expect(cats(WasteClassifier(), 'a', null), [WasteCategory.empty]);
  });

  test('R2 black frame is empty, and not also blurry/duplicate', () {
    final c = WasteClassifier();
    expect(cats(c, 'a', solid(0)), [WasteCategory.empty]);
    expect(cats(c, 'b', solid(0)), [WasteCategory.empty]);
  });

  test('R3 sharp photo is kept, smooth photo is blurry', () {
    final c = WasteClassifier();
    expect(cats(c, 'sharp', checker()), isEmpty);
    expect(cats(c, 'smooth', gradient()), [WasteCategory.blurry]);
  });

  test('R3 is not applied to videos', () {
    expect(cats(WasteClassifier(), 'v', gradient(), isImage: false), isEmpty);
  });

  test('R4 second identical photo is a duplicate, first is the original', () {
    final c = WasteClassifier();
    expect(cats(c, 'orig', checker()), isEmpty);
    expect(cats(c, 'copy', checker()), [WasteCategory.duplicate]);
  });

  test('R4 videos with different durations are not duplicates', () {
    final c = WasteClassifier();
    expect(cats(c, 'v1', checker(), isImage: false, dur: 10), isEmpty);
    expect(cats(c, 'v2', checker(), isImage: false, dur: 20), isEmpty);
    expect(cats(c, 'v3', checker(), isImage: false, dur: 10), [WasteCategory.duplicate]);
  });

  test('verdicts explain themselves', () {
    final c = WasteClassifier();
    c.classify(AssetFeatures.fromImage('orig', checker(), isImage: true));
    final v = c.classify(AssetFeatures.fromImage('copy', checker(), isImage: true)).single;
    expect(v.ruleId, 'R4-duplicate');
    expect(v.reason, contains('orig'));
  });

  test('custom thresholds change the outcome', () {
    final strict = WasteClassifier(const RuleConfig(blurThreshold: 1e9));
    expect(cats(strict, 'a', checker()), [WasteCategory.blurry]);
  });
}
