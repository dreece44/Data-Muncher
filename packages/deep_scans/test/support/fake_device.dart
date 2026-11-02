import 'dart:typed_data';

import 'package:deep_scans/deep_scans.dart';
import 'package:scan_engine/scan_engine.dart';

/// A phone made of in-memory files, with permissions the test controls.
class FakeDevice implements DeviceAdapter {
  FakeDevice(Map<String, List<int>> files,
      {Map<ScanPermission, PermissionState>? permissions,
      StorageSource Function(MemoryStorageSource)? wrap})
      : memory = MemoryStorageSource(files),
        permissions = StaticPermissionService(
            permissions ?? {ScanPermission.storage: PermissionState.granted}) {
    storage = wrap == null ? memory : wrap(memory);
  }

  final MemoryStorageSource memory;

  @override
  late final StorageSource storage;
  @override
  final StaticPermissionService permissions;
  @override
  DevicePlatform get platform => DevicePlatform.android;
  @override
  AppInventory? get apps => null;
  @override
  Set<ScanPermission> get storagePermissions => const {ScanPermission.storage};
  @override
  Future<StorageStats?> storageStats() async => null;
  @override
  List<String> get limitations => const [];
}

/// Runs the deep scan on in-memory [files] and returns rule code by path
/// (null = not flagged).
Future<Map<String, String?>> codes(Map<String, List<int>> files,
    {EmptyUnreadableRules rules = const EmptyUnreadableRules(),
    Set<String> unreadable = const {}}) async {
  final result = await deepScan(files, rules: rules, unreadable: unreadable);
  return {
    for (final path in files.keys) path: result.verdictFor(path)?.rule.code
  };
}

Future<DeepScanResult> deepScan(Map<String, List<int>> files,
    {EmptyUnreadableRules rules = const EmptyUnreadableRules(),
    Set<String> unreadable = const {},
    DateTime Function()? clock}) {
  final device = FakeDevice(files);
  device.memory.unreadable.addAll(unreadable);
  return EmptyUnreadableScan(device: device, rules: rules, clock: clock).run();
}

/// Reports every file as [extra] bytes longer than it is, like a cloud
/// placeholder whose data isn't on the device.
final class InflatedSizeSource implements StorageSource {
  InflatedSizeSource(this.inner, this.extra);
  final StorageSource inner;
  final int extra;

  @override
  Stream<StorageItem> listItems({void Function(ScanIssue)? onIssue}) =>
      inner.listItems(onIssue: onIssue).map((i) => StorageItem(
          id: i.id,
          path: i.path,
          displayName: i.displayName,
          sizeBytes: i.sizeBytes + extra,
          modified: i.modified));

  @override
  bool canReadContent(StorageItem item) => inner.canReadContent(item);
  @override
  bool canDecodeThumbnail(StorageItem item) => inner.canDecodeThumbnail(item);
  @override
  Future<Uint8List> readRange(StorageItem item, int start, int end) =>
      inner.readRange(item, start, end);
  @override
  Stream<List<int>> openRead(StorageItem item) => inner.openRead(item);
  @override
  Future<Thumbnail?> loadThumbnail(StorageItem item, int size) =>
      inner.loadThumbnail(item, size);
}

List<int> ascii(String s) => s.codeUnits;

List<int> box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return [
    size >> 24 & 0xFF, size >> 16 & 0xFF, size >> 8 & 0xFF, size & 0xFF, //
    ...type.codeUnits, ...payload,
  ];
}

final ftyp = box('ftyp', 'isom\x00\x00\x02\x00isommp41'.codeUnits);
