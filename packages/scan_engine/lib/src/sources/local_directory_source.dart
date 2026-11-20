import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../imaging/pure_dart_thumbnail_decoder.dart';
import '../imaging/thumbnail.dart';
import '../model/scan_report.dart';
import '../model/storage_item.dart';
import '../platform/storage_source.dart';

/// Files under one or more folders, read with `dart:io`.
///
/// On Android the roots are the shared storage volumes
/// (`/storage/emulated/0` plus any SD card). On a development computer the
/// root is a folder standing in for a phone's storage.
final class LocalDirectorySource implements StorageSource {
  LocalDirectorySource(
    this.roots, {
    this.excludedPaths = const [],
    this.includeHidden = false,
    this.thumbnailDecoder = const PureDartThumbnailDecoder(),
  });

  final List<String> roots;

  /// Folders to skip entirely, e.g. Android's `Android/data`, which apps
  /// aren't allowed to read.
  final List<String> excludedPaths;

  /// Whether to include files and folders whose names start with a dot.
  /// Off by default: they're app caches (e.g. `.thumbnails`, which would
  /// show up as duplicates of every photo) and marker files like `.nomedia`.
  final bool includeHidden;

  final ThumbnailDecoder thumbnailDecoder;

  @override
  Stream<StorageItem> listItems({void Function(ScanIssue)? onIssue}) async* {
    for (final root in roots) {
      final dir = Directory(root);
      if (!await dir.exists()) {
        onIssue?.call(ScanIssue('Storage location not found', location: root));
        continue;
      }
      yield* _walk(dir, onIssue);
    }
  }

  /// Recurses by hand (rather than `list(recursive: true)`) so one folder
  /// that can't be opened is reported and skipped instead of ending the scan.
  Stream<StorageItem> _walk(
      Directory dir, void Function(ScanIssue)? onIssue) async* {
    final List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } on FileSystemException catch (e) {
      onIssue?.call(ScanIssue('Folder could not be opened (${e.message})',
          location: dir.path));
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));

    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (!includeHidden && name.startsWith('.')) continue;
      if (entry is Directory) {
        if (!_isExcluded(entry.path)) yield* _walk(entry, onIssue);
      } else if (entry is File) {
        try {
          final stat = await entry.stat();
          yield StorageItem(
            id: entry.path,
            path: entry.path,
            displayName: name,
            sizeBytes: stat.size,
            modified: stat.modified,
          );
        } on FileSystemException catch (e) {
          onIssue?.call(ScanIssue('File could not be inspected (${e.message})',
              location: entry.path));
        }
      }
      // Symbolic links are skipped: following them could count files twice
      // or leave the scanned area.
    }
  }

  bool _isExcluded(String path) => excludedPaths.any(
      (excluded) => p.equals(excluded, path) || p.isWithin(excluded, path));

  @override
  bool canReadContent(StorageItem item) => item.path != null;

  @override
  bool canDecodeThumbnail(StorageItem item) =>
      item.path != null && thumbnailDecoder.supportsExtension(item.extension);

  @override
  Future<Uint8List> readRange(StorageItem item, int start, int end) async {
    RandomAccessFile? file;
    try {
      file = await File(item.path!).open();
      final length = await file.length();
      final from = start.clamp(0, length);
      final to = end.clamp(from, length);
      await file.setPosition(from);
      return await file.read(to - from);
    } on FileSystemException catch (e) {
      throw StorageReadException(item.id, e.message);
    } finally {
      await file?.close();
    }
  }

  @override
  Stream<List<int>> openRead(StorageItem item) => File(item.path!).openRead();

  @override
  Future<Thumbnail?> loadThumbnail(StorageItem item, int size) async {
    final Uint8List bytes;
    try {
      bytes = await File(item.path!).readAsBytes();
    } on FileSystemException catch (e) {
      throw StorageReadException(item.id, e.message);
    }
    return thumbnailDecoder.decode(bytes, size);
  }
}
