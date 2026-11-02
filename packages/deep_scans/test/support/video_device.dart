import 'dart:math' as math;
import 'dart:typed_data';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart' show videoTestAreaScale;
import 'package:scan_engine/scan_engine.dart';

/// One in-memory file for the video tests: its bytes and its own
/// last-modified date (MemoryStorageSource gives every file the same one).
final class VideoFile {
  const VideoFile(this.bytes, this.modified, {this.photoLibrary = false});

  final List<int> bytes;
  final DateTime modified;

  /// An iOS photo-library asset: listed, but its bytes can't be read.
  final bool photoLibrary;
}

final class VideoStorage implements StorageSource {
  VideoStorage(Map<String, VideoFile> files)
      : _files = {
          for (final e in files.entries)
            e.key: (Uint8List.fromList(e.value.bytes), e.value),
        };

  final Map<String, (Uint8List, VideoFile)> _files;

  /// Paths whose reads fail.
  final Set<String> unreadable = {};

  /// Number of times anything was listed or read.
  int accessCount = 0;

  @override
  Stream<StorageItem> listItems({void Function(ScanIssue)? onIssue}) async* {
    accessCount++;
    for (final e in _files.entries) {
      final (bytes, file) = e.value;
      yield StorageItem(
        id: e.key,
        path: file.photoLibrary ? null : e.key,
        displayName: e.key.split('/').last,
        sizeBytes: bytes.length,
        modified: file.modified,
        origin:
            file.photoLibrary ? ItemOrigin.photoLibrary : ItemOrigin.fileSystem,
      );
    }
  }

  @override
  bool canReadContent(StorageItem item) => !_files[item.id]!.$2.photoLibrary;

  @override
  bool canDecodeThumbnail(StorageItem item) => false;

  @override
  Future<Uint8List> readRange(StorageItem item, int start, int end) async {
    accessCount++;
    if (unreadable.contains(item.id)) {
      throw StorageReadException(item.id, 'Permission denied');
    }
    final bytes = _files[item.id]!.$1;
    final from = start.clamp(0, bytes.length);
    return Uint8List.sublistView(
        bytes, from, math.max(from, math.min(end, bytes.length)));
  }

  @override
  Stream<List<int>> openRead(StorageItem item) async* {
    yield await readRange(item, 0, item.sizeBytes);
  }

  @override
  Future<Thumbnail?> loadThumbnail(StorageItem item, int size) async => null;
}

final class VideoDevice implements DeviceAdapter {
  VideoDevice(Map<String, VideoFile> files, {bool granted = true})
      : storage = VideoStorage(files),
        permissions = StaticPermissionService({
          ScanPermission.storage:
              granted ? PermissionState.granted : PermissionState.denied,
        });

  @override
  final VideoStorage storage;
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

/// "Now" for every video test.
final testNow = DateTime(2026, 11, 1, 12);

/// The default rules at test-area scale (1 KB stands for 1 MB), with every
/// video opened one at a time so results don't depend on scheduling.
final scaledRules =
    const LargeOldVideoRules(concurrency: 1).scaledDown(videoTestAreaScale);

/// On-disk bytes standing for real [gigabytes].
int gb(double gigabytes) => (gigabytes * 1024 * 1024).round();

/// On-disk bytes standing for real [megabytes].
int mb(double megabytes) => (megabytes * 1024).round();

DateTime daysAgo(int days) => testNow.subtract(Duration(days: days));

Future<LargeOldVideoResult> scanVideos(Map<String, VideoFile> files,
        {LargeOldVideoRules? rules,
        EmptyUnreadableRules healthRules = const EmptyUnreadableRules(),
        Set<String> unreadable = const {},
        DateTime? now}) =>
    LargeOldVideoScan(
      device: VideoDevice(files)..storage.unreadable.addAll(unreadable),
      rules: rules ?? scaledRules,
      healthRules: healthRules,
      clock: () => now ?? testNow,
    ).run();

extension VideoResultLookup on LargeOldVideoResult {
  /// The rule code for [path] (V or E/U), or null if not flagged.
  String? codeFor(String path) =>
      verdicts.where((v) => v.item.id == path).firstOrNull?.rule.code ??
      analysis.health
          .where((h) => h.item.id == path)
          .firstOrNull
          ?.verdict
          .rule
          .code;

  VideoVerdict verdictFor(String path) =>
      verdicts.singleWhere((v) => v.item.id == path);

  Set<String> notesFor(String path) => {
        for (final o in analysis.observations)
          if (o.id == path) o.kind.name
      };
}
