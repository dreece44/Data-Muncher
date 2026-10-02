// Shared data types used by DAT-16 (classifier.dart) and DAT-18 (muncher.dart).

class FileRecord {
  final String path;
  final int sizeBytes;
  final bool isReadable;
  final String? contentHash;

  FileRecord({
    required this.path,
    required this.sizeBytes,
    this.isReadable = true,
    this.contentHash,
  });
}

enum WasteCategory { empty, unreadable, duplicate }

class ClassificationResult {
  final FileRecord file;
  final WasteCategory category;
  final String reason;

  ClassificationResult(this.file, this.category, this.reason);
}

class ClassifierSummary {
  final int totalFlagged;
  final int totalBytesReclaimable;
  final Map<WasteCategory, int> countsByCategory;

  ClassifierSummary(this.totalFlagged, this.totalBytesReclaimable, this.countsByCategory);
}
