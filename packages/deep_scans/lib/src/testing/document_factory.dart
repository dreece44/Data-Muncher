import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

/// Synthetic documents for the duplicate-document test area and tests:
/// PDFs (text or scanned pages), Word documents, and photos of paper pages,
/// each of which can be re-saved, re-encoded or re-scanned in controlled
/// ways.

/// A PDF with one page per entry in [pages] (lines of text), or one
/// full-page scanned image per entry in [scans] (JPEG data, drawn at
/// [scanWidth]×[scanHeight] pixels).
///
/// [compress] stores page contents Flate-compressed. [producer], [id] and
/// [created] are the metadata a re-save changes. [glyphCodes] writes the
/// text as hex glyph numbers, as PDFs with embedded CID fonts do, so it
/// can't be extracted.
Uint8List pdfDocument({
  List<List<String>> pages = const [],
  List<Uint8List> scans = const [],
  int scanWidth = 850,
  int scanHeight = 1100,
  bool compress = true,
  String producer = 'DataMuncher Test PDF 1.0',
  String id = '00112233445566778899aabbccddeeff',
  DateTime? created,
  bool glyphCodes = false,
}) {
  final objects = <List<int>>[];
  int add(List<int> body) {
    objects.add(body);
    return objects.length;
  }

  List<int> ascii(String s) => latin1.encode(s);
  List<int> stream(String dict, List<int> data, {bool flate = false}) {
    final body = flate ? ZLibEncoder().encodeBytes(data) : data;
    return [
      ...ascii('<< $dict${flate ? ' /Filter /FlateDecode' : ''} '
          '/Length ${body.length} >>\nstream\n'),
      ...body,
      ...ascii('\nendstream'),
    ];
  }

  final catalog = add(const []);
  final pagesObj = add(const []);
  final font =
      add(ascii('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'));
  final kids = <int>[];
  final pageCount = scans.isNotEmpty ? scans.length : pages.length;
  for (var i = 0; i < pageCount; i++) {
    final String content;
    var resources = '/Font << /F1 $font 0 R >>';
    if (scans.isNotEmpty) {
      final image = add(stream(
          '/Type /XObject /Subtype /Image /Width $scanWidth /Height '
          '$scanHeight /ColorSpace /DeviceRGB /BitsPerComponent 8 '
          '/Filter /DCTDecode',
          scans[i]));
      resources = '/XObject << /Im1 $image 0 R >>';
      content = 'q 612 0 0 792 0 0 cm /Im1 Do Q';
    } else {
      final text = StringBuffer('BT /F1 11 Tf 14 TL 72 740 Td\n');
      for (final line in pages[i]) {
        text.writeln(glyphCodes
            ? '<${_glyphHex(line)}> Tj T*'
            : '(${_escape(line)}) Tj T*');
      }
      text.write('ET');
      content = text.toString();
    }
    final contents = add(stream('', ascii(content), flate: compress));
    kids.add(add(ascii('<< /Type /Page /Parent $pagesObj 0 R /MediaBox '
        '[0 0 612 792] /Resources << $resources >> /Contents $contents 0 R >>')));
  }
  objects[catalog - 1] = ascii('<< /Type /Catalog /Pages $pagesObj 0 R >>');
  objects[pagesObj - 1] = ascii('<< /Type /Pages /Kids '
      '[${kids.map((k) => '$k 0 R').join(' ')}] /Count ${kids.length} >>');
  final c = created ?? DateTime(2026, 9, 1, 9);
  String two(int v) => v.toString().padLeft(2, '0');
  final info = add(ascii('<< /Producer (${_escape(producer)}) /CreationDate '
      '(D:${c.year}${two(c.month)}${two(c.day)}${two(c.hour)}${two(c.minute)}'
      '00) >>'));

  final out = BytesBuilder()..add(ascii('%PDF-1.7\n%\xE2\xE3\xCF\xD3\n'));
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out
      ..add(ascii('${i + 1} 0 obj\n'))
      ..add(objects[i])
      ..add(ascii('\nendobj\n'));
  }
  final xref = out.length;
  out.add(ascii('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n'));
  for (final o in offsets) {
    out.add(ascii('${o.toString().padLeft(10, '0')} 00000 n \n'));
  }
  out.add(ascii('trailer\n<< /Size ${objects.length + 1} /Root $catalog 0 R '
      '/Info $info 0 R /ID [<$id> <$id>] >>\nstartxref\n$xref\n%%EOF\n'));
  return out.toBytes();
}

String _escape(String s) =>
    s.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');

/// Glyph numbers as an embedded CID font stores them: unrelated to the
/// character codes.
String _glyphHex(String s) => [
      for (final c in s.codeUnits)
        ((c * 7 + 3) & 0x3FF).toRadixString(16).padLeft(4, '0')
    ].join();

/// A Word document (.docx) with [paragraphs] of text.
///
/// [saved] is the "last modified" date stored inside it, [zipTime] the
/// timestamp on its ZIP entries and [level] the compression level: what
/// changes when the same document is saved again or passed through another
/// app. [revisionIds] adds the per-save revision marks Word writes around
/// edited runs (changes the XML, not the text). [splitRuns] stores each
/// word in its own text run, as Word does after spell-checking.
Uint8List docxDocument(
  List<String> paragraphs, {
  DateTime? saved,
  DateTime? zipTime,
  int level = 6,
  String? revisionIds,
  bool splitRuns = false,
}) {
  final s = saved ?? DateTime(2026, 9, 1, 9);
  final rsid = revisionIds == null ? '' : ' w:rsidR="$revisionIds"';
  String run(String text) =>
      '<w:r><w:t xml:space="preserve">${_xml(text)}</w:t></w:r>';
  final body = [
    for (final para in paragraphs)
      '<w:p$rsid>${splitRuns ? para.split(' ').map((w) => run('$w ')).join() : run(para)}</w:p>'
  ].join();
  final parts = {
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>',
    'word/document.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body>$body</w:body></w:document>',
    'docProps/core.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dcterms="http://purl.org/dc/terms/">'
        '<dcterms:modified>${s.toIso8601String()}Z</dcterms:modified>'
        '</cp:coreProperties>',
    'docProps/app.xml': '<?xml version="1.0" encoding="UTF-8"?>'
        '<Properties><TotalTime>${s.minute + 3}</TotalTime></Properties>',
  };
  final archive = Archive();
  for (final e in parts.entries) {
    archive.addFile(ArchiveFile.string(e.key, e.value)
      ..lastModTime = (zipTime ?? s).millisecondsSinceEpoch ~/ 1000);
  }
  return ZipEncoder()
      .encodeBytes(archive, level: level, modified: zipTime ?? s);
}

String _xml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// A plain ZIP archive of text files.
Uint8List zipArchive(Map<String, String> files, {DateTime? zipTime}) {
  final archive = Archive();
  final t = zipTime ?? DateTime(2026, 9, 1, 9);
  for (final e in files.entries) {
    archive.addFile(ArchiveFile.string(e.key, e.value)
      ..lastModTime = t.millisecondsSinceEpoch ~/ 1000);
  }
  return ZipEncoder().encodeBytes(archive, modified: t);
}

/// A photo of a printed page (a delivery note, an invoice) filling the
/// frame, as a scanner app saves it: white paper, a heading, a reference
/// line and a table of [items]. Different items give a different document
/// in the same layout.
img.Image documentPage(String heading, String reference, List<String> items,
    {int width = 850, int height = 1100}) {
  final im = img.Image(width: width, height: height);
  img.fill(im, color: img.ColorRgb8(250, 250, 246));
  final ink = img.ColorRgb8(25, 25, 30);
  img.drawString(im, heading, font: img.arial48, x: 60, y: 50, color: ink);
  img.drawString(im, reference, font: img.arial24, x: 60, y: 130, color: ink);
  img.drawString(im, 'Northgate Logistics, 41 Harbor Rd',
      font: img.arial24, x: 60, y: 170, color: ink);
  img.fillRect(im, x1: 60, y1: 230, x2: width - 60, y2: 234, color: ink);
  var y = 260;
  for (final item in items) {
    img.drawString(im, item, font: img.arial24, x: 70, y: y, color: ink);
    img.drawLine(im,
        x1: 60,
        y1: y + 38,
        x2: width - 60,
        y2: y + 38,
        color: img.ColorRgb8(170, 170, 170));
    y += 52;
  }
  img.fillRect(im,
      x1: 60, y1: height - 160, x2: 400, y2: height - 157, color: ink);
  img.drawString(im, 'Received by',
      font: img.arial24, x: 60, y: height - 145, color: ink);
  return im;
}

/// The same page scanned again: shifted by ([dx], [dy]) of its size,
/// lit differently, with sensor noise, and optionally out of focus.
img.Image rescan(img.Image page, int seed,
    {double dx = 0,
    double dy = 0,
    int brightness = 0,
    int noise = 4,
    int blur = 0}) {
  final r = Random(seed);
  final out = img.Image(width: page.width, height: page.height);
  img.fill(out, color: img.ColorRgb8(250, 250, 246));
  img.compositeImage(out, page,
      dstX: (dx * page.width).round(), dstY: (dy * page.height).round());
  for (final px in out) {
    int v(num c) => (c + brightness + r.nextInt(2 * noise + 1) - noise)
        .round()
        .clamp(0, 255);
    px
      ..r = v(px.r)
      ..g = v(px.g)
      ..b = v(px.b);
  }
  return blur > 0 ? img.gaussianBlur(out, radius: blur) : out;
}

/// Bytes that look like audio data: a FLAC signature and noise.
Uint8List flacLike(int length, int seed) {
  final r = Random(seed);
  return Uint8List.fromList([
    ...'fLaC'.codeUnits,
    for (var i = 4; i < length; i++) r.nextInt(256),
  ]);
}
