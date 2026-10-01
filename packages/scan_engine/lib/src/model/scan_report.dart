import '../platform/device_adapter.dart';
import 'finding.dart';
import 'waste_category.dart';

/// Total and free space on the device's main storage volume.
final class StorageStats {
  const StorageStats({required this.totalBytes, required this.freeBytes});

  final int totalBytes;
  final int freeBytes;
  int get usedBytes => totalBytes - freeBytes;

  Map<String, Object?> toJson() => {
        'totalBytes': totalBytes,
        'freeBytes': freeBytes,
        'usedBytes': usedBytes
      };
}

/// A non-fatal problem hit during a scan, e.g. a folder that couldn't be
/// opened. The scan carries on past these.
final class ScanIssue {
  const ScanIssue(this.message, {this.location});

  final String message;

  /// Path or item id the issue relates to, if any.
  final String? location;

  Map<String, Object?> toJson() =>
      {'message': message, if (location != null) 'location': location};

  @override
  String toString() => location == null ? message : '$message: $location';
}

enum CategoryState {
  /// The detector ran to completion (it may have found nothing).
  completed,

  /// The device's operating system doesn't allow this check at all.
  unsupported,

  /// The check needs a permission the user hasn't granted.
  skipped,

  /// The detector crashed. Other categories still ran.
  failed,
}

/// What happened to one [WasteCategory] during a scan.
final class CategoryResult {
  const CategoryResult(this.state, [this.note]);

  final CategoryState state;

  /// Why the category was unsupported, skipped or failed.
  final String? note;

  Map<String, Object?> toJson() =>
      {'state': state.name, if (note != null) 'note': note};
}

/// Everything a finished scan found. This is what the Scan and Review UI,
/// the post-scan summary (DAT-5) and notifications consume.
final class ScanReport {
  ScanReport({
    required this.platform,
    required this.startedAt,
    required this.finishedAt,
    required this.storage,
    required this.itemsScanned,
    required this.bytesScanned,
    required this.findings,
    required this.categories,
    required this.issues,
    required this.notes,
  });

  final DevicePlatform platform;
  final DateTime startedAt;
  final DateTime finishedAt;

  /// Device totals, or null if the platform couldn't report them.
  final StorageStats? storage;
  final int itemsScanned;
  final int bytesScanned;
  final List<Finding> findings;
  final Map<WasteCategory, CategoryResult> categories;
  final List<ScanIssue> issues;

  /// Caveats about what this scan could see, e.g. limited photo access.
  final List<String> notes;

  Duration get duration => finishedAt.difference(startedAt);

  List<Finding> findingsFor(WasteCategory category) => [
        for (final f in findings)
          if (f.category == category) f
      ];

  /// Space freed by removing every suggested item. Items flagged by more
  /// than one finding are only counted once.
  int get reclaimableBytes => _distinctBytes(findings);

  int reclaimableBytesFor(WasteCategory category) =>
      _distinctBytes(findingsFor(category));

  static int _distinctBytes(Iterable<Finding> findings) {
    final sizes = <String, int>{
      for (final f in findings)
        for (final item in f.removable) item.id: item.sizeBytes,
    };
    return sizes.values.fold(0, (a, b) => a + b);
  }

  Map<String, Object?> toJson() => {
        'platform': platform.name,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt.toIso8601String(),
        'storage': storage?.toJson(),
        'itemsScanned': itemsScanned,
        'bytesScanned': bytesScanned,
        'reclaimableBytes': reclaimableBytes,
        'categories': {
          for (final e in categories.entries)
            e.key.name: {
              ...e.value.toJson(),
              'findings': findingsFor(e.key).length,
              'reclaimableBytes': reclaimableBytesFor(e.key),
            },
        },
        'findings': [for (final f in findings) f.toJson()],
        'issues': [for (final i in issues) i.toJson()],
        'notes': notes,
      };
}
