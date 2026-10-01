import 'file_types.dart';

/// Something the user could remove to get space back: a file, a photo, or an
/// installed app.
abstract interface class Reclaimable {
  /// Stable identifier: a file path, a photo-library asset id, or an app
  /// package name.
  String get id;
  String get displayName;
  int get sizeBytes;
  Map<String, Object?> toJson();
}

/// Where a [StorageItem] came from, which decides how it can be read.
enum ItemOrigin {
  /// A regular file reached through a file path (Android storage, folders
  /// the user picked on iOS, a folder on a development computer).
  fileSystem,

  /// An asset in the iOS Photos library. It has no file path and its bytes
  /// are only reachable through the platform's photo APIs.
  photoLibrary,
}

/// One file or photo found in device storage.
final class StorageItem implements Reclaimable {
  StorageItem({
    required this.id,
    required this.displayName,
    required this.sizeBytes,
    this.path,
    this.modified,
    this.origin = ItemOrigin.fileSystem,
    MediaKind? kind,
  }) : kind = kind ?? mediaKindFor(displayName);

  @override
  final String id;
  @override
  final String displayName;
  @override
  final int sizeBytes;

  /// Absolute path for [ItemOrigin.fileSystem] items, otherwise null.
  final String? path;
  final DateTime? modified;
  final ItemOrigin origin;
  final MediaKind kind;

  String get extension => extensionOf(displayName);

  /// Whether this looks like a photo the image detectors should analyse.
  bool get isPhoto => photoExtensions.contains(extension);

  @override
  Map<String, Object?> toJson() => {
        'type': 'file',
        'id': id,
        'name': displayName,
        if (path != null) 'path': path,
        'sizeBytes': sizeBytes,
        if (modified != null) 'modified': modified!.toIso8601String(),
        'origin': origin.name,
        'kind': kind.name,
      };

  @override
  String toString() => 'StorageItem($id, $sizeBytes bytes)';
}
