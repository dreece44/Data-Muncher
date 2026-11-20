import 'dart:convert';
import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart' show isBlankContent;

import 'bytes.dart';
import 'formats.dart';
import 'rules.dart';

/// Extensions treated as text: checked for garbling (U09) and, for the
/// structured ones, for having no entries (E03).
const textExtensions = {
  'txt', 'csv', 'tsv', 'json', 'xml', 'html', 'htm', 'md', 'log', 'srt', //
  'vcf', 'ics', 'svg',
};

bool _isUtf16Bom(List<int> b) =>
    bytesAt(b, 0, const [0xFF, 0xFE]) || bytesAt(b, 0, const [0xFE, 0xFF]);

/// Whether [bytes] hold no content: whitespace, zero bytes and byte-order
/// marks only. Unlike the mass scan, also understands UTF-16 text.
bool isBlank(Uint8List bytes) {
  if (!_isUtf16Bom(bytes)) return isBlankContent(bytes);
  final littleEndian = bytes[0] == 0xFF;
  for (var i = 2; i < bytes.length; i += 2) {
    if (i + 1 >= bytes.length) return bytes[i] == 0;
    final lo = littleEndian ? bytes[i] : bytes[i + 1];
    final hi = littleEndian ? bytes[i + 1] : bytes[i];
    if (hi != 0 || !const {0, 0x09, 0x0A, 0x0D, 0x20}.contains(lo)) {
      return false;
    }
  }
  return true;
}

/// UTF-16 saved without a byte-order mark: zero bytes sit almost entirely
/// in every other position. Plain-ASCII text in UTF-16 looks like this.
bool _looksUtf16WithoutBom(Uint8List sample) {
  var even = 0, odd = 0;
  for (var i = 0; i < sample.length; i++) {
    if (sample[i] == 0) i.isEven ? even++ : odd++;
  }
  final pairs = sample.length ~/ 2;
  if (pairs == 0) return false;
  final (hi, lo) = odd > even ? (odd, even) : (even, odd);
  return hi >= pairs * 0.5 && lo <= (hi + lo) * 0.05;
}

String decodeText(Uint8List bytes) {
  if (bytesAt(bytes, 0, const [0xFF, 0xFE]) ||
      bytesAt(bytes, 0, const [0xFE, 0xFF])) {
    final le = bytes[0] == 0xFF;
    final units = [
      for (var i = 2; i + 1 < bytes.length; i += 2)
        le ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1]
    ];
    return String.fromCharCodes(units);
  }
  final start = bytesAt(bytes, 0, const [0xEF, 0xBB, 0xBF]) ? 3 : 0;
  return utf8.decode(bytes.sublist(start), allowMalformed: true);
}

/// U09: text that's been damaged. Binary data in a text file, a high share
/// of control characters, or many U+FFFD characters (left behind when text
/// is converted with the wrong encoding and saved).
Hit? garbledText(Uint8List sample, Uint8List? whole, EmptyUnreadableRules r) {
  if (_isUtf16Bom(sample)) return null;
  if (sample.contains(0) && !_looksUtf16WithoutBom(sample)) {
    return Hit(
        DeepRule.u09GarbledText,
        Confidence.certain,
        'Text file contains binary data and is likely corrupted',
        '${sample.where((b) => b == 0).length} zero bytes in the first '
            '${sample.length}');
  }
  if (sample.length >= 64) {
    // Tab, newlines, form feed and ESC (colour codes in logs) are normal.
    final control = sample
        .where((b) =>
            (b < 0x20 && !const {0, 9, 10, 11, 12, 13, 27}.contains(b)) ||
            b == 0x7F)
        .length;
    if (control > sample.length * r.garbledControlRatio) {
      return Hit(
          DeepRule.u09GarbledText,
          Confidence.likely,
          'Text is garbled and unreadable',
          '$control control characters in the first ${sample.length} bytes');
    }
  }
  final text = whole ?? sample;
  var replacements = 0;
  for (var i = indexOf(text, const [0xEF, 0xBF, 0xBD]);
      i >= 0;
      i = indexOf(text, const [0xEF, 0xBF, 0xBD], i + 3)) {
    replacements++;
  }
  if (replacements >= r.replacementCharMin) {
    final chars = utf8.decode(text, allowMalformed: true).length;
    if (replacements >= chars * r.replacementCharRatio) {
      return Hit(
          DeepRule.u09GarbledText,
          Confidence.likely,
          'Text was damaged by a bad conversion; $replacements characters '
              'were lost',
          '$replacements U+FFFD of $chars characters');
    }
  }
  return null;
}

/// E03 (and JSON validity): a structured text file with nothing in it.
Hit? structuredText(String ext, String text) => switch (ext) {
      'json' => _json(text),
      'csv' => _table(text, ','),
      'tsv' => _table(text, '\t'),
      'html' || 'htm' => _html(text),
      'xml' => _xml(text),
      'svg' => _svg(text),
      'vcf' => _vcard(text),
      'ics' => _calendar(text),
      'srt' => text.contains('-->')
          ? null
          : const Hit(DeepRule.e03EmptyDocument, Confidence.likely,
              'Subtitle file has no subtitles', 'no "-->" timing lines'),
      _ => null,
    };

Hit _empty(String reason, String evidence,
        [Confidence confidence = Confidence.likely]) =>
    Hit(DeepRule.e03EmptyDocument, confidence, reason, evidence);

Hit? _json(String text) {
  Object? value;
  try {
    value = jsonDecode(text);
  } on FormatException catch (e) {
    // Line-delimited JSON (one record per line) is fine.
    final lines = [
      for (final l in const LineSplitter().convert(text))
        if (l.trim().isNotEmpty) l
    ];
    if (lines.length > 1 && lines.every(_parses)) return null;
    final depth = _openBrackets(text);
    return depth > 0
        ? Hit(
            DeepRule.u06CutOff,
            Confidence.likely,
            'Data file ends partway through; it was cut off',
            '$depth unclosed brackets')
        : Hit(DeepRule.u07Corrupt, Confidence.likely,
            "Data file is malformed and can't be read", e.message);
  }
  if (value == null ||
      (value is Map && value.isEmpty) ||
      (value is List && value.isEmpty) ||
      (value is String && value.isEmpty)) {
    return _empty(
        'Data file contains no data', 'JSON value is ${jsonEncode(value)}');
  }
  return null;
}

bool _parses(String line) {
  try {
    jsonDecode(line);
    return true;
  } on FormatException {
    return false;
  }
}

/// Unclosed `{`/`[` outside strings.
int _openBrackets(String text) {
  var depth = 0;
  var inString = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
    } else if (c == '"') {
      inString = true;
    } else if (c == '{' || c == '[') {
      depth++;
    } else if (c == '}' || c == ']') {
      depth--;
    }
  }
  return depth;
}

Hit? _table(String text, String delimiter) {
  final rows = [
    for (final line in const LineSplitter().convert(text))
      if (line
          .replaceAll(RegExp('[${RegExp.escape(delimiter)}"\\s]'), '')
          .isNotEmpty)
        line
  ];
  if (rows.isEmpty) {
    return _empty('Spreadsheet has no data, only empty cells',
        'every row is delimiters/quotes/whitespace', Confidence.certain);
  }
  // One row with no digits is column headings; one row of numbers is data.
  if (rows.length == 1 && !rows.single.contains(RegExp('[0-9]'))) {
    return _empty('Spreadsheet has column headings but no rows',
        'single row "${rows.single}"');
  }
  return null;
}

final _comments = RegExp(r'<!--.*?-->', dotAll: true);
final _tags = RegExp(r'<[^>]*>');

String _visibleText(String markup) => markup
    .replaceAll(_tags, ' ')
    .replaceAll(RegExp(r'&(nbsp|#160|#xa0);', caseSensitive: false), ' ')
    .trim();

Hit? _html(String text) {
  final body = text.replaceAll(_comments, '').replaceAll(
      RegExp(r'<(head|script|style|template)\b.*?</\1\s*>',
          dotAll: true, caseSensitive: false),
      '');
  final hasMedia = RegExp(
          r'<(img|video|audio|iframe|svg|canvas|object|embed|picture|input|'
          r'textarea|select|button|frame)\b',
          caseSensitive: false)
      .hasMatch(body);
  if (hasMedia || _visibleText(body).isNotEmpty) return null;
  return _empty('Web page has no text or pictures',
      'no visible text or media elements outside <head>');
}

Hit? _xml(String text) {
  final body = text
      .replaceAll(_comments, '')
      .replaceAll(RegExp(r'<\?.*?\?>', dotAll: true), '')
      .replaceAll(RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false), '');
  final elements = RegExp(r'<[A-Za-z_]').allMatches(body).length;
  if (elements <= 1 && _visibleText(body).isEmpty) {
    return _empty('Contains no data, only an empty outer tag',
        '$elements elements, no text');
  }
  return null;
}

Hit? _svg(String text) {
  if (!text.contains(RegExp(r'<svg\b', caseSensitive: false))) {
    return const Hit(DeepRule.u05WrongContent, Confidence.certain,
        'Contents are not a valid SVG drawing', 'no <svg> element');
  }
  final draws = RegExp(
          r'<(path|rect|circle|ellipse|line|polyline|polygon|text|image|use)\b',
          caseSensitive: false)
      .hasMatch(text);
  return draws
      ? null
      : _empty('Drawing is empty', 'no shape, text or image elements');
}

Hit? _vcard(String text) {
  const details = {
    'FN', 'N', 'TEL', 'EMAIL', 'ADR', 'ORG', 'NOTE', 'URL', 'PHOTO', //
  };
  for (final line in const LineSplitter().convert(text)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final name = line.substring(0, colon).split(';').first.toUpperCase();
    final value = line.substring(colon + 1).replaceAll(RegExp(r'[;\s]'), '');
    if (details.contains(name.split('.').last) && value.isNotEmpty) {
      return null;
    }
  }
  return _empty('Contact file has no contact details',
      'no FN/N/TEL/EMAIL/ADR/ORG/NOTE/URL/PHOTO values');
}

Hit? _calendar(String text) =>
    RegExp(r'^BEGIN:(VEVENT|VTODO|VJOURNAL|VFREEBUSY)',
                multiLine: true, caseSensitive: false)
            .hasMatch(text)
        ? null
        : _empty('Calendar file has no events', 'no VEVENT/VTODO/VJOURNAL');
