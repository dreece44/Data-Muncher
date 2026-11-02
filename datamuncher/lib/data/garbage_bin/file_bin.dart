import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bin_entry.dart';

/// Name of the hidden folder that holds collected files. It sits at the root
/// of the storage volume the file came from, so moving a file in or out is a
/// rename rather than a copy. The scan engine skips hidden folders, so files
/// in the bin are never flagged again.
const String fileBinFolderName = '.DataMuncherBin';

/// Prefix of every file-bin id, keeping them apart from photo library ids.
const String fileBinIdPrefix = 'file:';

/// One storage file held in the Garbage Bin.
class FileBinRecord {
  const FileBinRecord({
    required this.id,
    required this.originalPath,
    required this.storedPath,
    required this.sizeBytes,
    required this.reason,
    required this.collectedAt,
  });

  final String id;

  /// Where the file was collected from. File Recovery puts it back here.
  final String originalPath;

  /// Where the file is now, inside a [fileBinFolderName] folder.
  final String storedPath;

  final int sizeBytes;
  final CollectionReason reason;
  final DateTime collectedAt;

  String get fileName => p.basename(originalPath);

  Map<String, Object?> toJson() => {
        'id': id,
        'originalPath': originalPath,
        'storedPath': storedPath,
        'sizeBytes': sizeBytes,
        'reason': reason.name,
        'collectedAt': collectedAt.millisecondsSinceEpoch,
      };

  /// Returns null for a malformed record.
  static FileBinRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], original = json['originalPath'], stored = json['storedPath'];
    final size = json['sizeBytes'], ms = json['collectedAt'];
    if (id is! String || original is! String || stored is! String || size is! int || ms is! int) {
      return null;
    }
    return FileBinRecord(
      id: id,
      originalPath: original,
      storedPath: stored,
      sizeBytes: size,
      reason: CollectionReason.values.firstWhere(
        (r) => r.name == json['reason'],
        orElse: () => CollectionReason.other,
      ),
      collectedAt: DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }
}

/// The storage-file half of the Garbage Bin.
///
/// Photo library items stay in place and the bin only lists their ids. Files
/// found by the storage scan are different: they're moved into a hidden bin
/// folder, so they disappear from the phone's file browser and gallery until
/// recovered or deleted.
class FileBin {
  FileBin({required this.binFolderFor, Iterable<FileBinRecord> records = const []}) {
    for (final r in records) {
      _records[r.id] = r;
    }
  }

  /// The bin folder for a file at the given path. Should be on the same
  /// storage volume so the move is a rename.
  final String Function(String originalPath) binFolderFor;

  final Map<String, FileBinRecord> _records = {};
  int _counter = 0;

  Iterable<FileBinRecord> get records => _records.values;
  int get length => _records.length;
  bool get isEmpty => _records.isEmpty;
  bool contains(String id) => _records.containsKey(id);
  FileBinRecord? operator [](String id) => _records[id];

  /// Moves the file at [path] into the bin. Throws [FileSystemException] if
  /// it can't be moved; the file is then left where it was.
  Future<FileBinRecord> collect(String path, CollectionReason reason, {DateTime? now}) async {
    final when = now ?? DateTime.now();
    final source = File(path);
    final size = await source.length();
    final folder = Directory(binFolderFor(path));
    if (!await folder.exists()) {
      await folder.create(recursive: true);
      // Keeps the media scanner from listing binned photos in the gallery.
      await File(p.join(folder.path, '.nomedia')).create();
    }
    final key = '${when.microsecondsSinceEpoch}-${_counter++}';
    final stored = p.join(folder.path, '${key}_${p.basename(path)}');
    await _move(source, stored);
    final record = FileBinRecord(
      id: '$fileBinIdPrefix$key',
      originalPath: path,
      storedPath: stored,
      sizeBytes: size,
      reason: reason,
      collectedAt: when,
    );
    _records[record.id] = record;
    return record;
  }

  /// Moves a file back to where it was collected from and returns the path
  /// it now has. If another file has taken that name since, the recovered
  /// file gets a free name like `photo (1).jpg` instead of overwriting it.
  Future<String> restore(String id) async {
    final record = _records[id];
    if (record == null) throw StateError('$id is not in the file bin');
    final target = await _freePath(record.originalPath);
    await Directory(p.dirname(target)).create(recursive: true);
    await _move(File(record.storedPath), target);
    _records.remove(id);
    return target;
  }

  /// Deletes the file for good. Storage files have no system trash to go to.
  Future<void> delete(String id) async {
    final record = _records[id];
    if (record == null) return;
    final file = File(record.storedPath);
    if (await file.exists()) await file.delete();
    _records.remove(id);
  }

  /// Whether the file is still in the bin folder (it may have been removed
  /// with a file manager).
  Future<bool> isStored(String id) async {
    final record = _records[id];
    return record != null && await File(record.storedPath).exists();
  }

  /// Forgets an entry without touching any file.
  void forget(String id) => _records.remove(id);

  List<String> encode() => [for (final r in _records.values) jsonEncode(r.toJson())];

  static List<FileBinRecord> decode(Iterable<String> lines) => [
        for (final line in lines)
          if (_tryDecode(line) case final record?) record,
      ];

  static FileBinRecord? _tryDecode(String line) {
    try {
      return FileBinRecord.fromJson(jsonDecode(line));
    } on FormatException {
      return null;
    }
  }

  /// Rename when possible; copy and delete when the bin folder is on another
  /// volume.
  static Future<void> _move(File source, String target) async {
    try {
      await source.rename(target);
    } on FileSystemException {
      await source.copy(target);
      await source.delete();
    }
  }

  static Future<String> _freePath(String path) async {
    if (!await File(path).exists()) return path;
    final folder = p.dirname(path);
    final stem = p.basenameWithoutExtension(path);
    final ext = p.extension(path);
    for (var n = 1;; n++) {
      final candidate = p.join(folder, '$stem ($n)$ext');
      if (!await File(candidate).exists()) return candidate;
    }
  }
}

/// The bin folder for [path]: at the root of whichever of [roots] holds it,
/// or the first root if none does.
String binFolderUnder(List<String> roots, String path) {
  for (final root in roots) {
    if (p.isWithin(root, path)) return p.join(root, fileBinFolderName);
  }
  return p.join(roots.isEmpty ? p.dirname(path) : roots.first, fileBinFolderName);
}

/// File type for the bin's icon and category filter, from the extension.
FileCategory fileCategoryFor(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'jpg' || 'jpeg' || 'png' || 'heic' || 'heif' || 'webp' || 'gif' || 'bmp' || 'dng' => FileCategory.photo,
    'mp4' || 'm4v' || 'mov' || '3gp' || 'mkv' || 'webm' || 'avi' => FileCategory.video,
    'mp3' || 'm4a' || 'wav' || 'ogg' || 'opus' || 'flac' || 'aac' => FileCategory.audio,
    'pdf' || 'doc' || 'docx' || 'xls' || 'xlsx' || 'ppt' || 'pptx' || 'odt' || 'rtf' || 'txt' || 'csv' || 'epub' =>
      FileCategory.document,
    'apk' => FileCategory.app,
    _ => FileCategory.other,
  };
}
