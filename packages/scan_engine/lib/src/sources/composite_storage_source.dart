import 'dart:typed_data';

import '../imaging/thumbnail.dart';
import '../model/scan_report.dart';
import '../model/storage_item.dart';
import '../platform/storage_source.dart';

/// Several sources presented as one, e.g. on iOS the Photos library plus
/// folders the user picked in the Files app. Reads go to whichever source
/// listed the item.
final class CompositeStorageSource implements StorageSource {
  CompositeStorageSource(this.sources);

  final List<StorageSource> sources;
  final _owners = <String, StorageSource>{};

  StorageSource _owner(StorageItem item) =>
      _owners[item.id] ??
      (throw StateError('${item.id} was not listed by this source'));

  @override
  Stream<StorageItem> listItems({void Function(ScanIssue)? onIssue}) async* {
    for (final source in sources) {
      await for (final item in source.listItems(onIssue: onIssue)) {
        _owners[item.id] = source;
        yield item;
      }
    }
  }

  @override
  bool canReadContent(StorageItem item) =>
      _owners[item.id]?.canReadContent(item) ?? false;

  @override
  bool canDecodeThumbnail(StorageItem item) =>
      _owners[item.id]?.canDecodeThumbnail(item) ?? false;

  @override
  Future<Uint8List> readRange(StorageItem item, int start, int end) =>
      _owner(item).readRange(item, start, end);

  @override
  Stream<List<int>> openRead(StorageItem item) => _owner(item).openRead(item);

  @override
  Future<Thumbnail?> loadThumbnail(StorageItem item, int size) =>
      _owner(item).loadThumbnail(item, size);
}
