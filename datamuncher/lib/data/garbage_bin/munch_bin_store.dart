import 'dart:async';

import 'package:photo_manager/photo_manager.dart';

import '../../core.dart';
import 'bin_entry.dart';
import 'file_bin.dart';
import 'garbage_bin_store.dart';

/// [GarbageBinStore] backed by the app's [MunchState].
///
/// Photo library items stay where they are (the bin is a list of ids);
/// storage files from the storage scan are moved into a hidden bin folder
/// (see [FileBin]), gzipped there when that saves space (DAT-17). There is
/// no retention limit, so files stay until recovered or the bin is emptied.
class MunchBinStore implements GarbageBinStore {
  MunchBinStore(this.state) : _lastRevision = state.binRevision {
    state.addListener(_onStateChanged);
  }

  final MunchState state;
  int _lastRevision;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final Map<String, AssetEntity> _assets = {};
  final Map<String, int> _sizes = {};

  @override
  Stream<void> get changes => _changes.stream;

  /// The library asset behind a bin entry, once it has been loaded.
  AssetEntity? assetFor(String id) => _assets[id];

  /// Where a storage file in the bin is kept, or null for library items.
  String? storedPathFor(String id) => state.fileBin[id]?.storedPath;

  void _onStateChanged() {
    if (state.binRevision == _lastRevision) return;
    _lastRevision = state.binRevision;
    _changes.add(null);
  }

  @override
  Future<List<BinEntry>> listEntries() async {
    final entries = <BinEntry>[];
    final missing = <String>[];
    for (final id in state.bin.toList()) {
      final asset = _assets[id] ?? await AssetEntity.fromId(id);
      if (asset == null) {
        missing.add(id); // deleted outside DataMuncher
        continue;
      }
      _assets[id] = asset;
      final name = await _fileName(asset);
      final size = _sizes[id] ??= await _sizeOf(asset);
      final info = state.binInfo[id];
      entries.add(BinEntry(
        id: id,
        fileName: name,
        originalPath: _pathFor(asset, name),
        category: _categoryOf(asset.type),
        reason: info?.reason ?? CollectionReason.other,
        originalSizeBytes: size,
        storedSizeBytes: size,
        collectedAt: info?.collectedAt ?? DateTime.now(),
      ));
    }
    for (final record in state.fileBin.records.toList()) {
      if (!await state.fileBin.isStored(record.id)) {
        missing.add(record.id); // removed from the bin folder by hand
        continue;
      }
      entries.add(BinEntry(
        id: record.id,
        fileName: record.fileName,
        originalPath: record.originalPath,
        category: fileCategoryFor(record.fileName),
        reason: record.reason,
        originalSizeBytes: record.sizeBytes,
        storedSizeBytes: record.storedSizeBytes,
        collectedAt: record.collectedAt,
      ));
    }
    // Clean them out of the bin. This fires one more change, and the reload
    // it causes finds nothing missing, so it doesn't repeat.
    if (missing.isNotEmpty) unawaited(state.forgetMissing(missing));
    return entries;
  }

  void dispose() {
    state.removeListener(_onStateChanged);
    unawaited(_changes.close());
  }

  static Future<String> _fileName(AssetEntity asset) async {
    try {
      final title = await asset.titleAsync;
      if (title.isNotEmpty) return title;
    } catch (_) {}
    return asset.title?.isNotEmpty == true ? asset.title! : asset.id;
  }

  /// Android gives a relative folder such as `DCIM/Camera/`; iOS doesn't.
  static String _pathFor(AssetEntity asset, String name) {
    var folder = asset.relativePath ?? '';
    if (folder.isEmpty) folder = 'Photo library';
    if (!folder.startsWith('/')) folder = '/$folder';
    if (!folder.endsWith('/')) folder = '$folder/';
    return '$folder$name';
  }

  static Future<int> _sizeOf(AssetEntity asset) async {
    try {
      final file = await asset.file;
      return file == null ? 0 : await file.length();
    } catch (_) {
      return 0;
    }
  }

  static FileCategory _categoryOf(AssetType type) => switch (type) {
        AssetType.image => FileCategory.photo,
        AssetType.video => FileCategory.video,
        AssetType.audio => FileCategory.audio,
        AssetType.other => FileCategory.other,
      };
}
