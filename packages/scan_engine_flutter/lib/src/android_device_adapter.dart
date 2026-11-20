import 'package:scan_engine/scan_engine.dart';

import 'flutter_permission_service.dart';
import 'flutter_thumbnail_decoder.dart';
import 'native_bridge.dart';

/// Any Android phone or tablet: Pixel, Samsung Galaxy, Motorola, OnePlus…
///
/// Scans all shared storage (internal and SD cards) once the user grants
/// "All files access", and finds unused apps once they grant "Usage access".
final class AndroidDeviceAdapter implements DeviceAdapter {
  AndroidDeviceAdapter._(this._native, List<String> roots, int sdkInt)
    : permissions = FlutterPermissionService(_native) {
    storage = PermissionGuardedStorageSource(
      LocalDirectorySource(
        roots,
        // Other apps' private folders. Android 11+ blocks reading them even
        // with All files access.
        excludedPaths: [
          for (final root in roots) ...[
            '$root/Android/data',
            '$root/Android/obb',
          ],
        ],
        thumbnailDecoder: FlutterThumbnailDecoder(heicSupported: sdkInt >= 28),
      ),
      permissions,
      storagePermissions,
    );
    apps = _NativeAppInventory(_native);
  }

  /// Finding the storage volumes doesn't read them, so this is safe to call
  /// before permission is granted.
  static Future<AndroidDeviceAdapter> create({
    NativeBridge native = const NativeBridge(),
  }) async {
    return AndroidDeviceAdapter._(
      native,
      await native.androidStorageRoots(),
      await native.androidSdkInt(),
    );
  }

  final NativeBridge _native;

  @override
  final PermissionService permissions;

  @override
  late final StorageSource storage;

  @override
  late final AppInventory apps;

  @override
  DevicePlatform get platform => DevicePlatform.android;

  @override
  Set<ScanPermission> get storagePermissions => const {ScanPermission.storage};

  @override
  Future<StorageStats?> storageStats() => _native.storageStats();

  @override
  List<String> get limitations => const [
    "Other apps' private folders (Android/data and Android/obb) can't "
        'be read on Android 11 and later, so they were skipped.',
  ];
}

final class _NativeAppInventory implements AppInventory {
  _NativeAppInventory(this._native);
  final NativeBridge _native;

  @override
  Future<List<InstalledApp>> listApps() => _native.installedApps();
}
