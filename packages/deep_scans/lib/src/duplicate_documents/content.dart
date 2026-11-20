import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibDecoder;
import 'package:crypto/crypto.dart';

import '../empty_unreadable/bytes.dart';
import '../empty_unreadable/text_checks.dart' show decodeText, textExtensions;
import 'rules.dart';

/// How a document's content could be understood.
enum DocumentFormat {
  pdf('PDF'),
  officePackage('office document'),
  text('text'),
  rtf('RTF'),

  /// Anything else (audio, video, archives, unknown types): only compared
  /// byte for byte (F01).
  binary('file');

  const DocumentFormat(this.label);
  final String label;
}

/// What the content checks found inside one document: the keys and text the
/// F02–F05 rules compare.
final class DocumentContent {
  const DocumentContent({
    required this.format,
    this.contentKey,
    this.keyBasis,
    this.words = const [],
    this.noTextReason,
    this.pageCount = 0,
    this.scanPages = const [],
    this.bytesInflated = 0,
    this.textKey,
  });

  static const binary = DocumentContent(format: DocumentFormat.binary);

  final DocumentFormat format;

  /// F02: digest of the parts that make up the document's content, leaving
  /// out what changes every time it is saved (dates, ids, timestamps,
  /// compression, encoding). Equal keys mean a re-saved copy.
  final String? contentKey;

  /// What [contentKey] was built from, for evidence.
  final String? keyBasis;

  /// Normalised words of the document's text (lower case, punctuation and
  /// layout removed), for F03/F04. Empty when there is no usable text.
  final List<String> words;

  /// Why [words] is empty, when the format normally has text.
  final String? noTextReason;

  /// PDF pages.
  final int pageCount;

  /// F05: the JPEG data of each page, when the document is a scan (one
  /// full-page photo per page). Empty otherwise.
  final List<Uint8List> scanPages;

  /// Bytes produced by inflating compressed parts, for the stats.
  final int bytesInflated;

  bool get isScan => scanPages.isNotEmpty;

  /// Digest of [words], for F03.
  final String? textKey;
}

/// Reads [bytes] (a whole file named with extension [ext]) as a document.
DocumentContent readDocument(
    Uint8List bytes, String ext, DuplicateDocumentRules rules) {
  if (asciiAt(bytes, 0, '%PDF')) return _pdf(bytes, rules);
  if (bytesAt(bytes, 0, const [0x50, 0x4B, 0x03, 0x04])) {
    return _package(bytes, rules) ?? DocumentContent.binary;
  }
  if (asciiAt(bytes, 0, r'{\rtf')) return _rtf(bytes, rules);
  if (textExtensions.contains(ext)) return _text(bytes, ext, rules);
  return DocumentContent.binary;
}

// --- Text -----------------------------------------------------------------

final _wordSplit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Lower-case words with punctuation, symbols and layout removed.
List<String> wordsOf(String text) => [
      for (final w in text.toLowerCase().split(_wordSplit))
        if (w.isNotEmpty) w
    ];

/// Text with encoding and line-ending differences removed: what F02 compares
/// for text files.
String normalizeText(String text) => text
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .split('\n')
    .map((l) => l.trimRight())
    .join('\n')
    .trimRight();

final _markupNoise =
    RegExp(r'<(script|style)\b.*?</\1>|<!--.*?-->', dotAll: true);
final _tag = RegExp(r'<[^>]*>');

String _visibleMarkup(String markup) =>
    _entities(markup.replaceAll(_markupNoise, ' ').replaceAll(_tag, ' '));

DocumentContent _text(
    Uint8List bytes, String ext, DuplicateDocumentRules rules) {
  final text = decodeText(bytes);
  final normal = normalizeText(text);
  final visible = const {'html', 'htm', 'xml', 'svg'}.contains(ext)
      ? _visibleMarkup(text)
      : text;
  return _withText(
      DocumentFormat.text,
      sha256.convert(utf8.encode(normal)).toString(),
      'text after encoding and line-ending normalisation',
      visible,
      rules);
}

DocumentContent _rtf(Uint8List bytes, DuplicateDocumentRules rules) {
  final raw = latin1.decode(bytes);
  final text = raw
      .replaceAllMapped(RegExp(r"\\'([0-9a-fA-F]{2})"),
          (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
      .replaceAll(RegExp(r'\{\\\*[^{}]*\}'), ' ')
      .replaceAll(RegExp(r'\\(par|line|tab)\b ?'), ' ')
      .replaceAll(RegExp(r'\\[a-zA-Z]+-?\d* ?'), '')
      .replaceAll(RegExp(r'[{}\\]'), '');
  return _withText(
      DocumentFormat.rtf,
      sha256.convert(utf8.encode(normalizeText(raw))).toString(),
      'RTF source after line-ending normalisation',
      text,
      rules);
}

DocumentContent _withText(DocumentFormat format, String key, String basis,
    String text, DuplicateDocumentRules rules,
    {int pageCount = 0,
    List<Uint8List> scanPages = const [],
    int inflated = 0}) {
  final quality = _letterShare(text);
  final usable = quality >= rules.minLetterShare;
  final words = usable ? wordsOf(text) : const <String>[];
  return DocumentContent(
    format: format,
    contentKey: key,
    keyBasis: basis,
    words: words,
    noTextReason: !usable
        ? 'text is stored as font codes, not characters '
            '(${(quality * 100).toStringAsFixed(0)}% readable)'
        : words.isEmpty
            ? 'no text'
            : null,
    pageCount: pageCount,
    scanPages: scanPages,
    bytesInflated: inflated,
    textKey: words.isEmpty
        ? null
        : sha256.convert(utf8.encode(words.join(' '))).toString(),
  );
}

/// Share of letters, digits and whitespace among [text]'s characters.
double _letterShare(String text) {
  if (text.isEmpty) return 1;
  var good = 0;
  for (final rune in text.runes) {
    final c = String.fromCharCode(rune);
    if (_letterLike.hasMatch(c)) good++;
  }
  return good / text.runes.length;
}

final _letterLike =
    RegExp(r'[\p{L}\p{N}\s.,;:!?\-–—()/$€£%&@#"' "'" r']', unicode: true);

String _entities(String s) => s
    .replaceAllMapped(
        RegExp(r'&#(x?)([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(
            int.parse(m[2]!, radix: m[1]!.isEmpty ? 10 : 16)))
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&');

// --- PDF ------------------------------------------------------------------

final _streamStart = RegExp(r'>>\s*stream\r?\n');
final _directLength = RegExp(r'/Length\s+(\d+)(?!\s+\d+\s+R)');
final _pageObject = RegExp(r'/Type\s*/Page(?![a-zA-Z])');
// A single filter, given as a name or a one-element array.
final _flateOnly =
    RegExp(r'/Filter\s*(?:/FlateDecode\b|\[\s*/FlateDecode\s*\])');
final _anyFilter = RegExp(r'/Filter');
final _dctOnly = RegExp(r'/Filter\s*(?:/DCTDecode\b|\[\s*/DCTDecode\s*\])');
final _width = RegExp(r'/Width\s+(\d+)');
final _height = RegExp(r'/Height\s+(\d+)');
final _skippedForKey = RegExp(r'/Type\s*/(XRef|Metadata)\b');
final _fontProgram =
    RegExp(r'/Length[123]\b|/Subtype\s*/(Type1C|CIDFontType0C|OpenType)\b');

/// A PDF's content key is built from its streams (page contents, fonts,
/// images) after inflating them, leaving out the cross-reference and XMP
/// metadata streams and everything outside streams (the info dictionary
/// with its dates and producer, document ids, object offsets). Text comes
/// from the page content streams; a PDF whose pages are each one large
/// JPEG is a scan.
DocumentContent _pdf(Uint8List bytes, DuplicateDocumentRules rules) {
  final s = latin1.decode(bytes);
  var pages = _pageObject.allMatches(s).length;
  final key = AccumulatorSink<Digest>();
  final hasher = sha256.startChunkedConversion(key);
  final text = StringBuffer();
  final images = <Uint8List>[];
  var streams = 0, inflated = 0;

  for (final m in _streamStart.allMatches(s)) {
    final dictStart = s.lastIndexOf('obj', m.start);
    if (dictStart < 0) continue;
    final dict = s.substring(dictStart + 3, m.start + 2);
    final dataStart = m.end;
    var dataEnd = -1;
    final length = _directLength.firstMatch(dict);
    if (length != null) {
      final end = dataStart + int.parse(length[1]!);
      if (end <= bytes.length &&
          s
              .substring(end, (end + 12).clamp(0, s.length))
              .trimLeft()
              .startsWith('endstream')) {
        dataEnd = end;
      }
    }
    if (dataEnd < 0) {
      dataEnd = s.indexOf('endstream', dataStart);
      if (dataEnd < 0) break;
      while (dataEnd > dataStart &&
          (s[dataEnd - 1] == '\n' || s[dataEnd - 1] == '\r')) {
        dataEnd--;
      }
    }
    final raw = Uint8List.sublistView(bytes, dataStart, dataEnd);
    if (_skippedForKey.hasMatch(dict)) continue;
    streams++;

    final isImage = dict.contains('/Subtype') &&
        RegExp(r'/Subtype\s*/Image').hasMatch(dict);
    if (isImage) {
      hasher.add(raw);
      final w = int.tryParse(_width.firstMatch(dict)?[1] ?? '') ?? 0;
      final h = int.tryParse(_height.firstMatch(dict)?[1] ?? '') ?? 0;
      if (_dctOnly.hasMatch(dict) &&
          w >= rules.minScanPageSide &&
          h >= rules.minScanPageSide) {
        images.add(raw);
      }
      continue;
    }

    Uint8List data = raw;
    if (_flateOnly.hasMatch(dict) && raw.length <= rules.partMaxBytes) {
      try {
        data = ZLibDecoder().decodeBytes(raw);
        inflated += data.length;
      } catch (_) {
        data = raw; // Damaged stream: compare it as stored.
      }
    }
    hasher.add(data);
    if (_fontProgram.hasMatch(dict) ||
        (_anyFilter.hasMatch(dict) && identical(data, raw))) {
      continue;
    }
    final content = latin1.decode(data);
    if (dict.contains('/ObjStm')) {
      pages += _pageObject.allMatches(content).length;
    } else if (content.contains('BT')) {
      text.write(pdfContentText(content));
      text.write('\n');
    }
  }
  hasher.close();

  final isScan = images.isNotEmpty &&
      images.length == pages &&
      pages <= rules.maxScanPages;
  return _withText(
    DocumentFormat.pdf,
    streams == 0
        ? sha256.convert(bytes).toString()
        : '${key.events.single}:$pages',
    streams == 0
        ? 'whole file (no streams)'
        : '$streams streams, $pages pages; metadata, ids and offsets ignored',
    text.toString(),
    rules,
    pageCount: pages,
    scanPages: isScan ? images : const [],
    inflated: inflated,
  );
}

/// The text shown by a PDF content stream: strings given to the Tj, TJ, '
/// and " operators, with a space for each text move and wide TJ gap.
String pdfContentText(String c) {
  final out = StringBuffer();
  final pending = <String>[];
  var i = 0;
  while (i < c.length) {
    final ch = c.codeUnitAt(i);
    if (ch == 0x28) {
      // ( literal string )
      final (str, next) = _literal(c, i + 1);
      pending.add(str);
      i = next;
    } else if (ch == 0x3C) {
      if (i + 1 < c.length && c.codeUnitAt(i + 1) == 0x3C) {
        i += 2; // << dictionary
        continue;
      }
      final end = c.indexOf('>', i);
      if (end < 0) break;
      pending.add(_hexString(c.substring(i + 1, end)));
      i = end + 1;
    } else if (ch == 0x25) {
      // % comment
      final end = c.indexOf('\n', i);
      i = end < 0 ? c.length : end + 1;
    } else if (ch == 0x2F) {
      // /Name operand
      i++;
      while (i < c.length && !_delimiter(c.codeUnitAt(i))) {
        i++;
      }
    } else if (ch == 0x2D || ch == 0x2E || (ch >= 0x30 && ch <= 0x39)) {
      final start = i;
      i++;
      while (i < c.length && _numberChar(c.codeUnitAt(i))) {
        i++;
      }
      final n = double.tryParse(c.substring(start, i));
      // Inside TJ arrays, a large negative adjustment is a word gap.
      if (n != null && n <= -200 && pending.isNotEmpty) pending.add(' ');
    } else if (_operatorChar(ch)) {
      final start = i;
      while (i < c.length && _operatorChar(c.codeUnitAt(i))) {
        i++;
      }
      switch (c.substring(start, i)) {
        case 'Tj' || 'TJ' || "'" || '"':
          out
            ..writeAll(pending)
            ..write(' ');
        case 'Td' || 'TD' || 'T*' || 'Tm' || 'ET':
          out.write(' ');
      }
      pending.clear();
    } else {
      i++;
    }
  }
  return out.toString();
}

bool _delimiter(int c) => c <= 0x20 || '()<>[]{}/%'.codeUnits.contains(c);
bool _numberChar(int c) => c == 0x2E || (c >= 0x30 && c <= 0x39);
bool _operatorChar(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x27 ||
    c == 0x22 ||
    c == 0x2A;

/// Reads a literal string starting just after its "(": balanced parentheses
/// and backslash escapes. Returns the text and the index after the ")".
(String, int) _literal(String c, int i) {
  final out = StringBuffer();
  var depth = 1;
  while (i < c.length) {
    final ch = c[i];
    if (ch == r'\') {
      if (i + 1 >= c.length) break;
      final e = c[i + 1];
      i += 2;
      switch (e) {
        case 'n':
          out.write('\n');
        case 'r':
          out.write('\r');
        case 't':
          out.write('\t');
        case 'b' || 'f':
          break;
        case '\r' || '\n':
          if (e == '\r' && i < c.length && c[i] == '\n') i++;
        default:
          if (RegExp(r'[0-7]').hasMatch(e)) {
            var oct = e;
            while (oct.length < 3 &&
                i < c.length &&
                RegExp(r'[0-7]').hasMatch(c[i])) {
              oct += c[i++];
            }
            out.writeCharCode(int.parse(oct, radix: 8) & 0xFF);
          } else {
            out.write(e);
          }
      }
      continue;
    }
    if (ch == '(') depth++;
    if (ch == ')' && --depth == 0) return (out.toString(), i + 1);
    out.write(ch);
    i++;
  }
  return (out.toString(), i);
}

String _hexString(String hex) {
  final digits = hex.replaceAll(RegExp(r'\s'), '');
  final padded = digits.length.isOdd ? '${digits}0' : digits;
  final out = StringBuffer();
  for (var i = 0; i + 1 < padded.length; i += 2) {
    final v = int.tryParse(padded.substring(i, i + 2), radix: 16);
    if (v != null) out.writeCharCode(v);
  }
  return out.toString();
}

// --- ZIP-based office documents ---------------------------------------------

/// One entry of a ZIP central directory.
final class ZipEntry {
  const ZipEntry(this.name, this.method, this.crc, this.compressedSize,
      this.size, this.localOffset);
  final String name;
  final int method;
  final int crc;
  final int compressedSize;
  final int size;
  final int localOffset;
}

/// The entries in [bytes]' central directory, or null if it can't be found.
List<ZipEntry>? zipEntries(Uint8List bytes) {
  final from = bytes.length > 22 + 65535 ? bytes.length - 22 - 65535 : 0;
  final at = lastIndexOf(
      Uint8List.sublistView(bytes, from), const [0x50, 0x4B, 0x05, 0x06]);
  if (at < 0) return null;
  final eocd = from + at;
  if (eocd + 22 > bytes.length) return null;
  final count = u16le(bytes, eocd + 10);
  var pos = u32le(bytes, eocd + 16);
  final entries = <ZipEntry>[];
  while (entries.length < count && pos + 46 <= bytes.length) {
    if (!bytesAt(bytes, pos, const [0x50, 0x4B, 0x01, 0x02])) return null;
    final nameLen = u16le(bytes, pos + 28);
    if (pos + 46 + nameLen > bytes.length) return null;
    entries.add(ZipEntry(
      utf8.decode(bytes.sublist(pos + 46, pos + 46 + nameLen),
          allowMalformed: true),
      u16le(bytes, pos + 10),
      u32le(bytes, pos + 16),
      u32le(bytes, pos + 20),
      u32le(bytes, pos + 24),
      u32le(bytes, pos + 42),
    ));
    pos += 46 + nameLen + u16le(bytes, pos + 30) + u16le(bytes, pos + 32);
  }
  return entries.length == count ? entries : null;
}

/// The uncompressed bytes of [e], or null if it can't be read or is too big.
Uint8List? zipEntryData(Uint8List bytes, ZipEntry e, int maxBytes) {
  final o = e.localOffset;
  if (e.size > maxBytes || o + 30 > bytes.length) return null;
  if (!bytesAt(bytes, o, const [0x50, 0x4B, 0x03, 0x04])) return null;
  final start = o + 30 + u16le(bytes, o + 26) + u16le(bytes, o + 28);
  final end = start + e.compressedSize;
  if (end > bytes.length) return null;
  final data = Uint8List.sublistView(bytes, start, end);
  try {
    return switch (e.method) {
      0 => data,
      8 => ZLibDecoder().decodeBytes(data, raw: true),
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

/// Parts that change every time an office document is saved, without its
/// content changing: dates, editing time, the app version, thumbnails.
bool _isPackageMetadata(String name) {
  final n = name.toLowerCase();
  return n.startsWith('docprops/') ||
      n == 'meta.xml' ||
      n.startsWith('thumbnails/') ||
      n == 'settings.xml' ||
      n == 'word/settings.xml' ||
      n == 'xl/calcchain.xml';
}

final _docxParagraph = RegExp(r'</w:p>|<w:(tab|br|cr)\b[^>]*/>');
final _docxText = RegExp(r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>');
final _pptxText = RegExp(r'<a:t>([^<]*)</a:t>|</a:p>');
final _xlsxShared = RegExp(r'<si>(.*?)</si>', dotAll: true);
final _xlsxSharedText = RegExp(r'<t(?:\s[^>]*)?>([^<]*)</t>');
final _xlsxCell = RegExp(r'<c\b([^>]*?)(?:/>|>(.*?)</c>)', dotAll: true);
final _xlsxValue = RegExp(r'<v>([^<]*)</v>');
final _odfBreak = RegExp(
    r'</text:(p|h)>|<text:(s|tab|line-break)\b[^>]*/>|</table:table-cell>');
final _slideNumber = RegExp(r'(\d+)\.xml$');

/// A ZIP-based office document (docx, xlsx, pptx, odt/ods/odp, epub), or
/// null for an ordinary ZIP archive. The content key is the list of parts
/// with their checksums and sizes, minus the metadata parts: copies saved
/// with other timestamps or compression get the same key without inflating
/// anything.
DocumentContent? _package(Uint8List bytes, DuplicateDocumentRules rules) {
  final entries = zipEntries(bytes);
  if (entries == null) return null;
  final byName = {for (final e in entries) e.name: e};
  var inflated = 0;
  String? part(String name) {
    final e = byName[name];
    if (e == null) return null;
    final data = zipEntryData(bytes, e, rules.partMaxBytes);
    if (data == null) return null;
    inflated += data.length;
    return utf8.decode(data, allowMalformed: true);
  }

  String? text;
  if (byName.containsKey('word/document.xml')) {
    final xml = part('word/document.xml') ?? '';
    final out = StringBuffer();
    for (final para in xml.split(_docxParagraph)) {
      out
        ..writeAll(_docxText.allMatches(para).map((m) => m[1]))
        ..write('\n');
    }
    text = out.toString();
  } else if (byName.containsKey('xl/workbook.xml')) {
    final shared = [
      for (final si
          in _xlsxShared.allMatches(part('xl/sharedStrings.xml') ?? ''))
        _xlsxSharedText.allMatches(si[1]!).map((m) => m[1]).join()
    ];
    final out = StringBuffer();
    for (final name in _numbered(byName.keys, 'xl/worksheets/sheet')) {
      for (final c in _xlsxCell.allMatches(part(name) ?? '')) {
        final v = _xlsxValue.firstMatch(c[2] ?? '')?[1];
        if (v == null) continue;
        final i = c[1]!.contains('t="s"') ? int.tryParse(v) : null;
        out
          ..write(i != null && i < shared.length ? shared[i] : v)
          ..write(' ');
      }
      out.write('\n');
    }
    text = out.toString();
  } else if (byName.containsKey('ppt/presentation.xml')) {
    final out = StringBuffer();
    for (final name in _numbered(byName.keys, 'ppt/slides/slide')) {
      for (final m in _pptxText.allMatches(part(name) ?? '')) {
        out.write(m[1] ?? '\n');
      }
      out.write('\n');
    }
    text = out.toString();
  } else if (byName.containsKey('content.xml') &&
      byName.containsKey('mimetype')) {
    text = (part('content.xml') ?? '')
        .replaceAll(_odfBreak, ' ')
        .replaceAll(_tag, '');
  } else if (byName.containsKey('mimetype') &&
      (part('mimetype') ?? '').contains('epub')) {
    final pages = [
      for (final name in byName.keys)
        if (RegExp(r'\.x?html?$').hasMatch(name)) name
    ]..sort();
    text = pages.map((n) => _visibleMarkup(part(n) ?? '')).join('\n');
  } else {
    return null; // A plain archive.
  }

  final parts = [
    for (final e in entries)
      if (!e.name.endsWith('/') && !_isPackageMetadata(e.name))
        '${e.name}|${hex32(e.crc)}|${e.size}'
  ]..sort();
  return _withText(
    DocumentFormat.officePackage,
    sha256.convert(utf8.encode(parts.join('\n'))).toString(),
    '${parts.length} package parts by checksum; metadata parts, '
    'timestamps and compression ignored',
    _entities(text),
    rules,
    inflated: inflated,
  );
}

/// Names starting with [prefix] and ending in a number, in number order
/// (slide2 before slide10).
List<String> _numbered(Iterable<String> names, String prefix) {
  int n(String s) => int.parse(_slideNumber.firstMatch(s)![1]!);
  return [
    for (final name in names)
      if (name.startsWith(prefix) && _slideNumber.hasMatch(name)) name
  ]..sort((a, b) => n(a).compareTo(n(b)));
}

/// Collects the single digest from a chunked hash.
final class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];
  @override
  void add(T event) => events.add(event);
  @override
  void close() {}
}
