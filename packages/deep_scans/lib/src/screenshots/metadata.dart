import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibDecoder;

import '../empty_unreadable/bytes.dart';

/// What an image file's own metadata says about where it came from: camera
/// details (a camera photo) or a screenshot tool's mark. Read from JPEG
/// APP1 (Exif, XMP), PNG text and `eXIf` chunks, and WebP `EXIF`/`XMP `
/// chunks; other formats return [ImageMetadata.none].
final class ImageMetadata {
  const ImageMetadata({
    this.make,
    this.model,
    this.software,
    this.userComment,
    this.cameraTags = const {},
    this.textEntries = const {},
    this.xmp,
  });

  static const none = ImageMetadata();

  final String? make, model, software, userComment;

  /// Exposure tags present (ExposureTime, FNumber, ISO, FocalLength): what
  /// only a camera writes.
  final Set<String> cameraTags;

  /// PNG text chunks by keyword (Software, Description, Comment, Title…).
  final Map<String, String> textEntries;

  /// The XMP packet, if any.
  final String? xmp;

  /// The camera evidence, or null when there is none. Exposure tags are
  /// what counts: some apps copy Make/Model into images they save, but
  /// nothing but a camera records an exposure.
  String? get cameraEvidence {
    if (cameraTags.isEmpty) return null;
    final who = [make, model].whereType<String>().join(' ').trim();
    return '${who.isEmpty ? 'camera' : who} exposure data '
        '(${(cameraTags.toList()..sort()).join(', ')})';
  }

  /// A screenshot tool's mark: XMP or Exif UserComment "Screenshot" (iOS,
  /// macOS), or a Software / Description / Comment entry naming a capture
  /// tool. Returns where it was found, or null.
  String? screenshotMarker(Set<String> toolWords) {
    bool screenshot(String? s) =>
        s != null && s.toLowerCase().contains('screenshot');
    String? tool(String? s) {
      if (s == null) return null;
      final lower = s.toLowerCase();
      for (final word in toolWords) {
        if (lower.contains(word)) return word;
      }
      return null;
    }

    if (screenshot(userComment)) return 'Exif UserComment "$userComment"';
    final x = xmp;
    if (x != null) {
      final comment =
          RegExp(r'UserComment[^>]*>(?:\s*<[^>]+>)*\s*([^<]*)').firstMatch(x);
      if (comment != null && screenshot(comment.group(1))) {
        return 'XMP UserComment "${comment.group(1)!.trim()}"';
      }
      final creator =
          RegExp(r'CreatorTool(?:="([^"]*)"|>([^<]*)<)').firstMatch(x);
      final name = creator?.group(1) ?? creator?.group(2);
      if (tool(name) != null) return 'XMP CreatorTool "$name"';
    }
    if (tool(software) != null) return 'Software "$software"';
    for (final MapEntry(:key, :value) in textEntries.entries) {
      if (const {'software', 'description', 'comment', 'title', 'source'}
              .contains(key.toLowerCase()) &&
          tool(value) != null) {
        return 'PNG $key "$value"';
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        if (make != null) 'make': make,
        if (model != null) 'model': model,
        if (software != null) 'software': software,
        if (userComment != null) 'userComment': userComment,
        if (cameraTags.isNotEmpty) 'cameraTags': cameraTags.toList()..sort(),
        if (textEntries.isNotEmpty) 'text': textEntries,
        if (xmp != null) 'xmpBytes': xmp!.length,
      };
}

/// Reads [ImageMetadata] from the start of an image file ([head]: the
/// first bytes, enough to cover the metadata; JPEG and PNG keep it before
/// the picture data). Never throws: damaged metadata reads as missing.
ImageMetadata readImageMetadata(Uint8List head) {
  try {
    if (bytesAt(head, 0, const [0xFF, 0xD8])) return _jpeg(head);
    if (bytesAt(head, 0, const [0x89, 0x50, 0x4E, 0x47])) return _png(head);
    if (asciiAt(head, 0, 'RIFF') && asciiAt(head, 8, 'WEBP')) {
      return _webp(head);
    }
  } on RangeError {
    // Metadata ran past what was read, or lengths are nonsense.
  } on FormatException {
    // Compressed text that won't inflate.
  }
  return ImageMetadata.none;
}

/// Width and height from an image's header (PNG IHDR, JPEG SOF, WebP VP8
/// headers), without decoding it. Null if [head] doesn't hold them.
(int, int)? readImageSize(Uint8List head) {
  try {
    if (bytesAt(head, 0, const [0x89, 0x50, 0x4E, 0x47]) &&
        asciiAt(head, 12, 'IHDR')) {
      return (u32be(head, 16), u32be(head, 20));
    }
    if (bytesAt(head, 0, const [0xFF, 0xD8])) {
      var o = 2;
      while (o + 9 < head.length && head[o] == 0xFF) {
        final marker = head[o + 1];
        if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
          o += 2;
          continue;
        }
        final length = head[o + 2] << 8 | head[o + 3];
        // SOF0–SOF15, except DHT (C4), JPG (C8) and DAC (CC).
        if (marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC) {
          return (
            head[o + 7] << 8 | head[o + 8],
            head[o + 5] << 8 | head[o + 6]
          );
        }
        if (marker == 0xDA || length < 2) return null;
        o += 2 + length;
      }
      return null;
    }
    if (asciiAt(head, 0, 'RIFF') && asciiAt(head, 8, 'WEBP')) {
      if (asciiAt(head, 12, 'VP8X')) {
        return (
          1 + (head[24] | head[25] << 8 | head[26] << 16),
          1 + (head[27] | head[28] << 8 | head[29] << 16)
        );
      }
      if (asciiAt(head, 12, 'VP8 ')) {
        return (u16le(head, 26) & 0x3FFF, u16le(head, 28) & 0x3FFF);
      }
      if (asciiAt(head, 12, 'VP8L')) {
        final bits = u32le(head, 21);
        return (1 + (bits & 0x3FFF), 1 + (bits >> 14 & 0x3FFF));
      }
    }
  } on RangeError {
    // Header shorter than it claims.
  }
  return null;
}

ImageMetadata _jpeg(Uint8List b) {
  var exif = _Tiff.empty;
  String? xmp;
  var o = 2;
  while (o + 4 <= b.length && b[o] == 0xFF) {
    final marker = b[o + 1];
    if (marker == 0xD9 || marker == 0xDA) break; // end, or picture data
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      o += 2;
      continue;
    }
    final length = b[o + 2] << 8 | b[o + 3];
    final start = o + 4, end = o + 2 + length;
    if (length < 2 || end > b.length) break;
    if (marker == 0xE1) {
      if (asciiAt(b, start, 'Exif\x00\x00')) {
        exif = _Tiff.read(Uint8List.sublistView(b, start + 6, end));
      } else if (asciiAt(b, start, 'http://ns.adobe.com/xap/1.0/\x00')) {
        xmp = utf8.decode(b.sublist(start + 29, end), allowMalformed: true);
      }
    }
    o = end;
  }
  return exif.metadata(xmp: xmp);
}

ImageMetadata _png(Uint8List b) {
  var exif = _Tiff.empty;
  String? xmp;
  final text = <String, String>{};
  var o = 8;
  while (o + 8 <= b.length) {
    final length = u32be(b, o);
    final type = String.fromCharCodes(b, o + 4, o + 8);
    final start = o + 8, end = start + length;
    if (end > b.length || type == 'IDAT' || type == 'IEND') break;
    final data = Uint8List.sublistView(b, start, end);
    switch (type) {
      case 'eXIf':
        exif = _Tiff.read(data);
      case 'tEXt':
        final nul = data.indexOf(0);
        if (nul > 0) {
          text[latin1.decode(data.sublist(0, nul))] =
              latin1.decode(data.sublist(nul + 1));
        }
      case 'zTXt':
        final nul = data.indexOf(0);
        if (nul > 0 && nul + 2 <= data.length) {
          text[latin1.decode(data.sublist(0, nul))] = latin1
              .decode(const ZLibDecoder().decodeBytes(data.sublist(nul + 2)));
        }
      case 'iTXt':
        final nul = data.indexOf(0);
        if (nul > 0 && nul + 3 <= data.length) {
          final key = latin1.decode(data.sublist(0, nul));
          final compressed = data[nul + 1] == 1;
          var at = nul + 3;
          for (var skip = 0; skip < 2; skip++) {
            final next = data.indexOf(0, at);
            if (next < 0) break;
            at = next + 1;
          }
          var body = data.sublist(at);
          if (compressed) body = const ZLibDecoder().decodeBytes(body);
          final value = utf8.decode(body, allowMalformed: true);
          if (key == 'XML:com.adobe.xmp') {
            xmp = value;
          } else {
            text[key] = value;
          }
        }
    }
    o = end + 4; // skip the CRC; the empty & unreadable checks verify it
  }
  return exif.metadata(xmp: xmp, text: text);
}

ImageMetadata _webp(Uint8List b) {
  var exif = _Tiff.empty;
  String? xmp;
  var o = 12;
  while (o + 8 <= b.length) {
    final type = String.fromCharCodes(b, o, o + 4);
    final length = u32le(b, o + 4);
    final start = o + 8, end = start + length;
    if (end > b.length) break;
    if (type == 'EXIF') {
      var data = Uint8List.sublistView(b, start, end);
      if (asciiAt(data, 0, 'Exif\x00\x00')) data = data.sublist(6);
      exif = _Tiff.read(data);
    } else if (type == 'XMP ') {
      xmp = utf8.decode(b.sublist(start, end), allowMalformed: true);
    }
    o = end + (length & 1);
  }
  return exif.metadata(xmp: xmp);
}

/// The few TIFF/Exif tags the screenshot scan cares about.
final class _Tiff {
  const _Tiff(this.strings, this.cameraTags);

  static const empty = _Tiff({}, {});

  final Map<int, String> strings;
  final Set<String> cameraTags;

  static const _cameraTagNames = {
    0x829A: 'ExposureTime',
    0x829D: 'FNumber',
    0x8827: 'ISO',
    0x920A: 'FocalLength',
  };

  static _Tiff read(Uint8List t) {
    if (t.length < 8) return empty;
    final little = t[0] == 0x49 && t[1] == 0x49;
    if (!little && !(t[0] == 0x4D && t[1] == 0x4D)) return empty;
    int u16(int o) => little ? t[o] | t[o + 1] << 8 : t[o] << 8 | t[o + 1];
    int u32(int o) => little ? u32le(t, o) : u32be(t, o);

    final strings = <int, String>{};
    final camera = <String>{};
    final visited = <int>{};
    void ifd(int at) {
      if (at <= 0 || at + 2 > t.length || !visited.add(at)) return;
      final n = u16(at);
      for (var i = 0; i < n; i++) {
        final e = at + 2 + i * 12;
        if (e + 12 > t.length) return;
        final tag = u16(e), type = u16(e + 2), count = u32(e + 4);
        final size = count *
            const [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8][type < 13 ? type : 0];
        final valueAt = size <= 4 ? e + 8 : u32(e + 8);
        if (_cameraTagNames.containsKey(tag)) camera.add(_cameraTagNames[tag]!);
        if (tag == 0x8769) {
          ifd(u32(e + 8));
        } else if ((type == 2 || type == 7) &&
            const {0x010F, 0x0110, 0x0131, 0x010E, 0x9286}.contains(tag) &&
            valueAt + size <= t.length) {
          var raw = t.sublist(valueAt, valueAt + size);
          // UserComment starts with an 8-byte character-set code.
          if (tag == 0x9286 && raw.length >= 8) raw = raw.sublist(8);
          final s = latin1
              .decode(raw.where((c) => c != 0).toList(), allowInvalid: true)
              .trim();
          if (s.isNotEmpty) strings[tag] = s;
        }
      }
    }

    ifd(u32(4));
    return _Tiff(strings, camera);
  }

  ImageMetadata metadata({String? xmp, Map<String, String> text = const {}}) =>
      ImageMetadata(
        make: strings[0x010F],
        model: strings[0x0110],
        software: strings[0x0131],
        userComment: strings[0x9286],
        cameraTags: cameraTags,
        textEntries: text,
        xmp: xmp,
      );
}
