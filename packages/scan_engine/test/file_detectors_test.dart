import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('EmptyFileDetector', () {
    Future<List<Finding>> run(Map<String, List<int>> files) async =>
        (await scan(FakeDevice(files), detectors: [const EmptyFileDetector()]))
            .findings;

    test('reports zero-byte files', () async {
      final findings = await run({'Download/song.mp3': []});
      expect(findings.single.reason, 'File is 0 bytes');
    });

    test('reports small files holding only whitespace or zero bytes', () async {
      final findings = await run({
        'notes/blank.txt': ascii('  \n\t\r\n '),
        'notes/bom.txt': [0xEF, 0xBB, 0xBF, 0x20, 0x0A],
        'notes/zeros.bin': List.filled(100, 0),
      });
      expect(ids(findings),
          {'notes/blank.txt', 'notes/bom.txt', 'notes/zeros.bin'});
    });

    test('ignores files with content, and large files', () async {
      final findings = await run({
        'notes/real.txt': ascii('Call Grandpa'),
        'big/zeros.bin': List.filled(5000, 0), // over blankContentMaxBytes
      });
      expect(findings, isEmpty);
    });

    test('never reports .nomedia marker files', () async {
      expect(await run({'Pictures/.nomedia': []}), isEmpty);
    });
  });

  group('UnreadableFileDetector', () {
    Future<Map<String, String>> reasons(Map<String, List<int>> files,
        {Set<String> unreadable = const {}}) async {
      final device = FakeDevice(files);
      device.memory.unreadable.addAll(unreadable);
      final report =
          await scan(device, detectors: [const UnreadableFileDetector()]);
      return {for (final f in report.findings) f.items.single.id: f.reason};
    }

    final pdf = ascii('%PDF-1.4\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n');

    test('accepts valid files of every checked type', () async {
      final found = await reasons({
        'ok.jpg': jpg(scene(1)),
        'ok.png': png(scene(2)),
        'ok.pdf': pdf,
        'ok.zip': [0x50, 0x4B, 0x05, 0x06, ...List.filled(18, 0)],
        'ok.mp4': [
          ...ftyp,
          ...box('moov', List.filled(20, 1)),
          ...box('mdat', List.filled(50, 2))
        ],
        'ok.txt': ascii('hello world'),
        'ok.mp3': [...ascii('ID3'), ...List.filled(20, 1)],
        'unknown.xyz': List.filled(10, 0), // unknown types aren't judged
      });
      expect(found, isEmpty);
    });

    test('reports files that cannot be opened', () async {
      final found =
          await reasons({'locked.pdf': pdf}, unreadable: {'locked.pdf'});
      expect(found['locked.pdf'], startsWith('File could not be opened'));
    });

    test('reports unfinished downloads', () async {
      final found =
          await reasons({'Report.docx.crdownload': List.filled(100, 7)});
      expect(found.values.single, startsWith('Unfinished download'));
    });

    test('reports contents that do not match the file type', () async {
      final found = await reasons({
        'lease.pdf': ascii('<html>404 Not Found</html>'),
        'photo.jpg': ascii('GIF89a not really a jpeg at all'),
      });
      expect(found['lease.pdf'], 'Contents are not a valid PDF file');
      expect(found['photo.jpg'], 'Contents are not a valid JPEG file');
    });

    test('reports zero-filled files (failed downloads)', () async {
      final found = await reasons({'scan_copy.jpg': List.filled(8000, 0)});
      expect(found.values.single, contains('filled with zero bytes'));
    });

    test('reports truncated PDF, PNG and ZIP files', () async {
      final pngBytes = png(scene(3));
      final found = await reasons({
        'cut.pdf': pdf.sublist(0, pdf.length - 7),
        'cut.png': pngBytes.sublist(0, pngBytes.length - 30),
        'cut.zip': [0x50, 0x4B, 0x03, 0x04, ...List.filled(500, 9)],
      });
      expect(found.keys, containsAll(['cut.pdf', 'cut.png', 'cut.zip']));
      expect(found.values, everyElement(contains('cut off')));
    });

    test('reports videos that are cut off or missing their index', () async {
      final whole = [
        ...ftyp,
        ...box('moov', List.filled(20, 1)),
        ...box('mdat', List.filled(500, 2))
      ];
      final found = await reasons({
        'cut.mp4': whole.sublist(0, whole.length - 100),
        'no_index.mp4': [...ftyp, ...box('mdat', List.filled(500, 2))],
      });
      expect(found['cut.mp4'], contains('cut off'));
      expect(found['no_index.mp4'], contains('missing its index'));
    });

    test('reports text files containing binary data', () async {
      final found = await reasons({
        'notes.txt': [...ascii('hello'), 0, 0, 1, 2, ...ascii('world')]
      });
      expect(found.values.single, contains('binary data'));
    });

    test('reports photos whose image data is damaged', () async {
      final bytes = jpg(scene(4));
      for (var i = 200; i < bytes.length - 2; i++) {
        bytes[i] = (i * 7919) % 256;
      }
      final found = await reasons({'damaged.jpg': bytes});
      expect(found.values.single, contains('damaged'));
    });

    test('leaves tiny blank files to the empty-file detector', () async {
      expect(await reasons({'blank.txt': ascii('   \n')}), isEmpty);
    });
  });
}
