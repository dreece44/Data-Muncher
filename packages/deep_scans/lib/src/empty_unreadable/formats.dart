import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart' show MediaKind;

import 'bytes.dart';
import 'file_probe.dart';
import 'rules.dart';

/// One rule match from a check.
final class Hit {
  const Hit(this.rule, this.confidence, this.reason, [this.evidence]);

  final DeepRule rule;
  final Confidence confidence;
  final String reason;
  final String? evidence;
}

typedef FormatCheck = Future<Hit?> Function(
    FileProbe probe, EmptyUnreadableRules rules);

/// A file format the deep scan knows how to validate.
final class FormatSpec {
  const FormatSpec(this.name, this.matches,
      {this.check, this.sniffable = true});

  final String name;

  /// Whether the first bytes of a file are this format's signature.
  final bool Function(Uint8List head) matches;

  /// Structural checks run once the signature matches: truncation (U06),
  /// internal damage (U07) and empty containers (E04/E05).
  final FormatCheck? check;

  /// Whether the signature is distinctive enough to say "this file is really
  /// a X" when it turns up under another extension. Two-byte signatures
  /// (MP3 frame sync) aren't.
  final bool sniffable;
}

/// The format registered for [extension], if any.
FormatSpec? formatFor(String extension) => _byExtension[extension];

/// The real format of a file whose contents don't match its name, judged
/// from distinctive signatures only.
FormatSpec? sniffBinary(Uint8List head) {
  for (final f in _sniffOrder) {
    if (f.sniffable && f.matches(head)) return f;
  }
  return null;
}

/// What a non-matching file holds, when it's text: used to tell the user a
/// "PDF" is really a saved web page.
String? sniffTextKind(Uint8List head) {
  final sample = head.sublist(0, math.min(head.length, 512));
  if (sample.contains(0)) return null;
  final text = latin1.decode(sample).trimLeft().toLowerCase();
  final start = text.startsWith('ï»¿') ? text.substring(3).trimLeft() : text;
  if (start.startsWith('<!doctype html') ||
      start.startsWith('<html') ||
      start.startsWith('<head') ||
      start.startsWith('<body')) {
    return 'a web page';
  }
  if (start.startsWith('<?xml') || start.startsWith('<')) {
    return 'XML/markup text';
  }
  if (start.startsWith('{') || start.startsWith('[')) return 'JSON text';
  final printable = sample
      .where((b) => b == 9 || b == 10 || b == 13 || (b >= 32 && b < 127))
      .length;
  return printable >= sample.length * 0.95 ? 'plain text' : null;
}

// --- Shared helpers -------------------------------------------------------

/// A U06 hit, upgraded to "download stopped partway" (and to certain) when
/// the end of the file is blank: download managers reserve the full size up
/// front and fill it in as data arrives.
Future<Hit> cutOff(FileProbe p, String evidence,
    {Confidence confidence = Confidence.certain,
    String reason =
        'File ends partway through; it was cut off before it finished '
            'saving'}) async {
  final tail = await p.tail();
  final zeros = trailingZeros(tail);
  if (zeros >= 1024) {
    final atLeast = zeros == tail.length ? 'at least ' : '';
    return Hit(
        DeepRule.u06CutOff,
        Confidence.certain,
        'Download or copy stopped partway: the last $atLeast${kb(zeros)} '
            'were never filled in',
        '$evidence; $zeros trailing zero bytes');
  }
  return Hit(DeepRule.u06CutOff, confidence, reason, evidence);
}

Hit corrupt(String reason, String evidence,
        [Confidence confidence = Confidence.certain]) =>
    Hit(DeepRule.u07Corrupt, confidence, reason, evidence);

// --- Per-format checks ----------------------------------------------------

Future<Hit?> _pdf(FileProbe p, EmptyUnreadableRules r) async {
  // Readers look for the end marker in the last 1 KB.
  if (indexOf(await p.tail(1024), '%%EOF'.codeUnits) < 0) {
    return cutOff(p, 'no %%EOF in the last 1 KB');
  }
  if (p.size <= r.structuredTextMaxBytes) {
    final s = latin1.decode((await p.all())!);
    // Page objects inside compressed object streams can't be seen without
    // inflating, so only judge PDFs that don't use them.
    if (!s.contains('/ObjStm') &&
        !RegExp(r'/Type\s*/Page(?![a-zA-Z])').hasMatch(s) &&
        RegExp(r'/Count\s+0(?![0-9])').hasMatch(s)) {
      return const Hit(DeepRule.e05EmptyMedia, Confidence.likely,
          'PDF has no pages', 'page tree /Count 0 and no /Type /Page objects');
    }
  }
  return null;
}

Future<Hit?> _jpeg(FileProbe p, EmptyUnreadableRules r) async {
  if (indexOf(await p.tail(65536), const [0xFF, 0xD9]) >= 0) return null;

  // No end-of-image marker near the end. That's normal for "motion photos"
  // with a video appended, so find where the picture data actually is.
  final all = await p.all();
  if (all == null) return null;
  var pos = 2;
  int? scanStart;
  while (pos + 4 <= all.length) {
    if (all[pos] != 0xFF) {
      return corrupt("Image data is damaged and can't be displayed",
          'expected a marker at $pos, found 0x${all[pos].toRadixString(16)}');
    }
    final marker = all[pos + 1];
    if (marker == 0xFF) {
      pos++; // Fill byte.
    } else if (marker == 0xDA) {
      scanStart = pos;
      break;
    } else if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9)) {
      pos += 2;
    } else {
      pos += 2 + (all[pos + 2] << 8 | all[pos + 3]);
    }
  }
  if (scanStart == null) {
    return cutOff(p, 'no start-of-scan marker; header ends at $pos',
        reason: 'File ends before the picture data starts; it was cut off');
  }
  // Entropy-coded data can't contain FF D9, so any one after the first scan
  // is the real end of the image.
  if (indexOf(all, const [0xFF, 0xD9], scanStart) < 0) {
    return cutOff(p, 'no FF D9 end-of-image after scan at $scanStart',
        confidence: Confidence.likely,
        reason: 'Photo ends partway through the picture; the bottom is '
            'probably missing');
  }
  return null;
}

Future<Hit?> _png(FileProbe p, EmptyUnreadableRules r) async {
  final all = await p.all();
  if (all == null) {
    return indexOf(await p.tail(64), 'IEND'.codeUnits) < 0
        ? cutOff(p, 'no IEND chunk in the last 64 bytes')
        : null;
  }
  var pos = 8;
  var sawData = false;
  for (var n = 0;; n++) {
    if (pos + 8 > all.length) {
      return cutOff(
          p,
          pos == all.length
              ? 'ran out of chunks before IEND'
              : 'chunk header cut off at $pos');
    }
    final length = u32be(all, pos);
    final type = String.fromCharCodes(all, pos + 4, pos + 8);
    if (n == 0 && (type != 'IHDR' || length != 13)) {
      return corrupt("Image header is missing, so it can't be displayed",
          'first chunk is "$type" ($length bytes), expected IHDR (13)');
    }
    if (length > 0x7FFFFFFF) {
      return corrupt("Image data is damaged and can't be displayed",
          'chunk at $pos declares $length bytes');
    }
    final end = pos + 12 + length;
    if (end > all.length) {
      return cutOff(p,
          '$type chunk at $pos needs ${end - pos} bytes, ${all.length - pos} remain');
    }
    final stored = u32be(all, pos + 8 + length);
    final actual = crc32(all, pos + 4, pos + 8 + length);
    if (stored != actual) {
      return corrupt("Image data is damaged (failed its checksum)",
          '$type chunk at $pos: CRC ${hex32(actual)} != stored ${hex32(stored)}');
    }
    if (type == 'IHDR' &&
        (u32be(all, pos + 8) == 0 || u32be(all, pos + 12) == 0)) {
      return corrupt("Image says it is 0 pixels in size, so it can't be shown",
          'IHDR ${u32be(all, pos + 8)}x${u32be(all, pos + 12)}');
    }
    if (type == 'IDAT') sawData = true;
    if (type == 'IEND') break;
    pos = end;
  }
  return sawData
      ? null
      : corrupt("Image has no picture data, so it can't be displayed",
          'no IDAT chunk before IEND');
}

Future<Hit?> _gif(FileProbe p, EmptyUnreadableRules r) async =>
    (await p.tail(16)).contains(0x3B)
        ? null
        : cutOff(p, 'no 0x3B trailer in the last 16 bytes',
            confidence: Confidence.likely);

Future<Hit?> _bmp(FileProbe p, EmptyUnreadableRules r) async {
  final h = await p.head();
  if (h.length < 14) return cutOff(p, 'shorter than the 14-byte BMP header');
  final declared = u32le(h, 2);
  final dataOffset = u32le(h, 10);
  if (declared != 0 && declared > p.size) {
    return cutOff(p, 'header says $declared bytes, file has ${p.size}');
  }
  if (dataOffset >= p.size) {
    return cutOff(p, 'pixel data should start at $dataOffset',
        reason: 'File ends before the picture data starts; it was cut off');
  }
  return null;
}

Future<Hit?> _tiff(FileProbe p, EmptyUnreadableRules r) async {
  final h = await p.head();
  if (h.length < 8) return cutOff(p, 'shorter than the 8-byte TIFF header');
  final ifd = h[0] == 0x49 ? u32le(h, 4) : u32be(h, 4);
  return ifd >= p.size
      ? cutOff(p, 'first directory at $ifd, file has ${p.size} bytes')
      : null;
}

Future<Hit?> _riff(FileProbe p, EmptyUnreadableRules r) async {
  final h = await p.head();
  final declared = u32le(h, 4) + 8;
  if (declared > p.size) {
    return cutOff(p, 'RIFF header says $declared bytes, file has ${p.size}');
  }
  return null;
}

Future<Hit?> _wav(FileProbe p, EmptyUnreadableRules r) async {
  final riff = await _riff(p, r);
  if (riff != null) return riff;
  var pos = 12;
  for (var n = 0; n < 1000; n++) {
    if (pos + 8 > p.size) {
      return cutOff(p, 'no data chunk before end of file',
          reason: 'File ends before the recording starts; it was cut off');
    }
    final chunk = await p.at(pos, 8);
    final id = String.fromCharCodes(chunk, 0, 4);
    final size = u32le(chunk, 4);
    if (id == 'data') {
      final remaining = p.size - pos - 8;
      if (size == 0 && remaining == 0) {
        return const Hit(DeepRule.e05EmptyMedia, Confidence.certain,
            'Recording contains no sound', 'data chunk is 0 bytes');
      }
      if (size == 0 || size == 0xFFFFFFFF) {
        return Hit(
            DeepRule.u06CutOff,
            Confidence.likely,
            'Recording was never finished; its length was never saved',
            'data chunk size $size with $remaining bytes following');
      }
      if (size > remaining) {
        return cutOff(p, 'data chunk says $size bytes, $remaining remain');
      }
      return null;
    }
    pos += 8 + size + (size & 1);
  }
  return null;
}

/// Walks the top-level boxes of an ISO media file (MP4, MOV, M4A, HEIC…).
FormatCheck _isoBoxes({required bool requireMovie}) => (p, r) async {
      var pos = 0;
      var sawMovie = false, sawFragments = false;
      var mediaBytes = 0;
      for (var n = 0; pos + 8 <= p.size; n++) {
        if (n == 10000) return null; // Pathological; don't judge it.
        final h = await p.at(pos, 16);
        var boxSize = u32be(h, 0);
        final type = String.fromCharCodes(h, 4, 8);
        var header = 8;
        if (boxSize == 1) {
          if (h.length < 16) return cutOff(p, 'large box header cut off');
          boxSize = u32be(h, 8) * 0x100000000 + u32be(h, 12);
          header = 16;
        } else if (boxSize == 0) {
          boxSize = p.size - pos; // "Runs to the end of the file."
        }
        if (boxSize < header) {
          return corrupt('File structure is corrupt',
              'box "$type" at $pos has size $boxSize');
        }
        if (pos + boxSize > p.size) {
          return cutOff(p,
              'box "$type" at $pos needs $boxSize bytes, ${p.size - pos} remain');
        }
        if (type == 'moov') sawMovie = true;
        if (type == 'moof') sawFragments = true;
        if (type == 'mdat') mediaBytes += boxSize - header;
        pos += boxSize;
      }
      if (!requireMovie) return null;
      if (mediaBytes == 0 && !sawFragments) {
        return Hit(
            DeepRule.e05EmptyMedia,
            Confidence.certain,
            p.item.kind == MediaKind.audio
                ? 'Recording contains no sound'
                : 'Video contains no picture or sound',
            'no mdat payload${sawMovie ? '' : ' and no moov'}');
      }
      if (!sawMovie) {
        return cutOff(p, 'no moov box',
            reason: "Video is missing its index and can't be played "
                '(usually from a recording that was interrupted)');
      }
      return null;
    };

Future<Hit?> _mp3(FileProbe p, EmptyUnreadableRules r) async {
  final h = await p.head();
  if (!asciiAt(h, 0, 'ID3') || h.length < 10) return null;
  final tagEnd = 10 +
      ((h[6] & 0x7F) << 21 |
          (h[7] & 0x7F) << 14 |
          (h[8] & 0x7F) << 7 |
          (h[9] & 0x7F)) +
      ((h[5] & 0x10) != 0 ? 10 : 0);
  if (tagEnd >= p.size) {
    return Hit(
        DeepRule.e05EmptyMedia,
        Confidence.certain,
        'Audio file holds only song details, no audio',
        'ID3 tag runs to $tagEnd, file is ${p.size} bytes');
  }
  final audio = [
    ...await p.at(tagEnd, r.sampleBytes),
    ...await p.middle(r.sampleBytes),
    ...await p.tail(r.sampleBytes),
  ];
  return allZero(audio)
      ? Hit(
          DeepRule.u04ZeroFilled,
          Confidence.certain,
          'Audio data is blank (all zero bytes), likely a failed download',
          'samples after ID3 tag at $tagEnd are all zero')
      : null;
}

Future<Hit?> _ogg(FileProbe p, EmptyUnreadableRules r) async {
  final tail = await p.tail();
  final last = lastIndexOf(tail, 'OggS'.codeUnits);
  if (last < 0 || last + 5 >= tail.length) {
    return cutOff(p, 'no Ogg page in the last ${tail.length} bytes',
        confidence: Confidence.likely);
  }
  if (tail[last + 5] & 0x04 == 0) {
    return cutOff(p, 'last Ogg page has no end-of-stream flag',
        confidence: Confidence.likely,
        reason: 'Recording was interrupted before it finished saving');
  }
  return null;
}

/// Parts a ZIP-based document must contain to open.
const _requiredZipParts = {
  'docx': '[Content_Types].xml',
  'xlsx': '[Content_Types].xml',
  'pptx': '[Content_Types].xml',
  'odt': 'mimetype',
  'ods': 'mimetype',
  'odp': 'mimetype',
  'epub': 'mimetype',
  'apk': 'AndroidManifest.xml',
};

Future<Hit?> _zip(FileProbe p, EmptyUnreadableRules r) async {
  final ext = p.item.extension;
  // Apps open these as documents; an empty one is broken, not an empty
  // archive. Anything else (.zip, or a ZIP under another name) is an archive.
  final isPackage = _requiredZipParts.containsKey(ext) || ext == 'jar';
  final tail = await p.tail();
  final at = lastIndexOf(tail, const [0x50, 0x4B, 0x05, 0x06]);
  if (at < 0 || at + 22 > tail.length) {
    return cutOff(p, 'no end-of-central-directory record');
  }
  final eocd = p.size - tail.length + at;
  final entries = u16le(tail, at + 10);
  final cdSize = u32le(tail, at + 12);
  var cdOffset = u32le(tail, at + 16);
  if (entries == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
    return null; // ZIP64: not validated.
  }
  if (entries == 0) {
    return !isPackage
        ? const Hit(DeepRule.e04EmptyArchive, Confidence.certain,
            'Archive is empty', 'central directory lists 0 entries')
        : corrupt('Document package is empty, so it can\'t be opened',
            '.$ext with 0 entries');
  }
  if (cdOffset + cdSize > eocd) {
    return corrupt("Archive's table of contents is damaged",
        'directory at $cdOffset+$cdSize overlaps end record at $eocd');
  }
  // Self-extracting archives have a prefix; their offsets are relative.
  var shift = 0;
  var cd = await p.at(cdOffset, math.min(cdSize, 1 << 20));
  if (!bytesAt(cd, 0, const [0x50, 0x4B, 0x01, 0x02])) {
    shift = eocd - cdSize - cdOffset;
    final moved = shift > 0 ? await p.at(eocd - cdSize, 4) : Uint8List(0);
    if (!bytesAt(moved, 0, const [0x50, 0x4B, 0x01, 0x02])) {
      return corrupt("Archive's table of contents is damaged",
          'no central directory signature at $cdOffset');
    }
    cdOffset += shift;
    cd = await p.at(cdOffset, cd.length);
  }

  // Walk the directory: names, sizes, and where the first entry lives.
  final names = <String>[];
  var totalSize = 0;
  int? firstLocal;
  var pos = 0;
  while (names.length < entries && pos + 46 <= cd.length) {
    if (!bytesAt(cd, pos, const [0x50, 0x4B, 0x01, 0x02])) {
      return corrupt("Archive's table of contents is damaged",
          'entry ${names.length} at directory offset $pos has no signature');
    }
    totalSize += u32le(cd, pos + 24);
    final nameLen = u16le(cd, pos + 28);
    firstLocal ??= u32le(cd, pos + 42) + shift;
    if (pos + 46 + nameLen > cd.length) break;
    names.add(utf8.decode(cd.sublist(pos + 46, pos + 46 + nameLen),
        allowMalformed: true));
    pos += 46 + nameLen + u16le(cd, pos + 30) + u16le(cd, pos + 32);
  }
  if (firstLocal != null &&
      !bytesAt(await p.at(firstLocal, 4), 0, const [0x50, 0x4B, 0x03, 0x04])) {
    return corrupt("Archive's table of contents points to the wrong place",
        'first entry should start at $firstLocal');
  }
  final complete = names.length == entries;
  final required = _requiredZipParts[ext];
  if (complete && required != null && !names.contains(required)) {
    return corrupt("Not a valid .$ext file: parts it needs to open are missing",
        'no "$required" among $entries entries', Confidence.likely);
  }
  if (complete && !isPackage && totalSize == 0) {
    return Hit(
        DeepRule.e04EmptyArchive,
        Confidence.likely,
        'Archive only contains empty files or folders',
        '$entries entries, 0 bytes uncompressed');
  }
  return null;
}

Future<Hit?> _ole(FileProbe p, EmptyUnreadableRules r) async {
  final h = await p.head();
  if (h.length < 512) return cutOff(p, 'shorter than the 512-byte header');
  final shift = u16le(h, 30);
  if (!bytesAt(h, 28, const [0xFE, 0xFF]) || (shift != 9 && shift != 12)) {
    return corrupt("Document header is damaged, so it can't be opened",
        'byte order ${h[28]},${h[29]}; sector shift $shift');
  }
  final sector = 1 << shift;
  if (p.size < sector * 2) {
    return cutOff(p, '${p.size} bytes is less than header + one sector');
  }
  return p.size % sector != 0
      ? cutOff(
          p,
          '${p.size} bytes is not a whole number of $sector-byte '
          'sectors',
          confidence: Confidence.likely)
      : null;
}

Future<Hit?> _rtf(FileProbe p, EmptyUnreadableRules r) async {
  final all = p.size <= r.structuredTextMaxBytes ? await p.all() : null;
  if (all == null) return null;
  var depth = 0;
  for (var i = 0; i < all.length; i++) {
    final b = all[i];
    if (b == 0x5C) {
      i++; // Skip the escaped character (\{, \}, \\).
    } else if (b == 0x7B) {
      depth++;
    } else if (b == 0x7D) {
      depth--;
    }
  }
  return depth > 0
      ? cutOff(p, '$depth unclosed groups at end of file',
          confidence: Confidence.likely,
          reason: 'Document ends partway through; it was cut off')
      : null;
}

Future<Hit?> _sevenZip(FileProbe p, EmptyUnreadableRules r) async {
  final h = await p.head();
  if (h.length < 32) return cutOff(p, 'shorter than the 32-byte header');
  final offset = u64le(h, 12), size = u64le(h, 20);
  if (offset == 0 && size == 0) {
    return const Hit(DeepRule.e04EmptyArchive, Confidence.certain,
        'Archive is empty', 'next-header offset and size are 0');
  }
  final end = 32 + offset + size;
  return end > p.size
      ? cutOff(p, 'archive index should end at $end, file has ${p.size}')
      : null;
}

Future<Hit?> _gzip(FileProbe p, EmptyUnreadableRules r) async {
  if (p.size < 18) return cutOff(p, 'shorter than the 18-byte minimum');
  final tail = await p.tail(4);
  // The footer holds the uncompressed size modulo 2^32; tiny files can't
  // wrap, so 0 really means empty.
  return u32le(tail, 0) == 0 && p.size < 1024
      ? const Hit(DeepRule.e04EmptyArchive, Confidence.certain,
          'Compressed file holds nothing', 'footer size is 0')
      : null;
}

// --- Signatures -----------------------------------------------------------

bool _isFtyp(Uint8List h) => asciiAt(h, 4, 'ftyp');
bool _riffForm(Uint8List h, String form) =>
    asciiAt(h, 0, 'RIFF') && asciiAt(h, 8, form);
bool _zipHeader(Uint8List h) =>
    bytesAt(h, 0, const [0x50, 0x4B, 0x03, 0x04]) ||
    bytesAt(h, 0, const [0x50, 0x4B, 0x05, 0x06]) ||
    bytesAt(h, 0, const [0x50, 0x4B, 0x07, 0x08]);
bool _bmpHeader(Uint8List h) =>
    asciiAt(h, 0, 'BM') &&
    h.length >= 18 &&
    const {12, 40, 52, 56, 64, 108, 124}.contains(u32le(h, 14));

final _jpegF = FormatSpec(
    'JPEG', (h) => bytesAt(h, 0, const [0xFF, 0xD8, 0xFF]),
    check: _jpeg);
final _pngF = FormatSpec(
    'PNG',
    (h) =>
        bytesAt(h, 0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    check: _png);
final _gifF = FormatSpec('GIF', (h) => asciiAt(h, 0, 'GIF8'), check: _gif);
final _bmpF = FormatSpec('BMP', _bmpHeader, check: _bmp);
final _webpF = FormatSpec('WebP', (h) => _riffForm(h, 'WEBP'), check: _riff);
final _tiffF = FormatSpec(
    'TIFF',
    (h) =>
        bytesAt(h, 0, const [0x49, 0x49, 0x2A, 0x00]) ||
        bytesAt(h, 0, const [0x4D, 0x4D, 0x00, 0x2A]),
    check: _tiff);
final _heifF =
    FormatSpec('HEIF image', _isFtyp, check: _isoBoxes(requireMovie: false));
final _mp4F = FormatSpec('MP4', _isFtyp, check: _isoBoxes(requireMovie: true));
final _movF = FormatSpec(
    'QuickTime video',
    (h) => const ['ftyp', 'moov', 'mdat', 'wide', 'free', 'skip']
        .any((t) => asciiAt(h, 4, t)),
    check: _isoBoxes(requireMovie: true),
    sniffable: false);
final _ebmlF = FormatSpec(
    'Matroska/WebM', (h) => bytesAt(h, 0, const [0x1A, 0x45, 0xDF, 0xA3]));
final _aviF = FormatSpec('AVI', (h) => _riffForm(h, 'AVI '), check: _riff);
final _mp3F = FormatSpec(
    'MP3',
    (h) =>
        asciiAt(h, 0, 'ID3') ||
        (h.length > 1 && h[0] == 0xFF && h[1] & 0xE0 == 0xE0),
    check: _mp3,
    sniffable: false);
final _wavF = FormatSpec('WAV', (h) => _riffForm(h, 'WAVE'), check: _wav);
final _oggF = FormatSpec('Ogg', (h) => asciiAt(h, 0, 'OggS'), check: _ogg);
final _flacF = FormatSpec('FLAC', (h) => asciiAt(h, 0, 'fLaC'));
final _pdfF = FormatSpec(
    'PDF',
    (h) =>
        indexOf(h.sublist(0, math.min(h.length, 1024)), '%PDF-'.codeUnits) >= 0,
    check: _pdf);
final _zipF = FormatSpec('ZIP-based', _zipHeader, check: _zip);
final _oleF = FormatSpec(
    'Office',
    (h) =>
        bytesAt(h, 0, const [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]),
    check: _ole);
final _rtfF = FormatSpec('RTF', (h) => asciiAt(h, 0, r'{\rtf'), check: _rtf);
final _sevenZipF = FormatSpec(
    '7-Zip', (h) => bytesAt(h, 0, const [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]),
    check: _sevenZip);
final _rarF = FormatSpec('RAR', (h) => asciiAt(h, 0, 'Rar!\x1A\x07'));
final _gzipF = FormatSpec(
    'gzip', (h) => bytesAt(h, 0, const [0x1F, 0x8B, 0x08]),
    check: _gzip);

final List<FormatSpec> _sniffOrder = [
  _jpegF, _pngF, _gifF, _bmpF, _webpF, _tiffF, _mp4F, _ebmlF, _aviF, _wavF,
  _oggF, _flacF, _pdfF, _zipF, _oleF, _rtfF, _sevenZipF, _rarF, _gzipF, //
];

final Map<String, FormatSpec> _byExtension = {
  'jpg': _jpegF,
  'jpeg': _jpegF,
  'png': _pngF,
  'gif': _gifF,
  'bmp': _bmpF,
  'webp': _webpF,
  'tif': _tiffF,
  'tiff': _tiffF,
  'heic': _heifF,
  'heif': _heifF,
  'avif': _heifF,
  'mp4': _mp4F,
  'm4v': _mp4F,
  'm4a': _mp4F,
  '3gp': _mp4F,
  'mov': _movF,
  'mkv': _ebmlF,
  'webm': _ebmlF,
  'avi': _aviF,
  'mp3': _mp3F,
  'wav': _wavF,
  'ogg': _oggF,
  'opus': _oggF,
  'flac': _flacF,
  'pdf': _pdfF,
  for (final ext in const [
    'zip', 'docx', 'xlsx', 'pptx', 'odt', 'ods', 'odp', 'epub', 'apk', 'jar', //
  ])
    ext: _zipF,
  'doc': _oleF,
  'xls': _oleF,
  'ppt': _oleF,
  'rtf': _rtfF,
  '7z': _sevenZipF,
  'rar': _rarF,
  'gz': _gzipF,
};
