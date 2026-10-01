import 'dart:math' as math;
import 'dart:typed_data';

import '../model/finding.dart';
import '../model/storage_item.dart';
import '../model/waste_category.dart';
import '../platform/storage_source.dart';
import '../scan/scan_context.dart';
import 'waste_detector.dart';

/// Files that can't be used: ones that won't open, unfinished downloads,
/// and files whose contents don't match their type or are cut off.
///
/// Checks are cheap structural ones (file signatures and end markers) plus a
/// decode test for photos. Files of unknown types are only checked for
/// whether they open, since there's nothing to validate them against.
final class UnreadableFileDetector extends WasteDetector {
  const UnreadableFileDetector();

  static const _headerBytes = 4096;

  /// Extensions browsers and download managers give files until the
  /// download finishes. If one is still around, the download failed.
  static const partialDownloadExtensions = {
    'crdownload', 'part', 'partial', 'download', 'opdownload', //
  };

  @override
  WasteCategory get category => WasteCategory.unreadableFile;

  @override
  Future<List<Finding>> detect(ScanContext context) async {
    final files = [
      for (final item in context.items)
        if (item.origin == ItemOrigin.fileSystem &&
            item.sizeBytes > 0 &&
            context.source.canReadContent(item))
          item,
    ];
    // Decode photos in parallel up front; the per-file loop then hits the cache.
    await context.analyzeImages(category, [
      for (final f in files)
        if (f.isPhoto) f
    ]);

    final findings = <Finding>[];
    for (var i = 0; i < files.length; i++) {
      context.tick(category, i + 1, files.length);
      final reason = await _check(context, files[i]);
      if (reason != null) {
        findings.add(
            Finding(category: category, items: [files[i]], reason: reason));
      }
    }
    return findings;
  }

  Future<String?> _check(ScanContext context, StorageItem item) async {
    if (partialDownloadExtensions.contains(item.extension)) {
      return 'Unfinished download: the download never completed';
    }

    final Uint8List header;
    try {
      header = await context.source
          .readRange(item, 0, math.min(item.sizeBytes, _headerBytes));
    } on StorageReadException catch (e) {
      return 'File could not be opened (${e.message})';
    }

    // Tiny blank files are EmptyFileDetector's; don't report them twice.
    if (item.sizeBytes <= context.rules.blankContentMaxBytes &&
        isBlankContent(header)) {
      return null;
    }

    final format = _formats[item.extension];
    if (format == null) return null;

    if (header.every((b) => b == 0)) {
      return 'File is filled with zero bytes, likely a failed download or copy';
    }
    if (!format.matchesHeader(header)) {
      return format.isText
          ? 'Text file contains binary data and is likely corrupted'
          : 'Contents are not a valid ${format.name} file';
    }
    try {
      final problem = await format.checkStructure?.call(context.source, item);
      if (problem != null) return problem;
    } on StorageReadException catch (e) {
      return 'File could not be read to the end (${e.message})';
    }

    if (item.isPhoto && await context.analyzeImage(item) is UndecodableImage) {
      return "Image data is damaged and can't be displayed";
    }
    return null;
  }
}

typedef _StructureCheck = Future<String?> Function(
    StorageSource source, StorageItem item);

final class _Format {
  const _Format(this.name, this.matchesHeader,
      {this.checkStructure, this.isText = false});

  final String name;
  final bool Function(Uint8List header) matchesHeader;
  final _StructureCheck? checkStructure;
  final bool isText;
}

bool _bytesAt(Uint8List h, int offset, List<int> expected) {
  if (h.length < offset + expected.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (h[offset + i] != expected[i]) return false;
  }
  return true;
}

bool _asciiAt(Uint8List h, int offset, String text) =>
    _bytesAt(h, offset, text.codeUnits);

int _indexOf(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

Future<Uint8List> _tail(StorageSource source, StorageItem item, int length) =>
    source.readRange(
        item, math.max(0, item.sizeBytes - length), item.sizeBytes);

const _cutOff =
    'File ends partway through; it was cut off before it finished saving';

Future<String?> _pngEnd(StorageSource source, StorageItem item) async =>
    _indexOf(await _tail(source, item, 64), 'IEND'.codeUnits) < 0
        ? _cutOff
        : null;

Future<String?> _pdfEnd(StorageSource source, StorageItem item) async =>
    // PDF readers look for the end marker in the last 1 KB.
    _indexOf(await _tail(source, item, 1024), '%%EOF'.codeUnits) < 0
        ? _cutOff
        : null;

Future<String?> _zipEnd(StorageSource source, StorageItem item) async =>
    // A ZIP's table of contents (end-of-central-directory record) sits in
    // the last 22 bytes plus up to 64 KB of comment. Without it nothing in
    // the archive can be found.
    _indexOf(await _tail(source, item, 22 + 65535),
                const [0x50, 0x4B, 0x05, 0x06]) <
            0
        ? _cutOff
        : null;

/// Walks the top-level boxes of an ISO media file (MP4, MOV, HEIC…). A box
/// that runs past the end of the file means the file was truncated; a video
/// with no `moov` box has no index and can't be played.
_StructureCheck _isoBoxes({required bool requireMovie}) =>
    (source, item) async {
      final size = item.sizeBytes;
      var pos = 0;
      var sawMovie = false;
      for (var boxes = 0; pos + 8 <= size; boxes++) {
        if (boxes == 10000) return null; // Pathological file; don't judge it.
        final h = await source.readRange(item, pos, pos + 16);
        final data = ByteData.sublistView(h);
        var boxSize = data.getUint32(0);
        final type = String.fromCharCodes(h, 4, 8);
        if (boxSize == 1) {
          if (h.length < 16) return _cutOff;
          boxSize = data.getUint64(8);
        } else if (boxSize == 0) {
          boxSize = size - pos; // "Runs to the end of the file."
        }
        if (boxSize < 8) return 'File structure is corrupt';
        if (type == 'moov') sawMovie = true;
        if (pos + boxSize > size) return _cutOff;
        pos += boxSize;
      }
      if (requireMovie && !sawMovie) {
        return "Video is missing its index and can't be played "
            '(usually from a recording that was interrupted)';
      }
      return null;
    };

bool _isFtyp(Uint8List h) => _asciiAt(h, 4, 'ftyp');

bool _riff(Uint8List h, String form) =>
    _asciiAt(h, 0, 'RIFF') && _asciiAt(h, 8, form);

bool _zipHeader(Uint8List h) =>
    _bytesAt(h, 0, const [0x50, 0x4B, 0x03, 0x04]) ||
    _bytesAt(h, 0, const [0x50, 0x4B, 0x05, 0x06]) ||
    _bytesAt(h, 0, const [0x50, 0x4B, 0x07, 0x08]);

bool _textHeader(Uint8List h) {
  // UTF-16 text legitimately contains zero bytes.
  if (_bytesAt(h, 0, const [0xFF, 0xFE]) ||
      _bytesAt(h, 0, const [0xFE, 0xFF])) {
    return true;
  }
  return !h.contains(0);
}

final _jpeg = _Format('JPEG', (h) => _bytesAt(h, 0, const [0xFF, 0xD8, 0xFF]));
final _png = _Format(
    'PNG',
    (h) =>
        _bytesAt(h, 0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    checkStructure: _pngEnd);
final _heif = _Format('HEIF image', _isFtyp,
    checkStructure: _isoBoxes(requireMovie: false));
final _mp4 =
    _Format('MP4', _isFtyp, checkStructure: _isoBoxes(requireMovie: true));
final _mov = _Format(
    'QuickTime video',
    (h) => const ['ftyp', 'moov', 'mdat', 'wide', 'free', 'skip']
        .any((t) => _asciiAt(h, 4, t)),
    checkStructure: _isoBoxes(requireMovie: true));
final _zip = _Format('ZIP-based', _zipHeader, checkStructure: _zipEnd);
final _ole = _Format(
    'Office',
    (h) =>
        _bytesAt(h, 0, const [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]));
final _text = _Format('text', _textHeader, isText: true);

final Map<String, _Format> _formats = {
  'jpg': _jpeg,
  'jpeg': _jpeg,
  'png': _png,
  'gif': _Format('GIF', (h) => _asciiAt(h, 0, 'GIF8')),
  'bmp': _Format('BMP', (h) => _asciiAt(h, 0, 'BM')),
  'webp': _Format('WebP', (h) => _riff(h, 'WEBP')),
  'tif': _Format('TIFF', _tiffHeader),
  'tiff': _Format('TIFF', _tiffHeader),
  'heic': _heif,
  'heif': _heif,
  'avif': _heif,
  'mp4': _mp4,
  'm4v': _mp4,
  'm4a': _mp4,
  '3gp': _mp4,
  'mov': _mov,
  'mkv': _Format(
      'Matroska', (h) => _bytesAt(h, 0, const [0x1A, 0x45, 0xDF, 0xA3])),
  'webm':
      _Format('WebM', (h) => _bytesAt(h, 0, const [0x1A, 0x45, 0xDF, 0xA3])),
  'avi': _Format('AVI', (h) => _riff(h, 'AVI ')),
  'mp3': _Format(
      'MP3',
      (h) =>
          _asciiAt(h, 0, 'ID3') ||
          (h.length > 1 && h[0] == 0xFF && h[1] & 0xE0 == 0xE0)),
  'wav': _Format('WAV', (h) => _riff(h, 'WAVE')),
  'ogg': _Format('Ogg', (h) => _asciiAt(h, 0, 'OggS')),
  'opus': _Format('Opus', (h) => _asciiAt(h, 0, 'OggS')),
  'flac': _Format('FLAC', (h) => _asciiAt(h, 0, 'fLaC')),
  'pdf': _Format(
      'PDF',
      (h) =>
          _indexOf(h.sublist(0, math.min(h.length, 1024)), '%PDF-'.codeUnits) >=
          0,
      checkStructure: _pdfEnd),
  'zip': _zip,
  'docx': _zip,
  'xlsx': _zip,
  'pptx': _zip,
  'odt': _zip,
  'ods': _zip,
  'odp': _zip,
  'epub': _zip,
  'apk': _zip,
  'jar': _zip,
  'doc': _ole,
  'xls': _ole,
  'ppt': _ole,
  'rtf': _Format('RTF', (h) => _asciiAt(h, 0, r'{\rtf')),
  '7z': _Format('7-Zip',
      (h) => _bytesAt(h, 0, const [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])),
  'rar': _Format('RAR', (h) => _asciiAt(h, 0, 'Rar!\x1A\x07')),
  'gz': _Format('gzip', (h) => _bytesAt(h, 0, const [0x1F, 0x8B])),
  for (final ext in const [
    'txt', 'csv', 'json', 'xml', 'html', 'htm', 'md', 'log', 'srt', 'vcf',
    'ics', 'svg', //
  ])
    ext: _text,
};

bool _tiffHeader(Uint8List h) =>
    _bytesAt(h, 0, const [0x49, 0x49, 0x2A, 0x00]) ||
    _bytesAt(h, 0, const [0x4D, 0x4D, 0x00, 0x2A]);
