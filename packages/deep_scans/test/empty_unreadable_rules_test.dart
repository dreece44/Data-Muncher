import 'package:deep_scans/deep_scans.dart';
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

import 'support/fake_device.dart';

/// Rule behaviour the generated test area can't show (permissions, sizes
/// that lie, hidden Android files) plus edge cases around each rule. The
/// test area itself is checked in test_area_test.dart.
void main() {
  group('Empty rules', () {
    test('E01 skips intentional marker files', () async {
      expect(
          await codes({
            'Pictures/.nomedia': [],
            'repo/.gitkeep': [],
            'app/db.lock': [],
            'Download/song.mp3': [],
          }),
          {
            'Pictures/.nomedia': null,
            'repo/.gitkeep': null,
            'app/db.lock': null,
            'Download/song.mp3': 'E01',
          });
    });

    test('E02 understands UTF-8 and UTF-16 byte-order marks', () async {
      expect(
          await codes({
            'a.txt': [0xEF, 0xBB, 0xBF, 0x20, 0x0A],
            'b.txt': [0xFE, 0xFF, 0x00, 0x20, 0x00, 0x0A],
            'c.txt': [0xFF, 0xFE, 0x41, 0x00], // "A" in UTF-16
          }),
          {'a.txt': 'E02', 'b.txt': 'E02', 'c.txt': null});
    });

    test('E02 / U04 boundary is blankContentMaxBytes', () async {
      final found = await codes({
        'small.bin': List.filled(4096, 0),
        'large.bin': List.filled(4097, 0),
      });
      expect(found, {'small.bin': 'E02', 'large.bin': 'U04'});
    });

    test('E03 tells headings from a single row of data', () async {
      expect(
          await codes({
            'h.csv': ascii('Date,Amount\n'),
            'd.csv': ascii('2026-01-01,5.00\n'),
            // Tabs alone would be blank (E02); quotes make it a table.
            't.tsv': ascii('""\t""\n""\t""\n'),
          }),
          {'h.csv': 'E03', 'd.csv': null, 't.tsv': 'E03'});
    });

    test('E03 JSON: empty values are empty, real values are not', () async {
      expect(
          await codes({
            'a.json': ascii('[]'),
            'b.json': ascii('null'),
            'c.json': ascii('""'),
            'd.json': ascii('0'),
            'e.json': ascii('{"k": []}'),
          }),
          {
            'a.json': 'E03',
            'b.json': 'E03',
            'c.json': 'E03',
            'd.json': null,
            'e.json': null,
          });
    });

    test('E05 video: fragmented MP4 with media in fragments is not empty',
        () async {
      expect(
          await codes({
            'frag.mp4': [
              ...ftyp,
              ...box('moov', List.filled(20, 1)),
              ...box('moof', List.filled(20, 1)),
              ...box('mdat', []),
            ]
          }),
          {'frag.mp4': null});
    });
  });

  group('Unreadable rules', () {
    final pdf = ascii('%PDF-1.4\n1 0 obj << /Type /Page >> endobj\n%%EOF\n');

    test('U01 when the file cannot be opened', () async {
      final result =
          await deepScan({'locked.pdf': pdf}, unreadable: {'locked.pdf'});
      final v = result.verdictFor('locked.pdf')!;
      expect(v.rule, DeepRule.u01CannotOpen);
      expect(v.reason, contains('Permission denied'));
    });

    test('U02 when less data comes back than the listed size', () async {
      final device = FakeDevice({'cloud.pdf': pdf},
          wrap: (m) => InflatedSizeSource(m, 1000));
      final result = await EmptyUnreadableScan(device: device).run();
      expect(result.verdicts.single.rule, DeepRule.u02ShortRead);
    });

    test('U03 Android pending files and every partial extension', () async {
      final found = await codes({
        '.pending-1760000000-IMG_1.jpg': List.filled(50, 7),
        'a.zip.crdownload': List.filled(50, 7),
        'b.iso.part': List.filled(50, 7),
        'c.mkv.!qB': List.filled(50, 7),
        'd.bin.bc!': List.filled(50, 7),
      });
      expect(found.values, everyElement('U03'));
    });

    test('U04 needs the start, middle and end to be blank', () async {
      final mostlyZero = List.filled(200000, 0)..[100000] = 1;
      expect(await codes({'x.bin': mostlyZero}), {'x.bin': null});
    });

    test(
        'U05 a misnamed file in another valid format is checked as that '
        'format', () async {
      // An empty ZIP named .pdf: not "not a PDF", but an empty archive.
      final emptyZip = [0x50, 0x4B, 0x05, 0x06, ...List.filled(18, 0)];
      final result = await deepScan({'scan.pdf': emptyZip, 'a.docx': emptyZip});
      expect(result.verdictFor('scan.pdf')?.rule, DeepRule.e04EmptyArchive);
      expect(
          result.analysis.observations.single.kind, ObservationKind.misnamed);
      // An empty document package is broken, not an empty archive.
      expect(result.verdictFor('a.docx')?.rule, DeepRule.u07Corrupt);
    });

    test('U06 OLE (.doc) files that are not whole sectors', () async {
      final header = List.filled(512, 0)
        ..setAll(0, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        ..setAll(28, [0xFE, 0xFF, 9, 0]);
      final found = await codes({
        'ok.doc': [...header, ...List.filled(1024, 5)],
        'cut.doc': [...header, ...List.filled(1000, 5)],
        'bad.doc': [...header.toList()..[30] = 7, ...List.filled(1024, 5)],
      });
      expect(found, {'ok.doc': null, 'cut.doc': 'U06', 'bad.doc': 'U07'});
    });

    test('U09 UTF-16 without a byte-order mark is not binary', () async {
      final utf16 = [
        for (final c in 'hello world, this is fine'.codeUnits) ...[c, 0]
      ];
      final binary = [...ascii('hello'), 0, 0, 1, 2, 0, ...ascii('world')];
      expect(await codes({'a.txt': utf16, 'b.txt': binary}),
          {'a.txt': null, 'b.txt': 'U09'});
    });
  });

  group('Pipeline', () {
    test('files modified within the grace period are not judged', () async {
      final now = DateTime(2026, 1, 1, 0, 5); // MemoryStorageSource: 00:00
      final result =
          await deepScan({'a.mp4.part': List.filled(10, 1)}, clock: () => now);
      expect(result.verdicts, isEmpty);
      expect(result.analysis.observations.single.kind,
          ObservationKind.recentlyModified);
    });

    test('the grace period only holds back "still being written" rules',
        () async {
      final now = DateTime(2026, 1, 1, 0, 5);
      final result = await deepScan({
        'cut.pdf': ascii('%PDF-1.4\n1 0 obj'), // U06: may still be saving
        'error.pdf': ascii('<html>404</html>'), // U05: won't fix itself
      }, clock: () => now);
      expect(result.verdictFor('cut.pdf'), isNull);
      expect(result.verdictFor('error.pdf')?.rule, DeepRule.u05WrongContent);
    });

    test('minConfidence drops likely findings and records them', () async {
      final result = await deepScan({'h.csv': ascii('Name,Email\n')},
          rules: const EmptyUnreadableRules(minConfidence: Confidence.certain));
      expect(result.verdicts, isEmpty);
      expect(result.analysis.observations.single.detail, startsWith('E03'));
    });

    test('a disabled rule reports the file clean', () async {
      expect(
          await codes({'a.txt': []},
              rules: const EmptyUnreadableRules(
                  disabledRules: {DeepRule.e01ZeroBytes})),
          {'a.txt': null});
    });

    test('refuses to scan, and reads nothing, without storage access',
        () async {
      final device = FakeDevice({'a.txt': []},
          permissions: {ScanPermission.storage: PermissionState.denied});
      await expectLater(EmptyUnreadableScan(device: device).run(),
          throwsA(isA<PermissionDeniedException>()));
      expect(device.memory.accessCount, 0);
    });

    test(
        'drops into ScanEngine next to other detectors; each file is '
        'analysed once', () async {
      final analyzer = EmptyUnreadableAnalyzer();
      final device = FakeDevice({
        'a.txt': [],
        'b.pdf': ascii('<html>nope</html>'),
        'c.txt': ascii('fine'),
      });
      final report = await ScanEngine(device: device, detectors: [
        ...analyzer.detectors(),
        const BlankPhotoDetector(),
      ]).scan();
      expect({
        for (final f in report.findings) f.category: f.items.single.id
      }, {
        WasteCategory.emptyFile: 'a.txt',
        WasteCategory.unreadableFile: 'b.pdf',
      });
      expect(report.categories.values.map((c) => c.state),
          everyElement(CategoryState.completed));
      // 1 listing + one read each for b.pdf and c.txt.
      expect(device.memory.accessCount, 3);
    });
  });
}
