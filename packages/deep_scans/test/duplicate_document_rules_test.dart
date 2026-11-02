import 'dart:convert';
import 'dart:typed_data';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:image/image.dart' as img;
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

import 'support/fake_device.dart';

/// Rule behaviour on small in-memory documents. The full scenarios are
/// checked against the generated test area in
/// duplicate_document_test_area_test.dart.
void main() {
  const rules = DuplicateDocumentRules();
  final paragraphs = [
    'Northgate handled eighteen thousand shipments this quarter across every lane.',
    'Cold storage occupancy averaged eighty seven percent and peaked in September.',
    'Claims for damaged goods fell, mostly from pallets wrapped too loosely.',
  ];
  final words = wordsOf(paragraphs.join(' '));

  group('Reading documents', () {
    test('PDF text comes out the same compressed or not', () {
      for (final compress in [true, false]) {
        final c = readDocument(
            pdfDocument(pages: [paragraphs], compress: compress), 'pdf', rules);
        expect(c.format, DocumentFormat.pdf);
        expect(c.words, words, reason: 'compress: $compress');
        expect(c.pageCount, 1);
      }
    });

    test('PDF content key ignores producer, ids and dates', () {
      String? key(String producer, String id, DateTime created,
              {bool compress = true}) =>
          readDocument(
                  pdfDocument(
                      pages: [paragraphs],
                      producer: producer,
                      id: id,
                      created: created,
                      compress: compress),
                  'pdf',
                  rules)
              .contentKey;
      final a = key('A', '00' * 16, DateTime(2026, 1, 1));
      expect(key('B', 'ff' * 16, DateTime(2026, 5, 5)), a);
      expect(key('B', 'ff' * 16, DateTime(2026, 5, 5), compress: false), a);
      expect(
          readDocument(
                  pdfDocument(pages: [paragraphs.sublist(1)]), 'pdf', rules)
              .contentKey,
          isNot(a));
    });

    test('TJ arrays: large gaps are spaces, kerning is not', () {
      expect(wordsOf(pdfContentText('BT [(Hel) -20 (lo) -400 (world)] TJ ET')),
          ['hello', 'world']);
      expect(
          pdfContentText(r'BT (a \(b\) \\ c\101) Tj ET').trim(), r'a (b) \ cA');
    });

    test('text stored as glyph numbers is not used', () {
      final c = readDocument(
          pdfDocument(pages: [paragraphs], glyphCodes: true), 'pdf', rules);
      expect(c.words, isEmpty);
      expect(c.noTextReason, contains('font codes'));
      expect(c.contentKey, isNotNull);
    });

    test('Word: text survives split runs; key ignores metadata parts', () {
      final plain = readDocument(docxDocument(paragraphs), 'docx', rules);
      final resaved = readDocument(
          docxDocument(paragraphs,
              saved: DateTime(2026, 6, 1),
              zipTime: DateTime(2026, 6, 2),
              level: 9),
          'docx',
          rules);
      final rewritten = readDocument(
          docxDocument(paragraphs, splitRuns: true, revisionIds: '00AB'),
          'docx',
          rules);
      expect(plain.format, DocumentFormat.officePackage);
      expect(plain.words, words);
      expect(resaved.contentKey, plain.contentKey);
      expect(rewritten.words, words);
      expect(rewritten.contentKey, isNot(plain.contentKey));
    });

    test('a plain ZIP archive is not an office document', () {
      final c = readDocument(zipArchive({'a.txt': 'hello'}), 'zip', rules);
      expect(c.format, DocumentFormat.binary);
    });

    test('text key ignores BOM, line ends and trailing spaces', () {
      final a = readDocument(utf8.encode('one\ntwo'), 'txt', rules);
      final b = readDocument(
          Uint8List.fromList(
              [0xEF, 0xBB, 0xBF, ...utf8.encode('one  \r\ntwo\r\n\r\n')]),
          'txt',
          rules);
      expect(b.contentKey, a.contentKey);
    });

    test('scanned PDFs expose one JPEG per page', () {
      final page = encodeJpeg(documentPage('NOTE', 'REF-1', ['1 x thing']), 70);
      final c = readDocument(pdfDocument(scans: [page, page]), 'pdf', rules);
      expect(c.isScan, isTrue);
      expect(c.scanPages, hasLength(2));
      expect(c.scanPages.first, page);
    });
  });

  group('Similarity helpers', () {
    test('names: copy and version markers are ignored', () {
      expect(nameStem('Shipping manifest FINAL v3 (1).docx'),
          {'shipping', 'manifest'});
      expect(namesRelated('Report.docx', 'Copy of Report final.pdf'), isTrue);
      expect(namesRelated('Lease - Smith.docx', 'Lease - Jones.docx'), isFalse);
      expect(namesRelated('Invoice_0042.pdf', 'Invoice_0043.pdf'), isFalse);
    });

    test('one changed word in 300 keeps shingle similarity above 0.95', () {
      final a = [for (var i = 0; i < 300; i++) 'w$i'];
      final b = [...a]..[150] = 'changed';
      expect(jaccard(shingles(a, 5), shingles(b, 5)), greaterThan(0.95));
    });
  });

  group('Rules', () {
    Future<DuplicateDocumentResult> scan(Map<String, List<int>> files,
        {DuplicateDocumentRules rules = const DuplicateDocumentRules(),
        Set<String> unreadable = const {}}) {
      final device = FakeDevice(files);
      device.memory.unreadable.addAll(unreadable);
      return DuplicateDocumentScan(device: device, rules: rules).run();
    }

    Map<String, String> roles(DuplicateDocumentResult r) => {
          for (final g in r.groups)
            for (final m in g.members) m.item.id: m.rule?.code ?? 'keep'
        };

    final pdf = pdfDocument(pages: [paragraphs]);
    final resavedPdf = pdfDocument(
        pages: [paragraphs], producer: 'Other', id: 'ab' * 16, compress: false);
    final docx = docxDocument(paragraphs);

    test('F01 identical, F02 re-saved, F03 same text across formats', () async {
      final r = await scan({
        '/p/Documents/report.pdf': pdf,
        '/p/Download/report.pdf': pdf,
        '/p/WhatsApp/report.pdf': resavedPdf,
        '/p/Documents/report.docx': docx,
      });
      expect(r.groups, hasLength(1));
      expect(roles(r), {
        '/p/Documents/report.docx': 'keep',
        '/p/Documents/report.pdf': 'F03',
        '/p/Download/report.pdf': 'F03',
        '/p/WhatsApp/report.pdf': 'F03',
      });
      final pdfs = await scan({
        '/p/Documents/report.pdf': pdf,
        '/p/Download/report.pdf': pdf,
        '/p/WhatsApp/report.pdf': resavedPdf,
      });
      expect(roles(pdfs), {
        '/p/Documents/report.pdf': 'keep',
        '/p/Download/report.pdf': 'F01',
        '/p/WhatsApp/report.pdf': 'F02',
      });
      expect(pdfs.groups.single.confidence, Confidence.certain);
    });

    test('F04 needs related names and the same reference numbers', () async {
      final base = [for (var i = 0; i < 80; i++) 'word$i'].join(' ');
      List<int> doc(String text) => docxDocument([text]);
      final r = await scan({
        '/p/Docs/plan.docx': doc('$base order 55120'),
        '/p/Docs/plan final.docx': doc('$base order 55120 extra'),
        '/p/Docs/budget.docx': doc('$base order 55120 more'),
        '/p/Docs/plan November.docx': doc('$base order 55121'),
      });
      expect(r.groups, hasLength(1));
      expect(r.groups.single.members.map((m) => m.item.id).toSet(),
          {'/p/Docs/plan.docx', '/p/Docs/plan final.docx'});
      expect(r.groups.single.duplicates.single.rule,
          DocumentRule.f04EditedVersion);
      final misses = r.analysis.observations
          .where((o) => o.kind == DocumentObservationKind.nearMiss)
          .map((o) => o.detail)
          .join('\n');
      expect(misses, contains('names say different documents'));
      expect(misses, contains('different reference numbers'));
    });

    test('empty, unreadable, tiny, app and image files are never grouped',
        () async {
      final photo = encodeJpeg(documentPage('P', 'R', const []), 80);
      final r = await scan({
        '/p/a.txt': const [],
        '/p/b.txt': const [],
        '/p/locked.pdf': pdf,
        '/p/locked copy.pdf': pdf,
        '/p/ok.txt': utf8.encode('ok'),
        '/p/ok (1).txt': utf8.encode('ok'),
        '/p/Android/data/x/c.json': utf8
            .encode('{"a": 1, "b": [1, 2, 3], "c": "some setting value here"}'),
        '/p/Android/data/y/c.json': utf8
            .encode('{"a": 1, "b": [1, 2, 3], "c": "some setting value here"}'),
        '/p/img.jpg': photo,
        '/p/img (1).jpg': photo,
      }, unreadable: {
        '/p/locked.pdf',
        '/p/locked copy.pdf'
      });
      expect(r.groups, isEmpty);
      final kinds = r.analysis.observations.map((o) => o.kind).toSet();
      expect(
          kinds,
          containsAll([
            DocumentObservationKind.empty,
            DocumentObservationKind.unreadable,
            DocumentObservationKind.tooSmall,
            DocumentObservationKind.systemFile,
          ]));
      expect(r.health.verdicts.map((v) => v.rule.code).toSet(), {'E01', 'U01'});
    });

    test('a cut-off copy is reported as a failed download, not a duplicate',
        () async {
      final r = await scan({
        '/p/Documents/report.pdf': pdf,
        '/p/Download/report (1).pdf': pdf.sublist(0, pdf.length ~/ 2),
      });
      expect(r.groups, isEmpty);
      final partial = r.analysis.observations
          .singleWhere((o) => o.kind == DocumentObservationKind.partialCopy);
      expect(partial.ids,
          ['/p/Download/report (1).pdf', '/p/Documents/report.pdf']);
      expect(partial.rule, 'U06');
    });

    test('keeper prefers the original folder and name', () async {
      final r = await scan({
        '/p/Download/report (1).pdf': pdf,
        '/p/WhatsApp/report.pdf': pdf,
        '/p/Documents/report - Copy.pdf': pdf,
        '/p/Documents/report.pdf': pdf,
      });
      expect(r.groups.single.keeper.item.id, '/p/Documents/report.pdf');
    });

    test('disabled rules and minConfidence drop matches', () async {
      final files = {'/p/a/report.pdf': pdf, '/p/b/report.docx': docx};
      expect((await scan(files)).groups, hasLength(1));
      expect(
          (await scan(files,
                  rules: const DuplicateDocumentRules(
                      disabledRules: {DocumentRule.f03SameText})))
              .groups,
          isEmpty);
      expect(
          (await scan(files,
                  rules: const DuplicateDocumentRules(
                      minConfidence: Confidence.certain)))
              .groups,
          isEmpty);
    });

    test('scans: same paper matches, another document in the layout does not',
        () async {
      final note = documentPage('DELIVERY NOTE', 'DN-1',
          ['4 x  Pallet wrap   \$40.00', '2 x  Packing tape   \$9.00']);
      final other = documentPage('DELIVERY NOTE', 'DN-2',
          ['9 x  Euro pallet   \$310.00', '1 x  Strapping band   \$22.00']);
      Uint8List scanOf(img.Image page) =>
          pdfDocument(scans: [encodeJpeg(page, 80)]);
      final r = await scan({
        '/p/Scans/a.pdf': scanOf(rescan(note, 1)),
        '/p/Scans/b.pdf': scanOf(rescan(note, 2, dx: .01, blur: 2)),
        '/p/Scans/c.pdf': scanOf(rescan(other, 3)),
      });
      expect(r.groups.single.members.map((m) => m.item.id).toSet(),
          {'/p/Scans/a.pdf', '/p/Scans/b.pdf'});
      expect(r.groups.single.kind, GroupKind.scans);
      expect(r.groups.single.keeper.item.id, '/p/Scans/a.pdf',
          reason: 'the blurry rescan is not kept');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the detector files groups as findings with a keeper', () async {
      final analyzer = DuplicateDocumentAnalyzer();
      final report = await ScanEngine(
          device: FakeDevice({'/p/a/x.pdf': pdf, '/p/b/x.pdf': pdf}),
          detectors: [analyzer.detector(documentCategoryStandIn)]).scan();
      final f = report.findings.single;
      expect(f.category, documentCategoryStandIn);
      expect(f.keep, isNotNull);
      expect(f.removable, hasLength(1));
    });

    test('refuses to read anything without storage access', () async {
      final device = FakeDevice({'/p/a.pdf': pdf},
          permissions: {ScanPermission.storage: PermissionState.denied});
      await expectLater(DuplicateDocumentScan(device: device).run(),
          throwsA(isA<PermissionDeniedException>()));
      expect(device.memory.accessCount, 0);
    });
  });
}
