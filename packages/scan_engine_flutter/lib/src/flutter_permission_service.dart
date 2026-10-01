import 'dart:io';

import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:scan_engine/scan_engine.dart';

import 'native_bridge.dart';

/// Real OS permissions, via `permission_handler` plus this plugin's native
/// code for Android usage access (which `permission_handler` doesn't cover).
final class FlutterPermissionService implements PermissionService {
  FlutterPermissionService([this._native = const NativeBridge()]);

  final NativeBridge _native;

  @override
  Future<PermissionState> check(ScanPermission permission) async {
    switch (permission) {
      case ScanPermission.storage:
        final p = await _storagePermission();
        return p == null ? PermissionState.restricted : _map(await p.status);
      case ScanPermission.photos:
        return Platform.isIOS
            ? _map(await ph.Permission.photos.status)
            : PermissionState.restricted;
      case ScanPermission.appUsage:
        if (!Platform.isAndroid) return PermissionState.restricted;
        return await _native.hasUsageAccess()
            ? PermissionState.granted
            : PermissionState.denied;
    }
  }

  @override
  Future<PermissionState> request(ScanPermission permission) async {
    switch (permission) {
      case ScanPermission.storage:
        // On Android 11+ this opens the "All files access" Settings screen.
        final p = await _storagePermission();
        return p == null ? PermissionState.restricted : _map(await p.request());
      case ScanPermission.photos:
        return Platform.isIOS
            ? _map(await ph.Permission.photos.request())
            : PermissionState.restricted;
      case ScanPermission.appUsage:
        if (!Platform.isAndroid) return PermissionState.restricted;
        // Usage access can only be granted on a Settings screen, and Android
        // doesn't report back. Callers should check() again when the app
        // returns to the foreground.
        await _native.openUsageAccessSettings();
        return check(permission);
    }
  }

  /// "All files access" (MANAGE_EXTERNAL_STORAGE) on Android 11+, the older
  /// READ_EXTERNAL_STORAGE permission before that. Null off Android.
  Future<ph.Permission?> _storagePermission() async {
    if (!Platform.isAndroid) return null;
    return await _native.androidSdkInt() >= 30
        ? ph.Permission.manageExternalStorage
        : ph.Permission.storage;
  }

  static PermissionState _map(ph.PermissionStatus status) {
    if (status.isGranted) return PermissionState.granted;
    if (status.isLimited) return PermissionState.limited;
    if (status.isPermanentlyDenied) return PermissionState.permanentlyDenied;
    if (status.isRestricted) return PermissionState.restricted;
    return PermissionState.denied;
  }
}
