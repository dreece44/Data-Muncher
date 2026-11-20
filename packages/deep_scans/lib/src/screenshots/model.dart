import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

import '../empty_unreadable/verdict.dart';
import 'measure.dart';
import 'metadata.dart';
import 'rules.dart';

/// What kind of screen a screenshot is of, from its shape.
enum ScreenKind {
  phone('Phone screenshots'),
  tablet('Tablet screenshots'),
  computer('Computer screenshots'),
  unknown('Other screenshots');

  const ScreenKind(this.label);
  final String label;
}

/// One signal that an image is a screenshot. An image can have several
/// (a system name in a Screenshots folder); the strongest decides its rule
/// and the rest are kept as evidence.
final class ScreenshotSignal {
  const ScreenshotSignal(this.rule, this.detail);

  /// The identification rule this signal supports (S01–S04).
  final ScreenshotRule rule;
  final String detail;

  Map<String, Object?> toJson() => {'rule': rule.code, 'detail': detail};

  @override
  String toString() => '${rule.code}: $detail';
}

/// An image the scan flagged as a screenshot.
final class ScreenshotVerdict {
  const ScreenshotVerdict({
    required this.item,
    required this.rule,
    required this.identifiedBy,
    required this.signals,
    required this.kind,
    required this.reason,
    this.app,
    this.taken,
    this.measurement,
    this.metadata = ImageMetadata.none,
  });

  final StorageItem item;
  final ScreenshotRule rule;

  /// The identification rule (S01–S04). The same as [rule] unless the
  /// screenshot is also blank (S05/S06).
  final ScreenshotRule identifiedBy;
  final List<ScreenshotSignal> signals;
  final ScreenKind kind;

  /// Shown to the user (becomes [Finding.reason]).
  final String reason;

  /// The app or game on screen, when the name says.
  final String? app;

  /// When it was taken: from the name, else last modified.
  final DateTime? taken;

  /// The pixel measurement, if the image was decoded.
  final ScreenMeasurement? measurement;
  final ImageMetadata metadata;

  Confidence get confidence => rule.confidence;

  Finding toFinding(WasteCategory category) =>
      Finding(category: category, items: [item], reason: reason);

  Map<String, Object?> toJson() => {
        'rule': rule.code,
        'identifiedBy': identifiedBy.code,
        'confidence': confidence.name,
        'kind': kind.name,
        'reason': reason,
        if (app != null) 'app': app,
        if (taken != null) 'taken': taken!.toIso8601String(),
        'signals': [for (final s in signals) s.toJson()],
        if (measurement != null) 'measurement': measurement!.toJson(),
        if (metadata.toJson().isNotEmpty) 'metadata': metadata.toJson(),
        'item': item.toJson(),
      };
}

/// A screenshot file the empty & unreadable checks flagged (0-byte,
/// cut off, damaged, still downloading). Reported under that scan's rule;
/// recognised as a screenshot by its name or folder alone, since its
/// contents can't be trusted.
final class ScreenshotHealth {
  const ScreenshotHealth(this.verdict, this.signal);

  final FileVerdict verdict;
  final ScreenshotSignal signal;

  StorageItem get item => verdict.item;

  Map<String, Object?> toJson() =>
      {...verdict.toJson(), 'screenshotSignal': signal.toJson()};
}

/// A group of findings for reviewing and clearing in bulk (DAT-23).
final class ScreenshotBatch {
  const ScreenshotBatch(this.id, this.label, this.items,
      {this.preselect = false, this.old = 0, this.apps = const {}});

  final String id;
  final String label;
  final List<StorageItem> items;

  /// Nothing in it is worth keeping: the review UI can tick them all.
  final bool preselect;

  /// How many are older than `ScreenshotRules.oldAge`.
  final int old;

  /// Count by app, where the name says.
  final Map<String, int> apps;

  int get bytes => items.fold(0, (s, i) => s + i.sizeBytes);

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'count': items.length,
        'bytes': bytes,
        'preselect': preselect,
        'old': old,
        if (apps.isNotEmpty) 'apps': apps,
        'ids': [for (final i in items) i.id],
      };
}

/// An image the scan looked at closely but didn't flag, recorded so tuning
/// can see near-misses.
final class ScreenshotObservation {
  const ScreenshotObservation(this.kind, this.id, this.detail);

  final ScreenshotObservationKind kind;
  final String id;
  final String detail;

  Map<String, Object?> toJson() =>
      {'kind': kind.name, 'id': id, 'detail': detail};

  @override
  String toString() => '${kind.name} ${p.basename(id)}: $detail';
}

enum ScreenshotObservationKind {
  /// X01: named or filed as a screenshot, but camera exposure data says
  /// it's a photo (moved into the Screenshots folder, renamed).
  cameraPhoto,

  /// X02: taken within `recentWindow`; probably still in use.
  recent,

  /// X03: app-like flat colours at a screen size, but no system bars: an
  /// exported slide, story graphic or design, or a screenshot without
  /// them. Not flagged.
  possibleScreenshot,

  /// X04: a video named like a screen recording. Left to the old-video
  /// scan.
  screenRecording,

  /// X05: contents can't be read here (iOS photo library); judged by name
  /// and folder only.
  contentNotRead,

  /// X06: a format this scan can't decode (HEIC), or larger than
  /// `maxImageBytes`; judged by name, folder and metadata only.
  notDecoded,

  /// Decodable format, file won't decode, yet the empty & unreadable
  /// checks passed it. Worth a look when tuning.
  undecodable,

  /// The file couldn't be read.
  unreadable,

  /// A rule matched but was dropped (disabled, or below the confidence
  /// threshold).
  suppressed,
}
