import 'dart:math' as math;
import 'dart:typed_data';

import '../imaging/pure_dart_thumbnail_decoder.dart';
import '../imaging/thumbnail.dart';
import '../model/scan_report.dart';
import '../model/storage_item.dart';
import '../platform/storage_source.dart';

/// Files held in memory, keyed by path. For tests: build a fake phone in a
/// few lines and check exactly what the engine reads.
final class MemoryStorageSource implements StorageSource {
  MemoryStorageSource(Map<String, List<int>> files, {DateTime? modified})
      : _files = {
          for (final e in files.entries) e.key: Uint8List.fromList(e.value),
        },
        _modified = modified ?? DateTime(2026, 1, 1);

  final Map<String, Uint8List> _files;
  final DateTime _modified;
  final _decoder = const PureDartThumbnailDecoder(useIsolates: false);

  /// Paths whose reads fail, to simulate unreadable files.
  final Set<String> unreadable = {};

  /// Number of times anything was listed or read. Lets tests prove storage
  /// wasn't touched.
  int accessCount = 0;

  @override
  Stream<StorageItem> listItems({void Function(ScanIssue)? onIssue}) async* {
    accessCount++;
    for (final e in _files.entries) {
      yield StorageItem(
        id: e.key,
        path: e.key,
        displayName: e.key.split('/').last,
        sizeBytes: e.value.length,
        modified: _modified,
      );
    }
  }

  Uint8List _read(StorageItem item) {
    accessCount++;
    if (unreadable.contains(item.id)) {
      throw StorageReadException(item.id, 'Permission denied');
    }
    return _files[item.id]!;
  }

  @override
  bool canReadContent(StorageItem item) => true;

  @override
  bool canDecodeThumbnail(StorageItem item) =>
      _decoder.supportsExtension(item.extension);

  @override
  Future<Uint8List> readRange(StorageItem item, int start, int end) async {
    final bytes = _read(item);
    final from = start.clamp(0, bytes.length);
    return Uint8List.sublistView(
        bytes, from, math.max(from, math.min(end, bytes.length)));
  }

  @override
  Stream<List<int>> openRead(StorageItem item) => Stream.value(_read(item));

  @override
  Future<Thumbnail?> loadThumbnail(StorageItem item, int size) =>
      _decoder.decode(_read(item), size);
}
