// DAT-16: detects which files are considered wasteful.
// Same rules as the Python version: empty files, unreadable files,
// and exact duplicates (matched by content hash).

import 'models.dart';

List<ClassificationResult> classifyFiles(List<FileRecord> files) {
  final results = <ClassificationResult>[];
  final seenHashes = <String, String>{};

  for (final file in files) {
    // Checks for empty files
    if (file.sizeBytes == 0) {
      results.add(ClassificationResult(file, WasteCategory.empty, 'File size is 0 bytes.'));
      continue;
    }

    // Checks for unreadable files
    if (!file.isReadable) {
      results.add(ClassificationResult(file, WasteCategory.unreadable, 'File could not be opened.'));
      continue;
    }

    // Checks for duplicate files
    if (file.contentHash != null) {
      final hash = file.contentHash!;
      if (seenHashes.containsKey(hash)) {
        results.add(ClassificationResult(file, WasteCategory.duplicate, 'Same content as ${seenHashes[hash]}'));
        continue;
      } else {
        seenHashes[hash] = file.path;
      }
    }
  }

  return results;
}

ClassifierSummary summarize(List<ClassificationResult> results) {
  int totalBytes = 0;
  final counts = <WasteCategory, int>{};

  for (final result in results) {
    totalBytes += result.file.sizeBytes;
    counts[result.category] = (counts[result.category] ?? 0) + 1;
  }

  return ClassifierSummary(results.length, totalBytes, counts);
}
