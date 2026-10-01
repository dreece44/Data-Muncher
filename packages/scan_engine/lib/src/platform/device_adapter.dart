import '../model/scan_report.dart';
import '../permissions/permissions.dart';
import 'app_inventory.dart';
import 'storage_source.dart';

enum DevicePlatform { android, ios, desktop }

/// Everything the engine needs from one kind of device. The Android and iOS
/// adapters live in `scan_engine_flutter`. `LocalDeviceAdapter` simulates a
/// phone on a development computer.
abstract interface class DeviceAdapter {
  DevicePlatform get platform;

  PermissionService get permissions;

  /// Permissions that must all be granted before the engine reads any
  /// storage. Must not be empty: the engine refuses to scan a device that
  /// declares no storage permission.
  Set<ScanPermission> get storagePermissions;

  StorageSource get storage;

  /// Installed apps, or null where the OS doesn't let apps see each other
  /// (iOS). Categories that need this are then reported as unsupported.
  AppInventory? get apps;

  /// Device totals, or null if the platform can't report them.
  Future<StorageStats?> storageStats();

  /// Caveats about what a scan on this device can see, copied into every
  /// report (e.g. "on iPhone only the Photos library and folders you pick
  /// are scanned").
  List<String> get limitations;
}
