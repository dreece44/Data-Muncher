import 'package:flutter/material.dart' show IconData, Icons;
import 'package:scan_engine_flutter/scan_engine_flutter.dart' as engine;

import '../../data/garbage_bin/bin_entry.dart';
import '../../presentation/garbage_bin/format.dart';
import '../../presentation/garbage_collection/garbage_collection.dart' show StorageItem;
import '../../presentation/storage_results/storage_results.dart' show ReviewSuggestion, ScanResults;
import 'storage_scan.dart';

/// One swipe-review card (coilehayden0's PB-20) per bin reason, each mapped
/// to the scan candidates it stands for, largest first.
Map<ReviewSuggestion, List<ScanCandidate>> reviewSuggestionsFrom(List<ScanCandidate> candidates) {
  final groups = <CollectionReason, List<ScanCandidate>>{};
  for (final c in candidates) {
    groups.putIfAbsent(c.reason, () => []).add(c);
  }
  int bytes(List<ScanCandidate> items) => items.fold(0, (sum, c) => sum + c.item.sizeBytes);
  final sorted = groups.entries.toList()..sort((a, b) => bytes(b.value).compareTo(bytes(a.value)));
  return {
    for (final MapEntry(key: reason, value: items) in sorted)
      ReviewSuggestion(
        id: reason.name,
        title: '${reason.label}s',
        category: _reviewCategory(reason),
        description: _reviewDescription(reason, items),
        storageSize: formatBytes(bytes(items)),
        itemCount: items.length,
        icon: _reviewIcon(reason),
      ): items,
  };
}

String _reviewCategory(CollectionReason reason) => switch (reason) {
      CollectionReason.duplicate || CollectionReason.blurry || CollectionReason.blank => 'Photos',
      _ => 'Files',
    };

String _reviewDescription(CollectionReason reason, List<ScanCandidate> items) {
  final example = items.first.explanation;
  final what = switch (reason) {
    CollectionReason.duplicate => 'Extra copies of photos you already have; the best copy is kept.',
    CollectionReason.blank => 'Black or blank photos, often taken by accident.',
    CollectionReason.blurry => 'Photos that are out of focus.',
    CollectionReason.emptyFile => 'Files with nothing in them.',
    CollectionReason.unreadable => "Damaged or unfinished files that can't be opened.",
    _ => 'Files the scan flagged.',
  };
  return example.isEmpty ? what : '$what\nFor example: $example';
}

IconData _reviewIcon(CollectionReason reason) => switch (reason) {
      CollectionReason.duplicate => Icons.photo_library_outlined,
      CollectionReason.blank => Icons.image_not_supported_outlined,
      CollectionReason.blurry => Icons.blur_on,
      CollectionReason.emptyFile => Icons.insert_drive_file_outlined,
      CollectionReason.unreadable => Icons.broken_image_outlined,
      _ => Icons.delete_outline,
    };

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
