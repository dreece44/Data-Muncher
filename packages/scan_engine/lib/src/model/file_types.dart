/// Broad content type of a stored item, derived from its extension.
enum MediaKind { image, video, audio, document, archive, text, other }

const _kindsByExtension = <String, MediaKind>{
  // Images
  'jpg': MediaKind.image, 'jpeg': MediaKind.image, 'png': MediaKind.image,
  'heic': MediaKind.image, 'heif': MediaKind.image, 'webp': MediaKind.image,
  'gif': MediaKind.image, 'bmp': MediaKind.image, 'tif': MediaKind.image,
  'tiff': MediaKind.image, 'dng': MediaKind.image, 'avif': MediaKind.image,
  // Video
  'mp4': MediaKind.video, 'm4v': MediaKind.video, 'mov': MediaKind.video,
  '3gp': MediaKind.video, 'mkv': MediaKind.video, 'webm': MediaKind.video,
  'avi': MediaKind.video,
  // Audio
  'mp3': MediaKind.audio, 'm4a': MediaKind.audio, 'wav': MediaKind.audio,
  'ogg': MediaKind.audio, 'opus': MediaKind.audio, 'flac': MediaKind.audio,
  'aac': MediaKind.audio,
  // Documents
  'pdf': MediaKind.document, 'doc': MediaKind.document,
  'docx': MediaKind.document, 'xls': MediaKind.document,
  'xlsx': MediaKind.document, 'ppt': MediaKind.document,
  'pptx': MediaKind.document, 'odt': MediaKind.document,
  'ods': MediaKind.document, 'odp': MediaKind.document,
  'rtf': MediaKind.document, 'epub': MediaKind.document,
  // Archives
  'zip': MediaKind.archive, 'apk': MediaKind.archive, 'jar': MediaKind.archive,
  '7z': MediaKind.archive, 'rar': MediaKind.archive, 'gz': MediaKind.archive,
  // Text
  'txt': MediaKind.text, 'csv': MediaKind.text, 'json': MediaKind.text,
  'xml': MediaKind.text, 'html': MediaKind.text, 'htm': MediaKind.text,
  'md': MediaKind.text, 'log': MediaKind.text, 'srt': MediaKind.text,
  'vcf': MediaKind.text, 'ics': MediaKind.text, 'svg': MediaKind.text,
};

/// Image formats that can be photos worth analysing for duplicates/blankness.
/// GIFs (usually animations/memes) and RAW formats are left out on purpose.
const photoExtensions = {'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'bmp'};

/// Lower-case extension of [name] without the dot, or '' if there is none.
String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

MediaKind mediaKindFor(String name) =>
    _kindsByExtension[extensionOf(name)] ?? MediaKind.other;
