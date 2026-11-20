import '../model/scan_report.dart';
import '../permissions/guarded_storage_source.dart';
import '../permissions/permissions.dart';
import '../platform/app_inventory.dart';
import '../platform/device_adapter.dart';
import '../platform/storage_source.dart';
import 'local_directory_source.dart';

/// Simulates a phone on a development computer: a folder stands in for the
/// phone's storage, and permissions come from a [PermissionService] you
/// control (normally [StaticPermissionService]).
///
/// [simulate] picks which phone's rules to follow. Android needs storage
/// access and can list apps; iOS needs photo access and can't list apps.
final class LocalDeviceAdapter implements DeviceAdapter {
  LocalDeviceAdapter({
    required String root,
    required this.permissions,
    this.simulate = DevicePlatform.android,
    AppInventory? apps,
  })  : assert(simulate != DevicePlatform.desktop),
        _apps = apps {
    storage = PermissionGuardedStorageSource(
        LocalDirectorySource([root]), permissions, storagePermissions);
  }

  final DevicePlatform simulate;
  final AppInventory? _apps;

  @override
  final PermissionService permissions;

  @override
  late final StorageSource storage;

  @override
  DevicePlatform get platform => simulate;

  @override
  Set<ScanPermission> get storagePermissions => simulate == DevicePlatform.ios
      ? const {ScanPermission.photos}
      : const {ScanPermission.storage};

  @override
  AppInventory? get apps => simulate == DevicePlatform.ios ? null : _apps;

  /// A computer folder has no phone storage totals to report.
  @override
  Future<StorageStats?> storageStats() async => null;

  @override
  List<String> get limitations => [
        'Simulated ${simulate.name} device: a local folder stands in for '
            'phone storage.',
      ];
}
