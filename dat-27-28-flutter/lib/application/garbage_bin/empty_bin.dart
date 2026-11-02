import '../../data/garbage_bin/bin_entry.dart';

/// What happened when the user emptied the Garbage Bin (PB-14 / DAT-28).
class EmptyBinOutcome {
  const EmptyBinOutcome({required this.removedIds, this.restorableFor});

  /// Nothing left the bin (the user cancelled the phone's delete prompt).
  static const EmptyBinOutcome nothingRemoved =
      EmptyBinOutcome(removedIds: <String>{});

  /// Files that left the bin.
  final Set<String> removedIds;

  /// How long the files can still be restored from the phone's own trash
  /// (Deletion Backups, PB-17). Null when they were deleted permanently.
  final Duration? restorableFor;
}

/// The outcome measured against what the bin held when the user confirmed.
class EmptyBinReport {
  const EmptyBinReport({
    required this.requestedCount,
    required this.removedCount,
    required this.removedBytes,
    this.restorableFor,
  });

  /// [before] is what the viewer showed when the user confirmed. Removed ids
  /// it never showed (files already deleted outside the app) are ignored.
  factory EmptyBinReport.of(List<BinEntry> before, EmptyBinOutcome outcome) {
    var count = 0;
    var bytes = 0;
    for (final entry in before) {
      if (outcome.removedIds.contains(entry.id)) {
        count++;
        bytes += entry.originalSizeBytes;
      }
    }
    return EmptyBinReport(
      requestedCount: before.length,
      removedCount: count,
      removedBytes: bytes,
      restorableFor: outcome.restorableFor,
    );
  }

  final int requestedCount;
  final int removedCount;

  /// Combined size of the files that left the bin.
  final int removedBytes;

  final Duration? restorableFor;

  /// Files still in the bin afterwards.
  int get keptCount => requestedCount - removedCount;
}
