import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../empty_unreadable/bytes.dart';
import '../empty_unreadable/scan.dart';

/// A generated test area: [filesDir] is the folder to scan, [manifest] the
/// `expected.json` listing what each file should get.
final class TestArea {
  const TestArea(this.root, this.cases);

  final String root;
  final List<ExpectedCase> cases;

  String get filesDir => p.join(root, 'files');
  String get manifest => p.join(root, 'expected.json');
}

/// Marker that says a folder was made by this tool, so it's safe to replace.
const testAreaMarker = '.datamuncher_test_area';

/// When every planted file was "last modified" (well outside the grace
/// period for files still being written).
final plantedModified = DateTime(2026, 9, 1, 12);

/// Builds the empty & unreadable test area in [root]:
///
/// ```
/// root/
///   expected.json      what each file should be flagged as
///   files/empty/       E-rule examples
///   files/unreadable/  U-rule examples
///   files/healthy/     look-alikes that must NOT be flagged
/// ```
///
/// Refuses to overwrite a non-empty folder it didn't make.
Future<TestArea> buildEmptyUnreadableTestArea(String root,
    {DateTime? now}) async {
  root = p.absolute(root);
  final dir = Directory(root);
  if (dir.existsSync() && dir.listSync().isNotEmpty) {
    if (!File(p.join(root, testAreaMarker)).existsSync()) {
      throw StateError('$root already exists and was not made by this tool');
    }
    await _makeWritable(root);
    dir.deleteSync(recursive: true);
  }
  final files = p.join(root, 'files');
  Directory(files).createSync(recursive: true);
  File(p.join(root, testAreaMarker)).writeAsStringSync('');

  final cases = <ExpectedCase>[];
  final b = _Builder(files, cases);
  _plant(b);

  // Something still downloading: exempt now, U03 once it's been left alone.
  now ??= DateTime.now();
  const grace = Duration(minutes: 10);
  final active = b.write(
      'unreadable/still_downloading.zip.crdownload', _noise(30000, 77), null,
      why: 'Download in progress (just modified): not judged during the '
          '10-minute grace period, U03 after it',
      modified: now);
  cases[cases.length - 1] = ExpectedCase(
      path: active,
      rule: null,
      why: cases.last.why,
      ruleAfterGrace: 'U03',
      graceEnds: now.add(grace));

  // U01 needs a file the scanner isn't allowed to open; only possible where
  // chmod works and we aren't root.
  final locked = b.write(
      'unreadable/locked_statement.pdf', _pdf(['Statement']), 'U01',
      why: 'No permission to read it');
  if (!await _lock(p.join(files, locked))) {
    File(p.join(files, locked)).deleteSync();
    cases.removeLast();
  }

  File(p.join(root, 'expected.json'))
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'scan': 'empty_unreadable',
    'rulesetVersion': emptyUnreadableRulesetVersion,
    'scanFolder': 'files',
    'generatedAt': now.toIso8601String(),
    'cases': [for (final c in cases) c.toJson()],
  }));
  return TestArea(root, cases);
}

/// Reads a test area's `expected.json`.
List<ExpectedCase> readExpectedCases(String manifestPath) {
  final json =
      jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, Object?>;
  return [
    for (final c in json['cases']! as List)
      ExpectedCase.fromJson(c as Map<String, Object?>)
  ];
}

final class _Builder {
  _Builder(this.root, this.cases);
  final String root;
  final List<ExpectedCase> cases;

  String write(String path, List<int> bytes, String? expect,
      {required String why, String? confidence, DateTime? modified}) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    file.setLastModifiedSync(modified ?? plantedModified);
    cases.add(ExpectedCase(
        path: path, rule: expect, confidence: confidence, why: why));
    return path;
  }

  void text(String path, String content, String? expect,
          {required String why, String? confidence}) =>
      write(path, utf8.encode(content), expect,
          why: why, confidence: confidence);
}

void _plant(_Builder b) {
  // ===== Empty ==============================================================
  b.write('empty/Invoice_0042.pdf', [], 'E01',
      why: 'Failed download left a 0-byte file (Ethan scenario)');
  b.write('empty/podcast_episode_12.mp3', [], 'E01',
      why: 'Failed download left a 0-byte file');
  b.write('empty/New Text Document.txt', [], 'E01',
      why: 'Note created and never written in');

  b.text('empty/blank_note.txt', '   \n\t\r\n  \n', 'E02',
      why: 'Only whitespace');
  b.write('empty/utf16_blank_note.txt',
      [0xFF, 0xFE, 0x20, 0x00, 0x0A, 0x00, 0x20, 0x00], 'E02',
      why: 'UTF-16 text that is only whitespace (mass scan misses this)');
  b.write('empty/zero_padding.dat', List.filled(100, 0), 'E02',
      why: 'Small file of zero bytes');
  b.text('empty/long_blank_page.txt', '${' ' * 70}\n' * 120, 'E02',
      why: '8 KB of whitespace: over the small-file limit, caught by the '
          'text check');

  b.text('empty/export_2026-09-30.json', '{ }\n', 'E03',
      confidence: 'likely', why: 'Export with no data in it');
  b.text('empty/contacts_export.csv', 'Name,Phone,Email\r\n', 'E03',
      confidence: 'likely', why: 'Column headings only, no rows');
  b.text('empty/blank_sheet.csv', ',,,\n,,,\n,,,\n', 'E03',
      confidence: 'certain', why: 'Every cell empty');
  b.text(
      'empty/saved_page.html',
      '<!DOCTYPE html><html><head><title>Loading…</title>'
          '<script>var x = 1;</script></head><body>\n  <div></div>\n'
          '</body></html>',
      'E03',
      confidence: 'likely',
      why: 'Web page with nothing visible');
  b.text('empty/backup_settings.xml',
      '<?xml version="1.0" encoding="UTF-8"?>\n<settings/>\n', 'E03',
      confidence: 'likely', why: 'XML with only an empty root element');
  b.text(
      'empty/drawing.svg',
      '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">'
          '</svg>',
      'E03',
      confidence: 'likely',
      why: 'Drawing with no shapes');
  b.text('empty/shared_contact.vcf',
      'BEGIN:VCARD\r\nVERSION:3.0\r\nN:;;;;\r\nEND:VCARD\r\n', 'E03',
      confidence: 'likely', why: 'Contact card with no details');
  b.text(
      'empty/invite.ics',
      'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//DataMuncher//EN\r\n'
          'END:VCALENDAR\r\n',
      'E03',
      confidence: 'likely',
      why: 'Calendar with no events');
  b.text('empty/movie.srt', 'Subtitles by nobody\n\n', 'E03',
      confidence: 'likely', why: 'Subtitle file without any timed lines');

  b.write('empty/empty_archive.zip', _zip({}), 'E04',
      confidence: 'certain', why: 'ZIP with no entries');
  b.write('empty/folders_only.zip',
      _zip({'photos/': [], 'notes/': [], 'notes/todo.txt': []}), 'E04',
      confidence: 'likely', why: 'ZIP holding only folders and empty files');
  b.write('empty/logs.gz', gzip.encode([]), 'E04', why: 'gzip of nothing');
  b.write('empty/empty.7z', _sevenZip(0, 0, 0), 'E04',
      why: '7-Zip archive with no files');

  b.write('empty/silent_recording.wav', _wav(0), 'E05',
      why: 'WAV header with no audio');
  b.write(
      'empty/VID_20260921_090000.mp4',
      [..._ftyp, ..._box('moov', List.filled(100, 1)), ..._box('mdat', [])],
      'E05',
      why: 'Video recording that stopped before any frames were saved');
  b.write('empty/song_tag_only.mp3', _id3('Track 01'), 'E05',
      why: 'MP3 that is only a song-title tag');
  b.write('empty/scan_no_pages.pdf', _pdf([]), 'E05',
      confidence: 'likely', why: 'PDF with zero pages');

  // ===== Unreadable =========================================================
  b.write('unreadable/Report.docx.crdownload', _noise(40000, 1), 'U03',
      why: 'Chrome partial download');
  b.write('unreadable/holiday_movie.mp4.part', _noise(40000, 2), 'U03',
      why: 'Firefox partial download');
  b.write('unreadable/episode_01.mkv.!ut', _noise(20000, 3), 'U03',
      why: 'uTorrent partial download (mass scan misses this)');

  b.write('unreadable/scan_copy.jpg', List.filled(8000, 0), 'U04',
      why: 'Photo that is all zero bytes');
  b.write('unreadable/backup_data.bin', List.filled(64 * 1024, 0), 'U04',
      confidence: 'likely',
      why: 'Unknown type, all zero bytes (mass scan only judges known types)');
  b.write('unreadable/blank_audio.mp3',
      [..._id3('Voice memo'), ...List.filled(20000, 0)], 'U04',
      why: 'MP3 with a valid tag but zeroed audio (mass scan misses this)');

  final photo = _jpg(_scene(1), 90);
  b.text(
      'unreadable/lease_agreement.pdf',
      '<!DOCTYPE html><html><head><title>404 Not Found</title></head>'
          '<body><h1>Not Found</h1></body></html>',
      'U05',
      why: 'A saved error page instead of the PDF');
  b.text('unreadable/contract.docx',
      '{"error":"AccessDenied","message":"Request has expired"}', 'U05',
      why: 'A cloud error message saved under a document name');
  b.write('unreadable/garbage.png', _noise(5000, 4), 'U05',
      why: 'Random bytes with an image name');
  b.write('unreadable/header_wiped.jpg',
      [...List.filled(4096, 0), ...photo.sublist(4096)], 'U05',
      why: 'Photo whose first 4 KB were zeroed');

  final pdf = _pdf(['Invoice #0042', 'Total: \$120.00']);
  b.write(
      'unreadable/invoice_0042 (1).pdf', pdf.sublist(0, pdf.length - 40), 'U06',
      why: 'PDF missing its end');
  final png = _png(_scene(2));
  b.write('unreadable/screenshot_cut.png', png.sublist(0, png.length * 2 ~/ 3),
      'U06',
      why: 'PNG cut off mid-picture');
  final bigPhoto = _jpg(_scene(3, width: 640, height: 480), 92);
  b.write('unreadable/IMG_cut_off.jpg',
      bigPhoto.sublist(0, bigPhoto.length ~/ 2), 'U06',
      confidence: 'likely',
      why: 'JPEG cut off halfway (mass scan misses this '
          'unless the decoder fails)');
  b.write(
      'unreadable/IMG_stalled_download.jpg',
      [
        ...bigPhoto.sublist(0, bigPhoto.length * 6 ~/ 10),
        ...List.filled(bigPhoto.length - bigPhoto.length * 6 ~/ 10, 0)
      ],
      'U06',
      confidence: 'certain',
      why: 'Download reserved the full size and stopped at 60%');
  final zip = _zip({
    'receipts/2026-09-01.txt': utf8.encode('Fuel \$45.10\n' * 200),
    'receipts/2026-09-02.txt': utf8.encode('Lunch \$12.75\n' * 200),
  });
  b.write('unreadable/receipts_backup.zip',
      zip.sublist(0, zip.length * 6 ~/ 10), 'U06',
      why: 'ZIP missing its table of contents');
  b.write('unreadable/voice_memo_cut.wav', _wav(8000).sublist(0, 3000), 'U06',
      why: 'WAV shorter than its header says');
  b.write('unreadable/unfinished_recording.wav', _wav(8000, finalized: false),
      'U06',
      confidence: 'likely',
      why: 'Recorder never wrote the final length (mass scan misses this)');
  b.write(
      'unreadable/voice_note_interrupted.opus', _ogg(finished: false), 'U06',
      confidence: 'likely',
      why: 'Voice note with no end-of-stream marker (mass scan misses this)');
  final video = [
    ..._ftyp,
    ..._box('moov', List.filled(200, 1)),
    ..._box('mdat', _noise(6000, 5))
  ];
  b.write(
      'unreadable/VID_cut_off.mp4', video.sublist(0, video.length - 500), 'U06',
      why: 'Video cut off');
  b.write('unreadable/VID_no_index.mp4',
      [..._ftyp, ..._box('mdat', _noise(6000, 6))], 'U06',
      why: 'Recording interrupted before the index was written');
  final camera = [
    ..._ftyp,
    ..._box('mdat', _noise(12000, 7)),
    ..._box('moov', List.filled(3000, 1))
  ];
  b.write(
      'unreadable/VID_stalled_download.mp4',
      [...camera.sublist(0, camera.length - 4000), ...List.filled(4000, 0)],
      'U06',
      confidence: 'certain',
      why: 'Download stopped; the end of the file is blank');
  final gif = img.encodeGif(_scene(4, width: 120, height: 90));
  b.write('unreadable/reaction_cut.gif', gif.sublist(0, gif.length * 7 ~/ 10),
      'U06',
      confidence: 'likely', why: 'GIF missing its trailer');
  b.write('unreadable/photos_backup.7z',
      _sevenZip(4000, 60, 1).sublist(0, 1500), 'U06',
      why: '7-Zip archive cut off before its index');
  final rtf = _rtf('Dear landlord, the heating is broken again.');
  b.text('unreadable/letter_cut.rtf', rtf.substring(0, rtf.length - 12), 'U06',
      confidence: 'likely', why: 'RTF with unclosed groups');
  b.text('unreadable/app_settings.json',
      '{"theme": "dark", "fontSize": 14, "recent": ["a.pdf", "b.pdf"', 'U06',
      confidence: 'likely', why: 'JSON cut off mid-way');

  final damagedPng = Uint8List.fromList(_png(_scene(5)));
  damagedPng[damagedPng.length ~/ 2] ^= 0xFF;
  b.write('unreadable/screenshot_damaged.png', damagedPng, 'U07',
      why: 'One flipped byte: PNG checksum fails (mass scan only notices if '
          'the decoder fails)');
  b.write('unreadable/zero_size.png', _zeroSizePng(), 'U07',
      why: 'PNG header says 0x0 pixels');
  final brokenZip = Uint8List.fromList(_zip({
    'a.txt': utf8.encode('alpha' * 50),
    'b.txt': utf8.encode('bravo' * 50),
  }));
  final cdAt = lastIndexOf(brokenZip, const [0x50, 0x4B, 0x01, 0x02]);
  brokenZip.setAll(
      indexOf(brokenZip, const [0x50, 0x4B, 0x01, 0x02]), const [0, 0, 0, 0]);
  brokenZip.setAll(cdAt, const [0, 0, 0, 0]);
  b.write('unreadable/broken_index.zip', brokenZip, 'U07',
      why: 'ZIP table of contents damaged');
  b.write('unreadable/not_really.docx',
      _zip({'document.xml': utf8.encode('<doc>hi</doc>')}), 'U07',
      confidence: 'likely',
      why: 'ZIP named .docx without the parts Word needs');
  b.text('unreadable/data_export.json', '{"a": 1,, "b": 2}', 'U07',
      confidence: 'likely', why: 'Malformed JSON');

  final scrambled = Uint8List.fromList(_jpg(_scene(6), 90));
  final sos = indexOf(scrambled, const [0xFF, 0xDA]);
  final r = Random(9);
  for (var i = sos + 20; i < scrambled.length - 2; i++) {
    scrambled[i] = scrambled[i - 1] == 0xFF ? 0 : r.nextInt(256);
  }
  b.write('unreadable/IMG_damaged.jpg', scrambled, 'U08',
      why: 'Markers intact but picture data scrambled');

  b.write(
      'unreadable/notes_binary.txt',
      [
        ...utf8.encode('Shopping: eggs'),
        0,
        0,
        7,
        0,
        3,
        0,
        0,
        1,
        0,
        0,
        ...utf8.encode('milk')
      ],
      'U09',
      why: 'Text with binary data in it');
  b.text('unreadable/converted_notes.txt', 'Caf� r�sum� ' * 20, 'U09',
      confidence: 'likely', why: 'Text damaged by a bad encoding conversion');
  b.write(
      'unreadable/terminal_dump.log',
      [for (var i = 0; i < 400; i++) i % 3 == 0 ? 0x41 + i % 26 : 1 + i % 7],
      'U09',
      confidence: 'likely',
      why: 'Mostly control characters');

  // ===== Healthy (must not be flagged) ======================================
  b.write('healthy/IMG_20260912_101500.jpg', photo, null, why: 'Normal photo');
  b.write('healthy/Screenshot_20260913.png', _png(_scene(7)), null,
      why: 'Normal PNG');
  b.write('healthy/sticker_saved_as.jpg', _png(_scene(8)), null,
      why: 'PNG with a .jpg name: opens fine everywhere (mass scan flags it)');
  b.write(
      'healthy/MVIMG_motion_photo.jpg',
      [
        ...photo,
        ..._ftyp,
        ..._box('moov', List.filled(200, 1)),
        ..._box('mdat', _noise(80000, 8))
      ],
      null,
      why: 'Motion photo: JPEG with an 80 KB video appended');
  b.write('healthy/animation.gif', gif, null, why: 'Normal GIF');
  b.write('healthy/invoice.pdf', pdf, null, why: 'Normal PDF');
  b.write('healthy/receipts_backup.zip', zip, null, why: 'Normal ZIP');
  b.write(
      'healthy/Report.docx',
      _zip({
        '[Content_Types].xml': utf8.encode('<Types/>'),
        '_rels/.rels': utf8.encode('<Relationships/>'),
        'word/document.xml': utf8.encode('<w:document>Q3 report</w:document>'),
      }),
      null,
      why: 'Word document with its required parts');
  b.write('healthy/VID_20260920_183000.mp4', video, null, why: 'Normal video');
  b.write('healthy/VID_camera_layout.mp4', camera, null,
      why: 'Video with its index at the end (how phones record)');
  b.write('healthy/voice_memo.wav', _wav(8000), null, why: 'Normal WAV');
  b.write('healthy/voice_note.opus', _ogg(finished: true), null,
      why: 'Voice note with end-of-stream marker');
  b.write('healthy/song.mp3', [..._id3('Track 02'), ..._mp3Frames(30)], null,
      why: 'MP3 with tag and audio');
  b.write('healthy/photos_backup.7z', _sevenZip(4000, 60, 1), null,
      why: 'Normal 7-Zip archive');
  b.write('healthy/logs.gz', gzip.encode(utf8.encode('started\n' * 100)), null,
      why: 'Normal gzip');
  b.text('healthy/letter.rtf', rtf, null, why: 'Normal RTF');
  b.text('healthy/shopping_list.txt', 'eggs\nmilk\nbread\n', null,
      why: 'Normal note');
  b.write('healthy/old_windows_notes.txt',
      latin1.encode('Café menu — crème brûlée\n'.replaceAll('—', '-')), null,
      why: 'Latin-1 text: not UTF-8, but not damaged');
  b.write(
      'healthy/utf16_no_bom.txt',
      [
        for (final c in 'Meeting notes\r\n'.codeUnits) ...[c, 0]
      ],
      null,
      why: 'UTF-16 without a byte-order mark (mass scan flags it as binary)');
  b.text('healthy/build_output.log',
      '\x1B[32mPASS\x1B[0m test 1\n\x1B[31mFAIL\x1B[0m test 2\n' * 10, null,
      why: 'Coloured terminal log: escape codes are normal');
  b.text('healthy/settings.json', '{"theme": "dark", "fontSize": 14}', null,
      why: 'Normal JSON');
  b.text('healthy/events.json', '{"e": "open"}\n{"e": "close"}\n', null,
      why: 'Line-delimited JSON: not one document, but valid');
  b.text('healthy/contacts.csv', 'Name,Phone\nAda,555-0100\nGrace,555-0101\n',
      null,
      why: 'Normal CSV');
  b.text('healthy/readings.csv', '42,17,99\n', null,
      why: 'One row of numbers is data, not headings');
  b.text('healthy/article.html',
      '<html><body><p>How to bake bread</p></body></html>', null,
      why: 'Web page with text');
  b.text('healthy/gallery.html', '<html><body><img src="a.jpg"></body></html>',
      null,
      why: 'Web page that is only a picture');
  b.text('healthy/backup.xml',
      '<?xml version="1.0"?><items><item>1</item></items>', null,
      why: 'Normal XML');
  b.text('healthy/icon.svg',
      '<svg xmlns="http://www.w3.org/2000/svg"><circle r="5"/></svg>', null,
      why: 'Normal SVG');
  b.text('healthy/contact.vcf',
      'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ada Lovelace\r\nEND:VCARD\r\n', null,
      why: 'Normal contact');
  b.text(
      'healthy/invite.ics',
      'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Dinner\r\nEND:VEVENT\r\n'
          'END:VCALENDAR\r\n',
      null,
      why: 'Normal calendar');
  b.text('healthy/movie.srt', '1\n00:00:01,000 --> 00:00:02,000\nHello\n', null,
      why: 'Normal subtitles');
  b.write('healthy/game_data.dat', _noise(10000, 9), null,
      why: 'Unknown type with content: not judged');
  b.write('healthy/app.lock', [], null,
      why: '0-byte lock file: exists on purpose');
}

// --- File makers ----------------------------------------------------------

img.Image _scene(int seed, {int width = 320, int height = 240}) {
  final r = Random(seed);
  final image = img.Image(width: width, height: height);
  img.Color color() =>
      img.ColorRgb8(r.nextInt(256), r.nextInt(256), r.nextInt(256));
  img.fill(image, color: color());
  for (var i = 0; i < 16; i++) {
    img.fillCircle(image,
        x: r.nextInt(width),
        y: r.nextInt(height),
        radius: 10 + r.nextInt(width ~/ 6),
        color: color());
  }
  return image;
}

Uint8List _jpg(img.Image image, int quality) =>
    img.encodeJpg(image, quality: quality);
Uint8List _png(img.Image image) => img.encodePng(image);

Uint8List _zeroSizePng() {
  final ihdr = [
    ...'IHDR'.codeUnits, 0, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 0, 0, //
  ];
  final iend = 'IEND'.codeUnits;
  List<int> chunk(List<int> typeAndData) => [
        ..._u32be(typeAndData.length - 4),
        ...typeAndData,
        ..._u32be(crc32(typeAndData)),
      ];
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ...chunk(ihdr),
    ...chunk(iend),
  ]);
}

/// Random filler with no 0x00 (so it never looks blank) and no 0xFF (so it
/// can't form JPEG markers by chance).
List<int> _noise(int length, int seed) {
  final r = Random(seed);
  return [for (var i = 0; i < length; i++) 1 + r.nextInt(254)];
}

List<int> _u16le(int v) => [v & 0xFF, v >> 8 & 0xFF];
List<int> _u32le(int v) =>
    [v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF];
List<int> _u32be(int v) =>
    [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];
List<int> _u64le(int v) =>
    [..._u32le(v & 0xFFFFFFFF), ..._u32le(v ~/ 0x100000000)];

/// A minimal PDF with one page per string (none for an empty list), with a
/// correct cross-reference table.
Uint8List _pdf(List<String> pages) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${[
      for (var i = 0; i < pages.length; i++) '${3 + i * 2} 0 R'
    ].join(' ')}] /Count ${pages.length} >>',
    for (var i = 0; i < pages.length; i++) ...[
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
          '/Contents ${4 + i * 2} 0 R >>',
      () {
        final s = 'BT /F1 24 Tf 72 700 Td (${pages[i]}) Tj ET';
        return '<< /Length ${s.length} >>\nstream\n$s\nendstream';
      }(),
    ],
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n');
  return latin1.encode(out.toString());
}

/// A ZIP with every entry stored (uncompressed).
Uint8List _zip(Map<String, List<int>> entries) {
  final out = <int>[];
  final central = <int>[];
  for (final e in entries.entries) {
    final name = utf8.encode(e.key);
    final crc = crc32(e.value);
    final common = [
      ..._u16le(20), ..._u16le(0), ..._u16le(0), // version, flags, stored
      ..._u16le(0), ..._u16le(0x5B21), // time, date
      ..._u32le(crc), ..._u32le(e.value.length), ..._u32le(e.value.length),
      ..._u16le(name.length),
    ];
    central.addAll([
      0x50, 0x4B, 0x01, 0x02, ..._u16le(20), ...common, //
      ..._u16le(0), ..._u16le(0), ..._u16le(0), ..._u16le(0),
      ..._u32le(e.key.endsWith('/') ? 0x10 : 0), ..._u32le(out.length),
      ...name,
    ]);
    out.addAll([0x50, 0x4B, 0x03, 0x04, ...common, ..._u16le(0), ...name]);
    out.addAll(e.value);
  }
  final cdOffset = out.length;
  out
    ..addAll(central)
    ..addAll([
      0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, //
      ..._u16le(entries.length), ..._u16le(entries.length),
      ..._u32le(central.length), ..._u32le(cdOffset), ..._u16le(0),
    ]);
  return Uint8List.fromList(out);
}

/// A 7-Zip file: [packed] bytes of data then a [header]-byte index.
List<int> _sevenZip(int packed, int header, int seed) => [
      0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04, //
      ..._u32le(0), ..._u64le(packed), ..._u64le(header), ..._u32le(0),
      ..._noise(packed + header, seed),
    ];

List<int> _box(String type, List<int> payload) =>
    [..._u32be(8 + payload.length), ...type.codeUnits, ...payload];

final _ftyp = _box('ftyp', 'isom\x00\x00\x02\x00isommp41'.codeUnits);

/// A 16-bit mono WAV with [dataBytes] of audio. Unfinalized recordings
/// still say 0 bytes in their headers.
List<int> _wav(int dataBytes, {bool finalized = true}) {
  final data = [for (var i = 0; i < dataBytes; i++) (i * 37) % 251 + 1];
  return [
    ...'RIFF'.codeUnits,
    ..._u32le(finalized ? 36 + dataBytes : 0),
    ...'WAVE'.codeUnits,
    ...'fmt '.codeUnits,
    ..._u32le(16),
    ..._u16le(1),
    ..._u16le(1),
    ..._u32le(8000),
    ..._u32le(16000),
    ..._u16le(2),
    ..._u16le(16),
    ...'data'.codeUnits,
    ..._u32le(finalized ? dataBytes : 0),
    ...data,
  ];
}

/// An ID3v2.3 tag holding just a title.
List<int> _id3(String title) {
  final frame = [
    ...'TIT2'.codeUnits, ..._u32be(title.length + 1), 0, 0, 0, //
    ...latin1.encode(title),
  ];
  final n = frame.length;
  return [
    ...'ID3'.codeUnits, 3, 0, 0, //
    n >> 21 & 0x7F, n >> 14 & 0x7F, n >> 7 & 0x7F, n & 0x7F,
    ...frame,
  ];
}

/// MPEG-1 Layer III frames (128 kbit/s, 44.1 kHz) with noise as audio.
List<int> _mp3Frames(int count) => [
      for (var i = 0; i < count; i++) ...[
        0xFF, 0xFB, 0x90, 0x64, ..._noise(413, i + 100), //
      ]
    ];

/// An Ogg stream of three pages; [finished] sets end-of-stream on the last.
/// Page checksums use Ogg's own CRC so the pages are well-formed.
List<int> _ogg({required bool finished}) {
  final out = <int>[];
  for (var page = 0; page < 3; page++) {
    final payload = _noise(200, page + 50);
    final type = page == 0 ? 0x02 : (page == 2 && finished ? 0x04 : 0x00);
    final bytes = [
      ...'OggS'.codeUnits, 0, type, ..._u64le(page * 960), //
      ..._u32le(0x1234), ..._u32le(page), ..._u32le(0),
      1, payload.length, ...payload,
    ];
    final crc = _oggCrc(bytes);
    bytes.setAll(22, _u32le(crc));
    out.addAll(bytes);
  }
  return out;
}

int _oggCrc(List<int> bytes) {
  var crc = 0;
  for (final b in bytes) {
    crc ^= b << 24;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ 0x04C11DB7 : crc << 1;
      crc &= 0xFFFFFFFF;
    }
  }
  return crc;
}

String _rtf(String body) =>
    r'{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}{\colortbl;\red0\green0\blue0;}'
    '\n\\f0\\fs24 $body\\par\n'
    r'{\i Sent from my phone}\par'
    '\n}';

/// Removes read permission so the scanner can't open the file. Returns false
/// where that isn't possible (Windows, or running as root).
Future<bool> _lock(String path) async {
  if (Platform.isWindows) return false;
  final result = await Process.run('chmod', ['000', path]);
  if (result.exitCode != 0) return false;
  try {
    File(path).openSync().closeSync();
    await Process.run('chmod', ['644', path]); // Still readable: root.
    return false;
  } on FileSystemException {
    return true;
  }
}

Future<void> _makeWritable(String root) async {
  if (!Platform.isWindows) await Process.run('chmod', ['-R', 'u+rw', root]);
}
