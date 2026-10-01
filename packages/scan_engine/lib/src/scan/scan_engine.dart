import '../detectors/blank_photo_detector.dart';
import '../detectors/duplicate_photo_detector.dart';
import '../detectors/empty_file_detector.dart';
import '../detectors/unreadable_file_detector.dart';
import '../detectors/unused_app_detector.dart';
import '../detectors/waste_detector.dart';
import '../model/finding.dart';
import '../model/scan_report.dart';
import '../model/storage_item.dart';
import '../model/waste_category.dart';
import '../permissions/permissions.dart';
import '../platform/device_adapter.dart';
import 'scan_context.dart';
import 'scan_progress.dart';
import 'scan_rules.dart';

/// The DataMuncher scanning engine: checks permissions, lists device
/// storage, runs each waste detector, and returns a [ScanReport].
///
/// ```dart
/// final engine = ScanEngine(device: adapter);
/// final report = await engine.scan(onProgress: print);
/// ```
final class ScanEngine {
  ScanEngine({
    required this.device,
    this.rules = const ScanRules(),
    List<WasteDetector>? detectors,
    DateTime Function()? clock,
  })  : detectors = detectors ?? defaultDetectors(),
        _clock = clock ?? DateTime.now;

  final DeviceAdapter device;
  final ScanRules rules;
  final List<WasteDetector> detectors;
  final DateTime Function() _clock;

  static List<WasteDetector> defaultDetectors() => const [
        EmptyFileDetector(),
        UnreadableFileDetector(),
        DuplicatePhotoDetector(),
        BlankPhotoDetector(),
        UnusedAppDetector(),
      ];

  /// State of every permission a scan uses: storage access (required) and
  /// any extras detectors want. For the permission grant flow (DAT-15).
  Future<Map<ScanPermission, PermissionState>> checkPermissions() async => {
        for (final p in {
          ...device.storagePermissions,
          for (final d in detectors) ...d.extraPermissions,
        })
          p: await device.permissions.check(p),
      };

  /// Runs a full scan.
  ///
  /// Throws [PermissionDeniedException] without reading any storage if the
  /// device's storage permissions haven't been granted. Throws
  /// [ScanCancelledException] if [cancelToken] is cancelled.
  Future<ScanReport> scan({
    void Function(ScanProgress)? onProgress,
    ScanCancelToken? cancelToken,
  }) async {
    final startedAt = _clock();
    final notes = [...device.limitations];

    // 1. Permission gate. Nothing past this point runs unless the user has
    //    granted storage access.
    onProgress?.call(const ScanProgress(ScanPhase.checkingPermissions));
    if (device.storagePermissions.isEmpty) {
      throw StateError('${device.runtimeType} declares no storage permission; '
          'refusing to scan storage without one.');
    }
    final missing = <ScanPermission, PermissionState>{};
    for (final permission in device.storagePermissions) {
      final state = await device.permissions.check(permission);
      if (!state.allowsAccess) missing[permission] = state;
      if (state == PermissionState.limited) {
        notes.add('${permission.label} is limited: only the items you '
            'selected were scanned.');
      }
    }
    if (missing.isNotEmpty) throw PermissionDeniedException(missing);

    // 2. List everything once; detectors share the list.
    final issues = <ScanIssue>[];
    final items = <StorageItem>[];
    var bytesScanned = 0;
    await for (final item in device.storage.listItems(onIssue: issues.add)) {
      items.add(item);
      bytesScanned += item.sizeBytes;
      if (items.length % 250 == 0) {
        _throwIfCancelled(cancelToken);
        onProgress?.call(ScanProgress(ScanPhase.listing, done: items.length));
      }
    }

    // 3. Run each detector. One failing or unavailable doesn't stop the rest.
    final context = ScanContext(
      device: device,
      items: items,
      rules: rules,
      now: startedAt,
      issues: issues,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    final findings = <Finding>[];
    final categories = <WasteCategory, CategoryResult>{};
    for (final detector in detectors) {
      _throwIfCancelled(cancelToken);
      categories[detector.category] = await _run(detector, context, findings);
    }

    onProgress?.call(const ScanProgress(ScanPhase.finishing));
    return ScanReport(
      platform: device.platform,
      startedAt: startedAt,
      finishedAt: _clock(),
      storage: await _storageStats(issues),
      itemsScanned: items.length,
      bytesScanned: bytesScanned,
      findings: findings,
      categories: categories,
      issues: issues,
      notes: notes,
    );
  }

  Future<CategoryResult> _run(WasteDetector detector, ScanContext context,
      List<Finding> findings) async {
    final unsupported = detector.unsupportedReason(device);
    if (unsupported != null) {
      return CategoryResult(CategoryState.unsupported, unsupported);
    }
    for (final permission in detector.extraPermissions) {
      final state = await device.permissions.check(permission);
      if (!state.allowsAccess) {
        return CategoryResult(CategoryState.skipped,
            '${permission.label} has not been granted (${state.name})');
      }
    }
    try {
      findings.addAll(await detector.detect(context));
      return const CategoryResult(CategoryState.completed);
    } on ScanCancelledException {
      rethrow;
    } catch (e) {
      return CategoryResult(CategoryState.failed, e.toString());
    }
  }

  Future<StorageStats?> _storageStats(List<ScanIssue> issues) async {
    try {
      return await device.storageStats();
    } catch (e) {
      issues.add(ScanIssue('Could not read device storage totals: $e'));
      return null;
    }
  }

  static void _throwIfCancelled(ScanCancelToken? token) {
    if (token?.isCancelled ?? false) throw const ScanCancelledException();
  }
}
