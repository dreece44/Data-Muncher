import 'dart:math';

import 'package:image/image.dart' as img;

/// DAT-16 / PB-03: Wasteful-file classification ruleset.
///
/// Pipeline: decoded thumbnail -> [AssetFeatures] -> [WasteClassifier] (ordered
/// list of [WasteRule]s) -> [Verdict]s. Every verdict carries the rule id and a
/// human-readable reason so the UI can explain why something was flagged.

enum WasteCategory { duplicate, empty, blurry }

/// All tunable thresholds live here so the ruleset can be adjusted in one place.
class RuleConfig {
  /// Laplacian variance below this = blurry (images only).
  final double blurThreshold;

  /// A frame is "black" when mean luminance <= this (0-255)...
  final double blackMeanMax;

  /// ...and luminance standard deviation <= this.
  final double blackStdMax;

  const RuleConfig({this.blurThreshold = 60, this.blackMeanMax = 8, this.blackStdMax = 6});
}

const defaultRuleConfig = RuleConfig();

class Verdict {
  final String assetId;
  final WasteCategory category;
  final String ruleId;
  final String reason;
  const Verdict(this.assetId, this.category, this.ruleId, this.reason);
}

/// Measurements taken from one thumbnail. Rules only ever look at these.
class AssetFeatures {
  static const int sample = 64;

  final String id;
  final bool isImage; // false = video
  final bool unreadable;
  final int durationSec;
  final double mean; // luminance 0-255
  final double std; // luminance standard deviation
  final double sharpness; // Laplacian variance (higher = sharper)
  final String hash; // 64-bit difference hash as '0'/'1'

  const AssetFeatures._(this.id, this.isImage, this.unreadable, this.durationSec, this.mean, this.std,
      this.sharpness, this.hash);

  /// Pass a null [im] for a file that could not be decoded.
  factory AssetFeatures.fromImage(String id, img.Image? im, {required bool isImage, int durationSec = 0}) {
    if (im == null) return AssetFeatures._(id, isImage, true, durationSec, 0, 0, 0, '');

    final gray = img.grayscale(im);
    final s = img.copyResize(gray, width: sample, height: sample);
    final px = [
      for (var y = 0; y < sample; y++) for (var x = 0; x < sample; x++) s.getPixel(x, y).luminance.toDouble()
    ];
    final mean = px.reduce((a, b) => a + b) / px.length;
    final variance = px.fold<double>(0, (t, v) => t + (v - mean) * (v - mean)) / px.length;

    final lap = <double>[];
    for (var y = 1; y < sample - 1; y++) {
      for (var x = 1; x < sample - 1; x++) {
        lap.add(px[(y - 1) * sample + x] +
            px[(y + 1) * sample + x] +
            px[y * sample + x - 1] +
            px[y * sample + x + 1] -
            4 * px[y * sample + x]);
      }
    }
    final lm = lap.reduce((a, b) => a + b) / lap.length;
    final sharp = lap.fold<double>(0, (t, v) => t + (v - lm) * (v - lm)) / lap.length;

    final h = img.copyResize(gray, width: 9, height: 8);
    final bits = StringBuffer();
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        bits.write(h.getPixel(x, y).luminance > h.getPixel(x + 1, y).luminance ? '1' : '0');
      }
    }
    return AssetFeatures._(id, isImage, false, durationSec, mean, sqrt(variance), sharp, bits.toString());
  }
}

abstract class WasteRule {
  String get id;
  WasteCategory get category;

  /// Returns a verdict if the asset matches, otherwise null.
  Verdict? evaluate(AssetFeatures f);
}

/// R1: file could not be decoded (failed download, corrupt file).
class UnreadableRule extends WasteRule {
  @override
  final id = 'R1-unreadable';
  @override
  final category = WasteCategory.empty;

  @override
  Verdict? evaluate(AssetFeatures f) =>
      f.unreadable ? Verdict(f.id, category, id, 'File is unreadable or corrupt') : null;
}

/// R2: photo or video frame is essentially a black screen.
class BlackFrameRule extends WasteRule {
  final RuleConfig cfg;
  BlackFrameRule(this.cfg);
  @override
  final id = 'R2-black-frame';
  @override
  final category = WasteCategory.empty;

  @override
  Verdict? evaluate(AssetFeatures f) => (!f.unreadable && f.mean <= cfg.blackMeanMax && f.std <= cfg.blackStdMax)
      ? Verdict(f.id, category, id, 'Black screen')
      : null;
}

/// R3: photo is too blurry. Not applied to videos.
class BlurRule extends WasteRule {
  final RuleConfig cfg;
  BlurRule(this.cfg);
  @override
  final id = 'R3-blurry';
  @override
  final category = WasteCategory.blurry;

  @override
  Verdict? evaluate(AssetFeatures f) => (f.isImage && f.sharpness < cfg.blurThreshold)
      ? Verdict(f.id, category, id, 'Sharpness ${f.sharpness.toStringAsFixed(1)} is below ${cfg.blurThreshold}')
      : null;
}

/// R4: same media type, same video duration and same perceptual hash as an
/// earlier asset. The first one seen is kept as the original.
class DuplicateRule extends WasteRule {
  final _seen = <String, String>{};
  @override
  final id = 'R4-duplicate';
  @override
  final category = WasteCategory.duplicate;

  @override
  Verdict? evaluate(AssetFeatures f) {
    if (f.unreadable) return null;
    final key = '${f.isImage}-${f.durationSec}-${f.hash}';
    final original = _seen[key];
    if (original == null) {
      _seen[key] = f.id;
      return null;
    }
    return Verdict(f.id, category, id, 'Duplicate of $original');
  }
}

/// Applies the ruleset in order. Precedence:
/// 1. Empty rules (R1, R2) are exclusive: an empty file is not also reported
///    as blurry or duplicate.
/// 2. Otherwise blur (R3) and duplicate (R4) can both apply.
///
/// Stateful (duplicate detection), so create one classifier per scan.
class WasteClassifier {
  final UnreadableRule _unreadable = UnreadableRule();
  final BlackFrameRule _black;
  final BlurRule _blur;
  final DuplicateRule _dup = DuplicateRule();

  WasteClassifier([RuleConfig cfg = defaultRuleConfig])
      : _black = BlackFrameRule(cfg),
        _blur = BlurRule(cfg);

  List<Verdict> classify(AssetFeatures f) {
    for (final r in [_unreadable, _black]) {
      final v = r.evaluate(f);
      if (v != null) return [v];
    }
    final out = <Verdict>[];
    for (final r in [_blur, _dup]) {
      final v = r.evaluate(f);
      if (v != null) out.add(v);
    }
    return out;
  }
}
