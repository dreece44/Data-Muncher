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

/// List of the records kept in each bin folder, next to the files. The app's
/// own copy of the list is lost when its data is cleared or it is
/// reinstalled; this one lets it find the files again (see [FileBin.adopt]).
const String fileBinIndexName = '.datamuncher-index.json';

/// Added to the name of a file the bin keeps gzip-compressed (DAT-17).
const String compressedSuffix = '.dmgz';

/// Folder that files found in a bin folder with no record of where they came
/// from are recovered to, under the volume's root.
const String unknownOriginFolder = 'Download';

/// One storage file held in the Garbage Bin.
class FileBinRecord {
  const FileBinRecord({
    required this.id,
    required this.originalPath,
    required this.storedPath,
    required this.sizeBytes,
    required this.reason,
    required this.collectedAt,
    int? storedSizeBytes,
    this.compressed = false,
  }) : storedSizeBytes = storedSizeBytes ?? sizeBytes;

  final String id;

  /// Where the file was collected from. File Recovery puts it back here.
  final String originalPath;

  /// Where the file is now, inside a [fileBinFolderName] folder.
  final String storedPath;

  /// Size of the file as the user had it.
  final int sizeBytes;

  /// Space it takes up in the bin; smaller than [sizeBytes] when compressed.
  final int storedSizeBytes;

  /// Whether [storedPath] holds a gzip-compressed copy (DAT-17).
  final bool compressed;

  final CollectionReason reason;
  final DateTime collectedAt;

  String get fileName => p.basename(originalPath);

  /// Space compression saves; never negative.
  int get bytesSaved => compressed && storedSizeBytes < sizeBytes ? sizeBytes - storedSizeBytes : 0;

  FileBinRecord _stored(String path, int size, {required bool compressed}) => FileBinRecord(
        id: id,
        originalPath: originalPath,
        storedPath: path,
        sizeBytes: sizeBytes,
        reason: reason,
        collectedAt: collectedAt,
        storedSizeBytes: size,
        compressed: compressed,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'originalPath': originalPath,
        'storedPath': storedPath,
        'sizeBytes': sizeBytes,
        'storedSizeBytes': storedSizeBytes,
        'compressed': compressed,
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
    final storedSize = json['storedSizeBytes'];
    return FileBinRecord(
      id: id,
      originalPath: original,
      storedPath: stored,
      sizeBytes: size,
      storedSizeBytes: storedSize is int ? storedSize : size,
      compressed: json['compressed'] == true,
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
/// recovered or deleted. Files that compress well are kept gzipped there
/// (DAT-17), so they take less space while they wait.
class FileBin {
  FileBin({
    required this.binFolderFor,
    Iterable<FileBinRecord> records = const [],
    this.compressOnCollect = true,
  }) {
    for (final r in records) {
      _records[r.id] = r;
      _folders.add(p.dirname(r.storedPath));
    }
  }

  /// The bin folder for a file at the given path. Should be on the same
  /// storage volume so the move is a rename.
  final String Function(String originalPath) binFolderFor;

  /// Compress files that are likely to shrink as they come in.
  final bool compressOnCollect;

  final Map<String, FileBinRecord> _records = {};

  /// Bin folders this bin has used, whose index files it keeps up to date.
  final Set<String> _folders = {};

  /// The records changed since the index files were last written.
  bool _dirty = false;
  int _counter = 0;

  Iterable<FileBinRecord> get records => _records.values;
  int get length => _records.length;
  bool get isEmpty => _records.isEmpty;
  bool contains(String id) => _records.containsKey(id);
  FileBinRecord? operator [](String id) => _records[id];

  /// Space the bin's files take up on the phone.
  int get storedBytes => _records.values.fold(0, (sum, r) => sum + r.storedSizeBytes);

  /// Space compression is saving.
  int get bytesSaved => _records.values.fold(0, (sum, r) => sum + r.bytesSaved);

  /// Moves the file at [path] into the bin, compressing it if that's likely
  /// to help. Throws [FileSystemException] if it can't be moved; the file is
  /// then left where it was.
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
    var record = FileBinRecord(
      id: '$fileBinIdPrefix$key',
      originalPath: path,
      storedPath: stored,
      sizeBytes: size,
      reason: reason,
      collectedAt: when,
    );
    _records[record.id] = record;
    _folders.add(folder.path);
    _dirty = true;
    if (compressOnCollect && worthCompressing(path)) {
      record = await compress(record.id) ?? record;
    }
    return record;
  }

  /// Gzips a file in the bin (DAT-17). Keeps the compressed copy only when
  /// it is smaller; returns the updated record, or null when compressing
  /// didn't help or the file is already compressed. The original stays
  /// untouched if anything goes wrong.
  Future<FileBinRecord?> compress(String id) async {
    final record = _records[id];
    if (record == null || record.compressed) return null;
    final source = File(record.storedPath);
    final target = File('${record.storedPath}$compressedSuffix');
    try {
      await source.openRead().transform(gzip.encoder).pipe(target.openWrite());
      final packed = await target.length();
      if (packed >= await source.length()) {
        await target.delete();
        return null;
      }
      await source.delete();
      final updated = record._stored(target.path, packed, compressed: true);
      _records[id] = updated;
      _dirty = true;
      return updated;
    } on Exception {
      // Out of space, file vanished, etc.: keep the uncompressed copy.
      if (await target.exists()) await target.delete();
      return null;
    }
  }

  /// Moves a file back to where it was collected from and returns the path
  /// it now has. If another file has taken that name since, the recovered
  /// file gets a free name like `photo (1).jpg` instead of overwriting it.
  /// Compressed files are unpacked on the way out.
  Future<String> restore(String id) async {
    final record = _records[id];
    if (record == null) throw StateError('$id is not in the file bin');
    final target = await _freePath(record.originalPath);
    await Directory(p.dirname(target)).create(recursive: true);
    if (record.compressed) {
      final partial = File('$target.part');
      try {
        await File(record.storedPath).openRead().transform(gzip.decoder).pipe(partial.openWrite());
        await partial.rename(target);
      } catch (_) {
        if (await partial.exists()) await partial.delete();
        rethrow;
      }
      await File(record.storedPath).delete();
    } else {
      await _move(File(record.storedPath), target);
    }
    _records.remove(id);
    _dirty = true;
    return target;
  }

  /// Deletes the file for good. Storage files have no system trash to go to.
  Future<void> delete(String id) async {
    final record = _records[id];
    if (record == null) return;
    final file = File(record.storedPath);
    if (await file.exists()) await file.delete();
    _records.remove(id);
    _dirty = true;
  }

  /// Whether the file is still in the bin folder (it may have been removed
  /// with a file manager).
  Future<bool> isStored(String id) async {
    final record = _records[id];
    return record != null && await File(record.storedPath).exists();
  }

  /// Forgets an entry without touching any file.
  void forget(String id) {
    if (_records.remove(id) != null) _dirty = true;
  }

  List<String> encode() => [for (final r in _records.values) jsonEncode(r.toJson())];

  static List<FileBinRecord> decode(Iterable<String> lines) => [
        for (final line in lines)
          ?_tryDecode(line),
      ];

  static FileBinRecord? _tryDecode(String line) {
    try {
      return FileBinRecord.fromJson(jsonDecode(line));
    } on FormatException {
      return null;
    }
  }

  /// Writes each bin folder's [fileBinIndexName] after the records changed.
  /// A folder that can't be written to is skipped; the app's own list still
  /// has the records.
  Future<void> saveIndexes() async {
    if (!_dirty) return;
    _dirty = false;
    for (final folder in _folders) {
      final here = [
        for (final r in _records.values)
          if (p.equals(p.dirname(r.storedPath), folder)) r.toJson(),
      ];
      try {
        if (!await Directory(folder).exists()) continue;
        await File(p.join(folder, fileBinIndexName)).writeAsString(jsonEncode(here));
      } on FileSystemException {
        // Read-only or no longer mounted.
      }
    }
  }

  /// Takes in files in [folder] that this bin has no record of, after the
  /// app's data was cleared or it was reinstalled. Records come from the
  /// folder's index; a file with none (binned by an older version) is
  /// recovered to [recoverTo] under its own name. Returns how many files
  /// were added.
  Future<int> adopt(String folder, {required String recoverTo}) async {
    final dir = Directory(folder);
    if (!await dir.exists()) return 0;
    _folders.add(folder);
    final known = {for (final r in _records.values) p.normalize(r.storedPath)};
    var adopted = 0;

    void add(FileBinRecord r) {
      _records[r.id] = r;
      known.add(p.normalize(r.storedPath));
      adopted++;
    }

    final index = File(p.join(folder, fileBinIndexName));
    if (await index.exists()) {
      Object? list;
      try {
        list = jsonDecode(await index.readAsString());
      } on FormatException {
        list = null;
      }
      if (list is List) {
        for (final json in list) {
          var r = FileBinRecord.fromJson(json);
          if (r == null || _records.containsKey(r.id)) continue;
          // The volume may be mounted under a different path now.
          final here = p.join(folder, p.basename(r.storedPath));
          if (!await File(r.storedPath).exists()) {
            if (!await File(here).exists()) continue;
            r = r._stored(here, r.storedSizeBytes, compressed: r.compressed);
          }
          if (known.contains(p.normalize(r.storedPath))) continue;
          add(r);
        }
      }
    }

    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.') || name.endsWith('.part')) continue;
      if (known.contains(p.normalize(entity.path))) continue;
      final r = await _recordForUnlisted(entity, recoverTo);
      if (_records.containsKey(r.id)) continue;
      add(r);
    }
    if (adopted > 0) _dirty = true;
    return adopted;
  }

  /// A record for a file found in a bin folder with no index entry. Its
  /// stored name `<micros>-<n>_<name>` gives the original name and when it
  /// was binned; where it came from is unknown.
  static Future<FileBinRecord> _recordForUnlisted(File file, String recoverTo) async {
    var name = p.basename(file.path);
    final compressed = name.endsWith(compressedSuffix);
    if (compressed) name = name.substring(0, name.length - compressedSuffix.length);
    final match = RegExp(r'^(\d+)-(\d+)_(.+)$').firstMatch(name);
    final stat = await file.stat();
    final key = match == null ? 'found-${stat.modified.microsecondsSinceEpoch}-$name' : '${match[1]}-${match[2]}';
    final micros = match == null ? null : int.tryParse(match[1]!);
    return FileBinRecord(
      id: '$fileBinIdPrefix$key',
      originalPath: p.join(recoverTo, match?[3] ?? name),
      storedPath: file.path,
      // The original size of a compressed file isn't known without
      // unpacking it; the stored size is the best guess.
      sizeBytes: stat.size,
      storedSizeBytes: stat.size,
      compressed: compressed,
      reason: CollectionReason.other,
      collectedAt: micros == null ? stat.modified : DateTime.fromMicrosecondsSinceEpoch(micros),
    );
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

/// Whether gzip is likely to shrink a file, judged by its extension. Photos,
/// videos, music and archives are already compressed, so trying would only
/// cost time (the Garbage Storage page can still try one by hand).
bool worthCompressing(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  if (fileCategoryFor(name) case FileCategory.photo || FileCategory.video || FileCategory.audio || FileCategory.app) {
    return false;
  }
  const packed = {
    'zip', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'jar', 'aab', 'obb', //
    'docx', 'xlsx', 'pptx', 'odt', 'ods', 'odp', 'epub', 'dmgz', //
  };
  return !packed.contains(ext);
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
