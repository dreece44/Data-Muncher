/// Broad kind of file, used for the list icon and the category filter.
enum FileCategory {
  photo('Photos', 'Photo'),
  video('Videos', 'Video'),
  document('Documents', 'Document'),
  audio('Audio', 'Audio'),
  app('Apps', 'App'),
  other('Other', 'Other file');

  const FileCategory(this.pluralLabel, this.singularLabel);

  final String pluralLabel;
  final String singularLabel;
}

/// Why a scan flagged the file before the user sent it to the bin.
enum CollectionReason {
  duplicate('Duplicate'),
  blurry('Blurry photo'),
  blank('Black screen'),
  emptyFile('Empty file'),
  unreadable('Unreadable file'),
  screenshot('Screenshot'),
  unusedApp('Unused app'),
  oldFile('Old file'),
  manual('Picked by you'),
  other('Flagged by scan');

  const CollectionReason(this.label);

  final String label;
}

/// One file currently held in the Garbage Bin.
///
/// This is the record the bin storage subsystem (PB-12 / DAT-17) hands to the
/// viewer. Everything here comes from the bin's own index: the viewer never
/// opens or decompresses the stored file to show it.
class BinEntry {
  const BinEntry({
    required this.id,
    required this.fileName,
    required this.originalPath,
    required this.category,
    required this.reason,
    required this.originalSizeBytes,
    required this.storedSizeBytes,
    required this.collectedAt,
    this.expiresAt,
  })  : assert(originalSizeBytes >= 0),
        assert(storedSizeBytes >= 0);

  /// Stable id assigned by the bin store.
  final String id;

  /// File name as the user knew it, e.g. `IMG_2041.jpg`.
  final String fileName;

  /// Full path the file was collected from. File Recovery restores it here.
  final String originalPath;

  final FileCategory category;
  final CollectionReason reason;

  /// Size of the file before it went into the bin.
  final int originalSizeBytes;

  /// Space the file takes up inside the bin, after compression if any.
  final int storedSizeBytes;

  /// When the file was sent to the bin.
  final DateTime collectedAt;

  /// When the file's recovery window in the bin ends and it is removed
  /// (handing off to Deletion Backups). Null when no limit applies.
  final DateTime? expiresAt;

  /// Whether the bin is holding a smaller, compressed copy.
  bool get isCompressed => storedSizeBytes < originalSizeBytes;

  /// Space compression saves for this file; never negative.
  int get bytesSavedByCompression =>
      isCompressed ? originalSizeBytes - storedSizeBytes : 0;

  /// The folder part of [originalPath], keeping its original separators.
  String get originalFolder {
    final normalized = originalPath.replaceAll('\\', '/');
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash < 0) return '';
    if (lastSlash == 0) return originalPath.substring(0, 1);
    return originalPath.substring(0, lastSlash);
  }

  @override
  bool operator ==(Object other) =>
      other is BinEntry &&
      other.id == id &&
      other.fileName == fileName &&
      other.originalPath == originalPath &&
      other.category == category &&
      other.reason == reason &&
      other.originalSizeBytes == originalSizeBytes &&
      other.storedSizeBytes == storedSizeBytes &&
      other.collectedAt == collectedAt &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(
        id,
        fileName,
        originalPath,
        category,
        reason,
        originalSizeBytes,
        storedSizeBytes,
        collectedAt,
        expiresAt,
      );

  @override
  String toString() => 'BinEntry($id, $fileName)';
}
