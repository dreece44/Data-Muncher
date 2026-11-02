// DAT-18: one-tap "Munch my Data" scan.
// Scans a folder, hands the files to DAT-16's classifier, and returns a
// summary ready for the UI to display.

import 'dart:io';
import 'package:crypto/crypto.dart';
import 'models.dart';
import 'classifier.dart';

// Hashing a multi-gigabyte video for a demo scan would be slow, so skip it,
// same cutoff the Python version used.
const _maxHashBytes = 25 * 1024 * 1024;

String _hashFile(File file) {
  final bytes = file.readAsBytesSync();
  return sha256.convert(bytes).toString();
}

List<FileRecord> scanFolder(String rootPath) {
  final files = <FileRecord>[];
  final dir = Directory(rootPath);
  if (!dir.existsSync()) return files;

  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
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

  return files;
}

class MunchResult {
  final List<ClassificationResult> items;
  final ClassifierSummary summary;
  final int totalScanned;
  final int totalBytesScanned;

  MunchResult({
    required this.items,
    required this.summary,
    required this.totalScanned,
    required this.totalBytesScanned,
  });

  String get humanSummary {
    final freedMb = summary.totalBytesReclaimable / (1024 * 1024);
    return 'Scanned $totalScanned file(s), found ${summary.totalFlagged} wasteful — '
        'up to ${freedMb.toStringAsFixed(2)} MB could be freed.';
  }
}

MunchResult munchMyData(String rootPath) {
  final files = scanFolder(rootPath);
  final results = classifyFiles(files);
  final summary = summarize(results);
  final totalBytes = files.fold<int>(0, (sum, f) => sum + f.sizeBytes);

  return MunchResult(
    items: results,
    summary: summary,
    totalScanned: files.length,
    totalBytesScanned: totalBytes,
  );
}
