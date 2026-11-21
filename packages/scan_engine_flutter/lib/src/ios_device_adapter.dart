import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart';

import 'flutter_permission_service.dart';
import 'flutter_thumbnail_decoder.dart';
import 'native_bridge.dart';

/// iPhone and iPad.
///
/// iOS only lets apps see the Photos library (with the user's permission)
/// and folders the user picks in the Files app. It never lets an app list
/// other apps or their usage, so unused-app detection is reported as
/// unsupported here.
final class IosDeviceAdapter implements DeviceAdapter {
  /// [pickedFolders] are paths the user chose with a document picker. The
  /// caller must keep their security-scoped access open during the scan.
  IosDeviceAdapter({
    List<String> pickedFolders = const [],
    NativeBridge native = const NativeBridge(),
  }) : _native = native,
       permissions = FlutterPermissionService(native) {
    storage = PermissionGuardedStorageSource(
      CompositeStorageSource([
        IosPhotoLibrarySource(native),
        if (pickedFolders.isNotEmpty)
          LocalDirectorySource(
            pickedFolders,
            thumbnailDecoder: const FlutterThumbnailDecoder(),
          ),
      ]),
      permissions,
      storagePermissions,
    );
  }

  final NativeBridge _native;

  @override
  final PermissionService permissions;

  @override
  late final StorageSource storage;

  @override
  DevicePlatform get platform => DevicePlatform.ios;

  @override
  Set<ScanPermission> get storagePermissions => const {ScanPermission.photos};

  @override
  AppInventory? get apps => null;

  @override
  Future<StorageStats?> storageStats() => _native.storageStats();

  @override
  List<String> get limitations => const [
    'On iPhone, DataMuncher can scan your Photos library and folders you '
        "choose in the Files app. iOS doesn't let apps look through the "
        "rest of the phone's storage.",
  ];
}

/// Images in the iOS Photos library. Assets have no file path; the engine
/// only sees their metadata and a small thumbnail rendered by iOS, which
/// also means iCloud-only photos aren't downloaded during a scan.
final class IosPhotoLibrarySource implements StorageSource {
  IosPhotoLibrarySource([this._native = const NativeBridge()]);

  final NativeBridge _native;
  final _dimensions = <String, (int, int)>{};

  @override
  Stream<StorageItem> listItems({void Function(ScanIssue)? onIssue}) async* {
    for (final asset in await _native.iosPhotoAssets()) {
      final id = asset['id']! as String;
      _dimensions[id] = (
        (asset['width']! as num).toInt(),
        (asset['height']! as num).toInt(),
      );
      final ms = (asset['modifiedAt'] ?? asset['createdAt']) as int?;
      yield StorageItem(
        id: id,
        displayName: asset['filename']! as String,
        sizeBytes: (asset['sizeBytes']! as num).toInt(),
        modified: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
        origin: ItemOrigin.photoLibrary,
        kind: MediaKind.image,
      );
    }
  }

  @override
  bool canReadContent(StorageItem item) => false;

  @override
  bool canDecodeThumbnail(StorageItem item) => _dimensions.containsKey(item.id);

  @override
  Future<Uint8List> readRange(StorageItem item, int start, int end) =>
      throw UnsupportedError('Photos assets are only read as thumbnails');

  @override
  Stream<List<int>> openRead(StorageItem item) =>
      throw UnsupportedError('Photos assets are only read as thumbnails');

  @override
  Future<Thumbnail?> loadThumbnail(StorageItem item, int size) async {
    final luma = await _native.iosPhotoThumbnail(item.id, size);
    if (luma == null || luma.length != size * size) return null;
    final (width, height) = _dimensions[item.id]!;
    return Thumbnail(
      size: size,
      luma: luma,
      sourceWidth: width,
      sourceHeight: height,
    );
  }
}
