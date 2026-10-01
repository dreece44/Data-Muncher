import 'dart:typed_data';

import '../imaging/thumbnail.dart';
import '../model/scan_report.dart';
import '../model/storage_item.dart';

/// The "File system interface" from the architecture doc: how the engine
/// sees a device's files and photos.
///
/// Implementations: `LocalDirectorySource` (Android storage, and folders on
/// a development computer), the iOS photo-library source in
/// `scan_engine_flutter`, and `MemoryStorageSource` for tests.
abstract interface class StorageSource {
  /// Every item the engine is allowed to see. Problems with individual
  /// folders are reported through [onIssue] and don't stop the listing.
  Stream<StorageItem> listItems({void Function(ScanIssue)? onIssue});

  /// Whether [readRange] / [openRead] work for this item. False for iOS
  /// photo-library assets, whose raw bytes the engine doesn't read.
  bool canReadContent(StorageItem item);

  /// Whether [loadThumbnail] can decode this item's format on this device.
  bool canDecodeThumbnail(StorageItem item);

  /// Bytes [start] (inclusive) to [end] (exclusive), clamped to the file
  /// size. Throws [StorageReadException] if the item can't be opened.
  Future<Uint8List> readRange(StorageItem item, int start, int end);

  /// The item's full contents, for hashing.
  Stream<List<int>> openRead(StorageItem item);

  /// A `size`×`size` greyscale thumbnail, or null if the image data can't be
  /// decoded. Throws [StorageReadException] if the item can't be opened.
  Future<Thumbnail?> loadThumbnail(StorageItem item, int size);
}

final class StorageReadException implements Exception {
  const StorageReadException(this.itemId, this.message);

  final String itemId;
  final String message;

  @override
  String toString() => 'StorageReadException($itemId): $message';
}
