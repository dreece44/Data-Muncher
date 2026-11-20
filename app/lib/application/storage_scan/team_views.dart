import 'package:scan_engine_flutter/scan_engine_flutter.dart' as engine;

import '../../data/garbage_bin/bin_entry.dart';
import '../../presentation/garbage_bin/format.dart';
import '../../presentation/garbage_collection/garbage_collection.dart' show StorageItem;
import '../../presentation/storage_results/storage_results.dart' show ScanResults;
import 'storage_scan.dart';

/// Label for unused apps in the results page's reclaimable list.
const String unusedAppsLabel = 'Unused apps';

/// The storage results page's data (coilehayden0's Storage_Results) from a
/// storage scan (DAT-1). Wasted space is what the scan suggests moving to the
/// Garbage Bin plus unused apps.
ScanResults scanResultsFrom(
  engine.ScanReport report,
  List<ScanCandidate> candidates,
  List<engine.InstalledApp> apps,
) {
  final byReason = <String, int>{};
  for (final c in candidates) {
    byReason.update(c.reason.label, (sum) => sum + c.item.sizeBytes, ifAbsent: () => c.item.sizeBytes);
  }
  if (apps.isNotEmpty) {
    byReason[unusedAppsLabel] = apps.fold(0, (sum, app) => sum + app.sizeBytes);
  }
  final wasted = byReason.values.fold(0, (a, b) => a + b);

  final storage = report.storage;
  final known = storage != null && storage.totalBytes > 0;
  String size(int bytes) => known ? formatBytes(bytes) : 'Unknown';

  return ScanResults(
    status: 'Complete',
    totalStorage: size(storage?.totalBytes ?? 0),
    usedStorage: size(storage?.usedBytes ?? 0),
    freeStorage: size(storage?.freeBytes ?? 0),
    wastedStorage: formatBytes(wasted),
    usedPercent: known ? (storage.usedBytes / storage.totalBytes).clamp(0.0, 1.0) : 0,
    reclaimable: {for (final e in byReason.entries) e.key: formatBytes(e.value)},
    filesScanned: report.itemsScanned,
    directoriesScanned: report.foldersScanned,
  );
}

/// One row per bin reason for the garbage collection page (coilehayden0's
/// garbage_collection), each mapped to the scan candidates it stands for.
/// Rows start ticked, like the storage scan's list.
Map<StorageItem, List<ScanCandidate>> collectionGroupsFrom(List<ScanCandidate> candidates) {
  final groups = <CollectionReason, List<ScanCandidate>>{};
  for (final c in candidates) {
    groups.putIfAbsent(c.reason, () => []).add(c);
  }
  return {
    for (final MapEntry(key: reason, value: items) in groups.entries)
      StorageItem(
        name: '${reason.label} (${items.length})',
        size: formatBytes(items.fold(0, (sum, c) => sum + c.item.sizeBytes)),
        selected: true,
      ): items,
  };
}
