// DAT-18: one-tap "Munch my Data" scan.
// Scans a folder, hands the files to DAT-16's classifier, and returns a
// summary ready for the UI to display.

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'classifier.dart';
import 'models.dart';

// Hashing a multi-gigabyte video for a demo scan would be slow, so skip it,
// same cutoff the Python version used.
const _maxHashBytes = 25 * 1024 * 1024;

String _hashFile(File file) {
  final bytes = file.readAsBytesSync();
  return sha256.convert(bytes).toString();
}

/// Every file under [rootPath]. Hidden folders (names starting with a dot,
/// such as the Garbage Bin's own `.DataMuncherBin`) are left out. A folder
/// that can't be opened, like Android's `Android/data`, is passed to
/// [onSkip] and skipped rather than ending the scan.
List<FileRecord> scanFolder(String rootPath, {void Function(String folder)? onSkip}) {
  final files = <FileRecord>[];
  final pending = [Directory(rootPath)];
  if (!pending.first.existsSync()) return files;

  while (pending.isNotEmpty) {
    final dir = pending.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      onSkip?.call(dir.path);
      continue;
    }
    for (final entity in entries) {
      if (p.basename(entity.path).startsWith('.')) continue;
      if (entity is Directory) {
        pending.add(entity);
        continue;
      }
      if (entity is! File) continue;

      int size = 0;
      bool readable = true;
      String? hash;
      try {
        size = entity.lengthSync();
        if (size > 0 && size <= _maxHashBytes) {
          hash = _hashFile(entity);
        }
      } catch (_) {
        readable = false;
      }
      files.add(FileRecord(path: entity.path, sizeBytes: size, isReadable: readable, contentHash: hash));
    }
  }

  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

class MunchResult {
  final List<ClassificationResult> items;
  final ClassifierSummary summary;
  final int totalScanned;
  final int totalBytesScanned;

  /// Folders that couldn't be opened and were left out.
  final List<String> skippedFolders;

  /// Every file that was scanned, for checks that run afterwards (blurry
  /// photos need the phone's image decoder).
  final List<FileRecord> files;

  MunchResult({
    required this.items,
    required this.summary,
    required this.totalScanned,
    required this.totalBytesScanned,
    this.skippedFolders = const [],
    this.files = const [],
  });

  /// The same scan with [items] in place of what was found, e.g. after
  /// blurry photos were added or files were moved to the Garbage Bin.
  MunchResult withItems(List<ClassificationResult> items) => MunchResult(
        items: items,
        summary: summarize(items),
        totalScanned: totalScanned,
        totalBytesScanned: totalBytesScanned,
        skippedFolders: skippedFolders,
        files: files,
      );

  String get humanSummary {
    final freedMb = summary.totalBytesReclaimable / (1024 * 1024);
    return 'Scanned $totalScanned file(s), found ${summary.totalFlagged} wasteful — '
        'up to ${freedMb.toStringAsFixed(2)} MB could be freed.';
  }
}

MunchResult munchMyData(String rootPath) {
  final skipped = <String>[];
  final files = scanFolder(rootPath, onSkip: skipped.add);
  final results = classifyFiles(files);
  final summary = summarize(results);
  final totalBytes = files.fold<int>(0, (sum, f) => sum + f.sizeBytes);

  return MunchResult(
    items: results,
    summary: summary,
    totalScanned: files.length,
    totalBytesScanned: totalBytes,
    skippedFolders: skipped,
    files: files,
  );
}

/// [munchMyData] on a background isolate, so hashing a big folder doesn't
/// freeze the app.
Future<MunchResult> munchMyDataInBackground(String rootPath) => Isolate.run(() => munchMyData(rootPath));
