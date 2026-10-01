import '../model/waste_category.dart';

enum ScanPhase { checkingPermissions, listing, detecting, finishing }

/// Progress updates for a running scan, e.g. to drive a progress bar.
final class ScanProgress {
  const ScanProgress(this.phase,
      {this.category, this.done = 0, this.total = 0});

  final ScanPhase phase;

  /// The category being checked during [ScanPhase.detecting].
  final WasteCategory? category;

  /// Items handled so far and the total. During [ScanPhase.listing] only
  /// [done] is known.
  final int done;
  final int total;

  @override
  String toString() =>
      'ScanProgress(${phase.name}${category == null ? '' : ' ${category!.name}'} $done/$total)';
}

/// Lets the caller stop a scan in progress. The scan then throws
/// [ScanCancelledException].
final class ScanCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

final class ScanCancelledException implements Exception {
  const ScanCancelledException();

  @override
  String toString() => 'ScanCancelledException: the scan was cancelled';
}
