import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

import '../empty_unreadable/verdict.dart';
import 'container.dart';
import 'names.dart';
import 'rules.dart';

/// Where a video's recorded date came from, most trusted first.
enum RecordedFrom {
  /// The container's creation time (MP4 `mvhd`, Matroska `DateUTC`).
  metadata,

  /// A date in the file name (`VID_20240706_181203.mp4`).
  name,

  /// The file's last-modified date. Copying a file can reset it.
  modified,

  /// Nothing says.
  unknown,
}

/// Another rule that matched a flagged video, below the one it was flagged
/// under. Kept as evidence: an old & large video that is also oversized can
/// be re-encoded instead of deleted.
final class VideoSignal {
  const VideoSignal(this.rule, this.detail);

  final VideoRule rule;
  final String detail;

  Map<String, Object?> toJson() => {'rule': rule.code, 'detail': detail};

  @override
  String toString() => '${rule.code}: $detail';
}

/// A video the scan flagged.
final class VideoVerdict {
  const VideoVerdict({
    required this.item,
    required this.rule,
    required this.confidence,
    required this.reason,
    required this.source,
    required this.recordedFrom,
    this.tool,
    this.app,
    this.recorded,
    this.info,
    this.evidence,
    this.alsoMatched = const [],
    this.estimatedSavingBytes,
  });

  final StorageItem item;
  final VideoRule rule;

  /// At most [VideoRule.confidence]: less when the age comes only from the
  /// file date, or the frame rate was assumed.
  final Confidence confidence;

  /// Shown to the user (becomes [Finding.reason]).
  final String reason;
  final VideoSource source;

  /// The recording app or camera, when the name says.
  final String? tool;

  /// The game or app recorded, when the name says.
  final String? app;
  final DateTime? recorded;
  final RecordedFrom recordedFrom;

  /// What the container says, if it was read.
  final VideoInfo? info;

  /// What the rule saw.
  final String? evidence;

  /// Other rules below [rule] that also matched.
  final List<VideoSignal> alsoMatched;

  /// V12, or any verdict where V12 also matched: what re-encoding would
  /// save.
  final int? estimatedSavingBytes;

  Finding toFinding(WasteCategory category) =>
      Finding(category: category, items: [item], reason: reason);

  Map<String, Object?> toJson() => {
        'rule': rule.code,
        'confidence': confidence.name,
        'reason': reason,
        'source': source.name,
        if (tool != null) 'tool': tool,
        if (app != null) 'app': app,
        if (recorded != null) 'recorded': recorded!.toIso8601String(),
        'recordedFrom': recordedFrom.name,
        if (evidence != null) 'evidence': evidence,
        if (alsoMatched.isNotEmpty)
          'alsoMatched': [for (final s in alsoMatched) s.toJson()],
        if (estimatedSavingBytes != null)
          'estimatedSavingBytes': estimatedSavingBytes,
        if (info != null) 'container': info!.toJson(),
        'item': item.toJson(),
      };
}

/// A video file the empty & unreadable checks flagged (0-byte, unfinished
/// download, zero-filled, no index…). Reported under that scan's rule.
final class VideoHealth {
  const VideoHealth(this.verdict, this.source);

  final FileVerdict verdict;
  final VideoSource source;

  StorageItem get item => verdict.item;

  Map<String, Object?> toJson() => {...verdict.toJson(), 'source': source.name};
}

/// A group of findings for reviewing and clearing together (DAT-24:
/// "reclaim large amounts of space quickly").
final class VideoBatch {
  const VideoBatch(this.id, this.label, this.items,
      {this.preselect = false,
      this.sources = const {},
      this.estimatedSavingBytes});

  final String id;
  final String label;

  /// Largest first.
  final List<StorageItem> items;

  /// Nothing in it can be played: the review UI can tick them all.
  final bool preselect;

  /// Count by [VideoSource] label.
  final Map<String, int> sources;

  /// For the compress batch: what re-encoding them all would save.
  final int? estimatedSavingBytes;

  int get bytes => items.fold(0, (s, i) => s + i.sizeBytes);

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'count': items.length,
        'bytes': bytes,
        'preselect': preselect,
        if (sources.isNotEmpty) 'sources': sources,
        if (estimatedSavingBytes != null)
          'estimatedSavingBytes': estimatedSavingBytes,
        'ids': [for (final i in items) i.id],
      };
}

/// A video the scan looked at but didn't flag, or a fact worth knowing
/// about one it did, recorded so tuning can see near-misses.
final class VideoObservation {
  const VideoObservation(this.kind, this.id, this.detail);

  final VideoObservationKind kind;
  final String id;
  final String detail;

  Map<String, Object?> toJson() =>
      {'kind': kind.name, 'code': kind.code, 'id': id, 'detail': detail};

  @override
  String toString() => '${kind.code} ${p.basename(id)}: ${kind.name}: $detail';
}

enum VideoObservationKind {
  /// X01: recorded within `recentWindow`; V10–V14 held back.
  recent('X01'),

  /// X02: used by an editing project changed within
  /// `activeProjectWindow`; V10–V14 held back.
  activeProject('X02'),

  /// X03: a container problem, but the file was modified within the empty
  /// & unreadable grace period: it may still be recording.
  stillWriting('X03'),

  /// X04: the movie half of an iPhone Live Photo; V10–V14 held back.
  livePhoto('X04'),

  /// X05: in an app's own folder (a game's cut-scenes); not judged.
  appData('X05'),

  /// X06: MP4/MOV index larger than `maxIndexBytes`; judged by size and
  /// date only.
  indexNotRead('X06'),

  /// X07: a container this scan doesn't open (WMV, MTS, MPG…); judged by
  /// size and date only.
  notParsed('X07'),

  /// X08: the recorded date (metadata or name) and the file date are far
  /// apart; the recorded date was used.
  datesDisagree('X08'),

  /// X09: contents can't be read here (iOS photo library); judged by size
  /// and date only.
  contentNotRead('X09'),

  /// X10: the container's creation time makes no sense (before 1995, in
  /// the future: a camera whose clock was never set); ignored.
  badMetadataDate('X10'),

  /// The file couldn't be read.
  unreadable(''),

  /// A rule matched but was dropped (disabled, or below the confidence
  /// threshold).
  suppressed('');

  const VideoObservationKind(this.code);
  final String code;
}
