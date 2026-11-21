// DAT-16: detects which files are considered wasteful.
// Same rules as the Python version: empty files, unreadable files,
// and exact duplicates (matched by content hash). Photos are also checked
// for black frames and blur with the photo scan's thresholds (rules.dart).

import 'dart:math';
import 'dart:typed_data';

import 'models.dart';
import 'rules.dart' show RuleConfig, defaultRuleConfig;

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

/// Photo formats the phone can decode for [classifyPhoto].
const Set<String> photoExtensions = {'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'bmp', 'gif'};

bool isPhoto(String path) {
  final dot = path.lastIndexOf('.');
  return dot >= 0 && photoExtensions.contains(path.substring(dot + 1).toLowerCase());
}

/// A black photo counts as empty, a soft one as blurry. [luma] is a
/// [size]×[size] greyscale thumbnail (0–255). Returns null for a good photo.
ClassificationResult? classifyPhoto(FileRecord file, Uint8List luma, int size,
    {RuleConfig config = defaultRuleConfig}) {
  final n = luma.length;
  final mean = luma.fold<int>(0, (t, v) => t + v) / n;
  final variance = luma.fold<double>(0, (t, v) => t + (v - mean) * (v - mean)) / n;
  if (mean <= config.blackMeanMax && sqrt(variance) <= config.blackStdMax) {
    return ClassificationResult(file, WasteCategory.empty, 'Black screen.');
  }

  // Variance of the Laplacian, as in the photo scan's blur rule.
  final lap = <double>[];
  for (var y = 1; y < size - 1; y++) {
    for (var x = 1; x < size - 1; x++) {
      lap.add((luma[(y - 1) * size + x] +
              luma[(y + 1) * size + x] +
              luma[y * size + x - 1] +
              luma[y * size + x + 1] -
              4 * luma[y * size + x])
          .toDouble());
    }
  }
  if (lap.isEmpty) return null;
  final lm = lap.reduce((a, b) => a + b) / lap.length;
  final sharpness = lap.fold<double>(0, (t, v) => t + (v - lm) * (v - lm)) / lap.length;
  if (sharpness < config.blurThreshold) {
    return ClassificationResult(file, WasteCategory.blurry,
        'Sharpness ${sharpness.toStringAsFixed(1)} is below ${config.blurThreshold.toStringAsFixed(0)}.');
  }
  return null;
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
