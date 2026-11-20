import 'package:scan_engine/scan_engine.dart';

import 'rules.dart';

/// Why a file was flagged: which rule, how sure, a plain-language reason for
/// the user and technical evidence for whoever is tuning the rules.
final class FileVerdict {
  const FileVerdict({
    required this.item,
    required this.rule,
    required this.confidence,
    required this.reason,
    this.evidence,
  });

  final StorageItem item;
  final DeepRule rule;
  final Confidence confidence;

  /// Shown to the user (becomes [Finding.reason]).
  final String reason;

  /// What the check actually saw, e.g. `IDAT chunk CRC 0x1a2b3c4d != stored
  /// 0x00000000`. Not shown to users.
  final String? evidence;

  WasteCategory get category => rule.category;

  Finding toFinding() =>
      Finding(category: category, items: [item], reason: reason);

  Map<String, Object?> toJson() => {
        'rule': rule.code,
        'category': category.name,
        'confidence': confidence.name,
        'reason': reason,
        if (evidence != null) 'evidence': evidence,
        'item': item.toJson(),
      };

  @override
  String toString() => '${rule.code} ${confidence.name} ${item.id}: $reason';
}

/// A file the scan looked at closely but didn't flag, recorded so tuning can
/// see near-misses (misnamed files, files skipped as still being written).
final class FileObservation {
  const FileObservation(this.item, this.kind, this.detail);

  final StorageItem item;
  final ObservationKind kind;
  final String detail;

  Map<String, Object?> toJson() =>
      {'kind': kind.name, 'detail': detail, 'id': item.id};

  @override
  String toString() => '${kind.name} ${item.id}: $detail';
}

enum ObservationKind {
  /// Modified within the grace period; not judged this scan.
  recentlyModified,

  /// Contents are a different, valid format than the name says. Most apps
  /// open these fine, so they're checked as their real format instead.
  misnamed,

  /// Too large for the deep checks; only cheap checks ran.
  deepChecksSkipped,

  /// A rule matched but was dropped (disabled, or below the confidence
  /// threshold).
  suppressed,
}
