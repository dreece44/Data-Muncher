import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

import 'fingerprint.dart';
import 'matcher.dart';
import 'rules.dart';

/// What the keeper ranking knows about one photo.
final class PhotoFacts {
  const PhotoFacts({
    required this.item,
    this.fingerprint,
    this.hasCameraDetails = false,
    this.secondhand = false,
    this.copyName = false,
  });

  final StorageItem item;

  /// Null for formats this device can't decode (byte-identical checks only).
  final PhotoFingerprint? fingerprint;

  /// Has EXIF camera metadata. Messaging apps and many editors strip it, so
  /// it marks the original.
  final bool hasCameraDetails;

  /// Lives in a folder that holds second-hand copies (WhatsApp, Download…).
  final bool secondhand;

  /// Name looks like a copy: "(1)", "copy", "-WA0001", "_edited".
  final bool copyName;

  int get pixels => fingerprint?.pixels ?? 0;
  double get sharpness => fingerprint?.sharpness ?? 0;

  String get dimensions => fingerprint == null
      ? 'not decoded'
      : '${fingerprint!.width}×${fingerprint!.height}';

  Map<String, Object?> toJson() => {
        'id': item.id,
        'sizeBytes': item.sizeBytes,
        if (fingerprint != null) ...{
          'width': fingerprint!.width,
          'height': fingerprint!.height,
          'sharpness': double.parse(fingerprint!.sharpness.toStringAsFixed(1)),
        },
        'cameraDetails': hasCameraDetails,
        'secondhand': secondhand,
        'copyName': copyName,
      };
}

/// One photo in a group and how it relates to the copy being kept.
final class DuplicateMember {
  const DuplicateMember(this.facts, this.rule, [this.check]);

  final PhotoFacts facts;

  /// Null for the keeper.
  final DuplicateRule? rule;

  /// Measurements behind [rule] (null for identical copies).
  final PairCheck? check;

  StorageItem get item => facts.item;
  bool get isKeeper => rule == null;

  Map<String, Object?> toJson() => {
        'role': rule?.code ?? 'keep',
        ...facts.toJson(),
        if (check != null) 'match': check!.toJson(),
      };
}

/// A set of duplicate photos with one suggested to keep.
final class DuplicateGroup {
  DuplicateGroup(this.members, this.keepReason)
      : assert(members.where((m) => m.isKeeper).length == 1);

  /// Keeper first, then the rest by path.
  final List<DuplicateMember> members;

  /// Why this copy was chosen to keep.
  final String keepReason;

  DuplicateMember get keeper => members.first;
  Iterable<DuplicateMember> get duplicates => members.skip(1);

  Confidence get confidence =>
      duplicates.every((m) => m.rule!.confidence == Confidence.certain)
          ? Confidence.certain
          : Confidence.likely;

  int get reclaimableBytes =>
      duplicates.fold(0, (s, m) => s + m.item.sizeBytes);

  String get reason {
    final counts = <DuplicateRule, int>{};
    for (final m in duplicates) {
      counts[m.rule!] = (counts[m.rule!] ?? 0) + 1;
    }
    final parts = [
      for (final r in DuplicateRule.values)
        if (counts[r] != null) '${counts[r]} ${_plural(r.label, counts[r]!)}'
    ];
    final what = counts.keys.every((r) => r == DuplicateRule.d06SimilarShot)
        ? '${members.length} near-identical shots'
        : '${members.length} copies of the same photo';
    return '$what (${parts.join(', ')}); keeping '
        '${p.basename(keeper.item.displayName)} ($keepReason)';
  }

  Finding toFinding() => Finding(
        category: WasteCategory.duplicatePhoto,
        items: [for (final m in members) m.item],
        keep: keeper.item,
        reason: reason,
      );

  Map<String, Object?> toJson() => {
        'confidence': confidence.name,
        'reason': reason,
        'keepReason': keepReason,
        'reclaimableBytes': reclaimableBytes,
        'members': [for (final m in members) m.toJson()],
      };
}

String _plural(String label, int n) {
  if (n == 1) return label;
  return label.contains('copy')
      ? label.replaceFirst('copy', 'copies')
      : label.replaceFirst('shot', 'shots');
}

/// A photo the scan looked at but left out, or a near-miss worth knowing
/// about when tuning.
final class PhotoObservation {
  const PhotoObservation(this.kind, this.ids, this.detail);

  final PhotoObservationKind kind;
  final List<String> ids;
  final String detail;

  Map<String, Object?> toJson() =>
      {'kind': kind.name, 'ids': ids, 'detail': detail};
}

enum PhotoObservationKind {
  /// X01: a flat-colour photo; left to the blank-photo scan.
  blank,

  /// X02: smaller than a photo (icon, sticker).
  tooSmall,

  /// X03: the format can be decoded but this file can't (damaged): left to
  /// the unreadable-file scan.
  undecodable,

  /// X04: format this device can't decode (RAW, HEIC on desktop): only
  /// byte-identical copies are found.
  identicalOnly,

  /// The file couldn't be read.
  unreadable,

  /// Two photos that came close to matching but didn't.
  nearMiss,

  /// Two photos that passed D06 on layout but whose fine detail differs
  /// (a different receipt on the same table): not grouped.
  detailDiffers,

  /// Photos linked through a chain of matches but not all alike, so the
  /// chain was split into separate groups.
  split,

  /// A member dropped from its group (below the confidence threshold or a
  /// disabled rule).
  dropped,
}
