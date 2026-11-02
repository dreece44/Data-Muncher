import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

import '../duplicate_photos/matcher.dart' show PairCheck;
import 'measure.dart';
import 'rules.dart';

/// A sharper shot of the same scene, taken close in time: what makes a
/// photo a blurry attempt (B04).
final class Retake {
  const Retake(
      this.item, this.measurement, this.gap, this.check, this.detailAgreement);

  final StorageItem item;
  final BlurMeasurement measurement;

  /// How long after (positive) or before (negative) the blurry photo.
  final Duration gap;

  /// How the two photos matched (the duplicate photo scan's comparison).
  final PairCheck check;

  /// How well the photos' fine detail lines up once the sharper one is
  /// blurred to match (−1…1; see retake.dart).
  final double detailAgreement;

  String get when {
    final s = gap.inSeconds.abs();
    final amount = s < 60
        ? '$s s'
        : s < 3600
            ? '${s ~/ 60} min'
            : '${s ~/ 3600} h';
    return gap.isNegative ? '$amount earlier' : '$amount later';
  }

  Map<String, Object?> toJson() => {
        'id': item.id,
        'gapSeconds': gap.inSeconds,
        'blurWidth': double.parse(measurement.blurWidth.toStringAsFixed(2)),
        'match': check.toJson(),
        'detailAgreement': double.parse(detailAgreement.toStringAsFixed(3)),
      };
}

/// A photo the scan flagged as blurry.
final class BlurVerdict {
  const BlurVerdict({
    required this.item,
    required this.rule,
    required this.measurement,
    required this.score,
    required this.reason,
    this.retake,
  });

  final StorageItem item;
  final BlurRule rule;
  final BlurMeasurement measurement;

  /// Blurriness 0–100; the ranking key.
  final double score;

  /// Shown to the user (becomes [Finding.reason]).
  final String reason;

  /// The sharper shot, for B04.
  final Retake? retake;

  Confidence get confidence => rule.confidence;

  /// For B04 the sharper shot is included and suggested to keep, so the
  /// user sees both side by side and only the blurry one is reclaimable.
  Finding toFinding(WasteCategory category) => Finding(
        category: category,
        items: [item, if (retake != null) retake!.item],
        keep: retake?.item,
        reason: reason,
      );

  Map<String, Object?> toJson() => {
        'rule': rule.code,
        'confidence': confidence.name,
        'score': double.parse(score.toStringAsFixed(1)),
        'reason': reason,
        'measurement': measurement.toJson(),
        if (retake != null) 'sharperRetake': retake!.toJson(),
        'item': item.toJson(),
      };
}

/// One measured photo in the blurriest-first ranking.
final class RankedPhoto {
  const RankedPhoto(this.item, this.measurement, this.score, this.rule);

  final StorageItem item;
  final BlurMeasurement measurement;
  final double score;

  /// The rule it was flagged under, or null if it wasn't.
  final BlurRule? rule;

  Map<String, Object?> toJson() => {
        'id': item.id,
        'score': double.parse(score.toStringAsFixed(1)),
        'blurWidth': double.parse(measurement.blurWidth.toStringAsFixed(2)),
        'rule': rule?.code,
      };
}

/// A photo the scan left out, or a near-miss worth knowing about when
/// tuning.
final class BlurObservation {
  const BlurObservation(this.kind, this.ids, this.detail);

  final BlurObservationKind kind;
  final List<String> ids;
  final String detail;

  Map<String, Object?> toJson() =>
      {'kind': kind.name, 'ids': ids, 'detail': detail};

  @override
  String toString() =>
      '${kind.name} ${ids.map(p.basename).join(' + ')}: $detail';
}

enum BlurObservationKind {
  /// X01: a flat-colour photo; left to the blank-photo scan.
  blank,

  /// X02: smaller than a photo (icon, sticker).
  tooSmall,

  /// X03: a screenshot, not a camera photo.
  screenshot,

  /// X04: too little detail to tell whether it's in focus (fog, sky, a
  /// plain wall, darkness).
  lowDetail,

  /// X05: a format this device can't decode (HEIC on a computer, RAW).
  cantDecode,

  /// X06: larger than the decode limit.
  tooLarge,

  /// The format can be decoded but this file couldn't, and the empty &
  /// unreadable checks didn't flag it either. Worth a look when tuning.
  undecodable,

  /// The file couldn't be read.
  unreadable,

  /// P01: the background is soft but part of the photo is sharp (portrait
  /// mode, a panning shot). Not flagged.
  sharpSubject,

  /// A sharper shot with the same layout whose fine detail differs (a
  /// different receipt on the same table): not used as a retake.
  retakeRejected,

  /// Just below the blurry threshold.
  nearMiss,

  /// A rule matched but was dropped (disabled, or below the confidence
  /// threshold).
  suppressed,
}
