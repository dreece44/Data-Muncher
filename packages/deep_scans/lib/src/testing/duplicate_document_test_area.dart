import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../duplicate_documents/scan.dart';
import '../duplicate_photos/scan.dart' show ExpectedGroup, ExpectedSingle;
import 'document_factory.dart';
import 'empty_unreadable_test_area.dart' show plantedModified, testAreaMarker;
import 'photo_factory.dart' show receiptPhoto;

/// A generated duplicate-document test area: [filesDir] is the folder to
/// scan, [manifest] the `expected.json` with the groups, the look-alikes
/// that must stay apart, and the empty/unreadable documents that must be
/// left out.
final class DocumentTestArea {
  const DocumentTestArea(this.root, this.groups, this.singles, this.health);

  final String root;
  final List<ExpectedGroup> groups;
  final List<ExpectedSingle> singles;
  final List<ExpectedHealth> health;

  String get filesDir => p.join(root, 'files');
  String get manifest => p.join(root, 'expected.json');
  int get fileCount =>
      groups.fold(0, (n, g) => n + g.paths.length) +
      singles.length +
      health.length;
}

/// Builds the duplicate document test area in [root]: a fake phone's
/// Documents, Download and messaging folders with planted duplicate groups
/// (one per scenario in DAT-3 and the project doc), look-alikes that must
/// stay apart, and empty, unreadable and half-downloaded documents that the
/// scan must leave to the empty & unreadable scan.
///
/// [now] is when the one "still downloading" file was last modified.
/// Refuses to overwrite a non-empty folder it didn't make.
Future<DocumentTestArea> buildDuplicateDocumentTestArea(String root,
    {DateTime? now}) async {
  root = p.absolute(root);
  final dir = Directory(root);
  if (dir.existsSync() && dir.listSync().isNotEmpty) {
    if (!File(p.join(root, testAreaMarker)).existsSync()) {
      throw StateError('$root already exists and was not made by this tool');
    }
    dir.deleteSync(recursive: true);
  }
  Directory(p.join(root, 'files')).createSync(recursive: true);
  File(p.join(root, testAreaMarker)).writeAsStringSync('');

  final b = _Builder(p.join(root, 'files'));
  _plant(b, now ?? DateTime.now());

  File(p.join(root, 'expected.json'))
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'scan': 'duplicate_documents',
    'rulesetVersion': duplicateDocumentRulesetVersion,
    'scanFolder': 'files',
    'groups': [for (final g in b.groups) g.toJson()],
    'singles': [for (final s in b.singles) s.toJson()],
    'emptyOrUnreadable': [for (final h in b.health) h.toJson()],
  }));
  return DocumentTestArea(root, b.groups, b.singles, b.health);
}

/// Reads a duplicate document test area's `expected.json`.
(List<ExpectedGroup>, List<ExpectedSingle>, List<ExpectedHealth>)
    readExpectedDocuments(String manifestPath) {
  final json =
      jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, Object?>;
  return (
    [
      for (final g in json['groups']! as List)
        ExpectedGroup.fromJson(g as Map<String, Object?>)
    ],
    [
      for (final s in json['singles']! as List)
        ExpectedSingle.fromJson(s as Map<String, Object?>)
    ],
    [
      for (final h in json['emptyOrUnreadable']! as List)
        ExpectedHealth.fromJson(h as Map<String, Object?>)
    ],
  );
}

final class _Builder {
  _Builder(this.root);
  final String root;
  final groups = <ExpectedGroup>[];
  final singles = <ExpectedSingle>[];
  final health = <ExpectedHealth>[];

  void write(String path, List<int> bytes, DateTime modified) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    file.setLastModifiedSync(modified);
  }

  /// Writes a group: the document to keep, then (path, rule, bytes, time)
  /// for each duplicate.
  void group(String name, String why, (String, List<int>, DateTime) keep,
      List<(String, String, List<int>, DateTime)> members) {
    write(keep.$1, keep.$2, keep.$3);
    for (final m in members) {
      write(m.$1, m.$3, m.$4);
    }
    groups.add(ExpectedGroup(
        name: name,
        why: why,
        keep: keep.$1,
        members: {for (final m in members) m.$1: m.$2}));
  }

  void single(String path, List<int> bytes, DateTime modified, String why) {
    write(path, bytes, modified);
    singles.add(ExpectedSingle(path, why));
  }

  void broken(String path, List<int> bytes, String why,
      {String? rule,
      String? observation,
      String? partialCopyOf,
      DateTime? modified,
      DateTime? graceEnds,
      String? ruleAfterGrace,
      String? partialAfterGrace}) {
    write(path, bytes, modified ?? plantedModified);
    health.add(ExpectedHealth(
        path: path,
        why: why,
        rule: rule,
        observation: observation,
        partialCopyOf: partialCopyOf,
        graceEnds: graceEnds,
        ruleAfterGrace: ruleAfterGrace,
        partialAfterGrace: partialAfterGrace));
  }
}

DateTime _day(int month, int day, [int hour = 9, int minute = 0]) =>
    DateTime(2026, month, day, hour, minute);

const _wa = 'WhatsApp/Media/WhatsApp Documents';

void _plant(_Builder b, DateTime now) {
  // --- Ethan: an invoice saved again and again ---------------------------
  final invoice42 = _invoice(42, 'Harbor Freight Partners', 1);
  final invoicePdf = pdfDocument(pages: [invoice42], created: _day(9, 30));
  b.group(
    'invoice 0042 (Ethan)',
    'Downloaded from the client portal twice, then sent over WhatsApp, '
        'which re-saves PDFs with its own ids and dates',
    ('Documents/Invoices/Invoice_0042.pdf', invoicePdf, _day(9, 30)),
    [
      ('Download/Invoice_0042.pdf', 'F01', invoicePdf, _day(10, 1)),
      ('Download/Invoice_0042 (1).pdf', 'F01', invoicePdf, _day(10, 2)),
      (
        '$_wa/Invoice_0042.pdf',
        'F02',
        pdfDocument(
            pages: [invoice42],
            producer: 'WhatsApp Document Exporter',
            id: 'f0e1d2c3b4a5968778695a4b3c2d1e0f',
            created: _day(10, 3, 14)),
        _day(10, 3, 14)
      ),
    ],
  );
  for (final (n, client, seed) in [
    (43, 'Harbor Freight Partners', 2),
    (44, 'Lakeside Cold Storage', 3),
  ]) {
    b.single(
        'Documents/Invoices/Invoice_00$n.pdf',
        pdfDocument(
            pages: [_invoice(n, client, seed)], created: _day(10, n - 40)),
        _day(10, n - 40),
        'Another invoice from the same template: different number, '
            'amounts and lines');
  }

  // --- A contract re-saved by another app (streams no longer compressed)
  final agreement = [_agreement(1), _agreement(2)];
  b.group(
    'service agreement re-saved',
    'The same two pages re-saved by a PDF viewer that stores page '
        'contents uncompressed and writes its own metadata',
    (
      'Documents/Contracts/Acme_Services_Agreement.pdf',
      pdfDocument(pages: agreement, created: _day(8, 20)),
      _day(8, 20)
    ),
    [
      (
        'Download/Acme_Services_Agreement_reviewed.pdf',
        'F02',
        pdfDocument(
            pages: agreement,
            compress: false,
            producer: 'Mobile PDF Viewer 7.2',
            id: '99887766554433221100ffeeddccbbaa',
            created: _day(9, 2)),
        _day(9, 2)
      ),
    ],
  );

  // --- Ethan: the quarterly report, copied, re-zipped and exported ------
  final q3 = _report('Q3', 18420, 0.962, 'September');
  final q3Docx = docxDocument(q3, saved: _day(10, 6));
  b.group(
    'Q3 logistics report',
    'A Word document duplicated in place, the same file re-zipped by an '
        'email app, re-saved by Word (new internal XML), and exported to PDF',
    ('Documents/Reports/Q3 Logistics Report.docx', q3Docx, _day(10, 6)),
    [
      (
        'Documents/Reports/Q3 Logistics Report - Copy.docx',
        'F01',
        q3Docx,
        _day(10, 6, 10)
      ),
      (
        'Download/Q3 Logistics Report.docx',
        'F02',
        docxDocument(q3,
            saved: _day(10, 7, 16), zipTime: _day(10, 7, 16), level: 9),
        _day(10, 7, 16)
      ),
      (
        'Documents/Reports/Q3 Logistics Report (2).docx',
        'F03',
        docxDocument(q3,
            saved: _day(10, 8), revisionIds: '00A1B2C3', splitRuns: true),
        _day(10, 8)
      ),
      (
        'Documents/Reports/Q3 Logistics Report.pdf',
        'F03',
        pdfDocument(pages: [q3], created: _day(10, 6, 11)),
        _day(10, 6, 11)
      ),
    ],
  );
  b.single(
      'Documents/Reports/Q2 Logistics Report.docx',
      docxDocument(_report('Q2', 17105, 0.948, 'June'), saved: _day(7, 6)),
      _day(7, 6),
      'Last quarter\'s report from the same template: other figures');

  // --- Redundant saves of a manifest that was edited a little each time -
  final manifest = _manifest(const {});
  b.group(
    'shipping manifest drafts',
    'Saved as a new file after each small edit; keep the newest version',
    (
      'Documents/Manifests/Shipping manifest final v3.docx',
      docxDocument(
          _manifest(const {'twelve': 'fourteen', 'Tuesday': 'Wednesday'}),
          saved: _day(10, 12)),
      _day(10, 12)
    ),
    [
      (
        'Documents/Manifests/Shipping manifest.docx',
        'F04',
        docxDocument(manifest, saved: _day(10, 10)),
        _day(10, 10)
      ),
      (
        'Documents/Manifests/Shipping manifest final.docx',
        'F04',
        docxDocument(_manifest(const {'twelve': 'fourteen'}),
            saved: _day(10, 11)),
        _day(10, 11)
      ),
    ],
  );
  b.single(
      'Documents/Manifests/Shipping manifest November.docx',
      docxDocument(
          _manifest(const {}, consignment: 'NG-77410', booking: '20261109'),
          saved: _day(11, 1)),
      _day(10, 25),
      'Next month\'s manifest: same wording, different consignment and '
          'booking numbers (blocked by the reference-number guard)');

  // --- Two leases from one template: only the tenant differs ------------
  for (final (tenant, unit) in [('Smith', '4B'), ('Jones', '7A')]) {
    b.single(
        'Documents/Contracts/Lease - $tenant.docx',
        docxDocument(_lease(tenant, unit), saved: _day(8, tenant.length)),
        _day(8, tenant.length),
        'Same lease template for another tenant (blocked by the name guard)');
  }

  // --- Ethan: a delivery note scanned again because of focus ------------
  final note = documentPage('DELIVERY NOTE', 'DN-20261014-0071', _goods(1));
  final noteScan = _jpg(rescan(note, 1, noise: 3));
  b.group(
    'delivery note rescans (Ethan)',
    'Scanned, rescanned because the first try was out of focus, and '
        'scanned once more at another desk that afternoon; keep the clearest',
    (
      'Documents/Scans/Scan_2026-10-14_091500.pdf',
      pdfDocument(scans: [noteScan], created: _day(10, 14, 9, 15)),
      _day(10, 14, 9, 15)
    ),
    [
      (
        'Documents/Scans/Scan_2026-10-14_091620.pdf',
        'F05',
        pdfDocument(
            scans: [_jpg(rescan(note, 2, dx: .004, blur: 2))],
            created: _day(10, 14, 9, 16)),
        _day(10, 14, 9, 16)
      ),
      (
        'Download/delivery_note_DN0071.pdf',
        'F05',
        pdfDocument(
            scans: [_jpg(rescan(note, 3, dx: .012, dy: -.006, brightness: 8))],
            producer: 'Office Scanner App',
            created: _day(10, 14, 15, 40)),
        _day(10, 14, 15, 40)
      ),
    ],
  );
  b.single(
      'Documents/Scans/Scan_2026-10-14_093000.pdf',
      pdfDocument(scans: [
        _jpg(rescan(
            documentPage('DELIVERY NOTE', 'DN-20261014-0072', _goods(2)), 4))
      ], created: _day(10, 14, 9, 30)),
      _day(10, 14, 9, 30),
      'The next delivery note: same layout, different goods');
  b.single(
      'Documents/Scans/Scan_2026-10-14_093500.pdf',
      pdfDocument(scans: [
        _jpg(rescan(
            documentPage('DELIVERY NOTE', 'DN-20261014-0071', [
              ..._goods(1).take(_goods(1).length - 1),
              '3 x  Stretch film roll   \$45.00'
            ]),
            5))
      ], created: _day(10, 14, 9, 35)),
      _day(10, 14, 9, 35),
      'Corrected delivery note: identical except the last line');
  b.single(
      'Documents/Scans/Scan_2026-10-21_091500.pdf',
      pdfDocument(scans: [
        _jpg(rescan(
            documentPage('DELIVERY NOTE', 'DN-20261021-0071', [
              for (final line in _goods(1))
                line.replaceAllMapped(
                    RegExp(r'\d'), (m) => '${(int.parse(m[0]!) + 3) % 10}')
            ]),
            6))
      ], created: _day(10, 21, 9, 15)),
      _day(10, 21, 9, 15),
      'Next week\'s delivery of the same goods: only the numbers differ, '
          'which the pages can\'t show; kept apart because it was scanned a '
          'week later (G5)');

  // --- A two-page customs declaration, scanned twice --------------------
  final customs = [
    documentPage('CUSTOMS DECLARATION', 'CD-88213  page 1 of 2', _goods(5)),
    documentPage('CUSTOMS DECLARATION', 'CD-88213  page 2 of 2', _goods(6)),
  ];
  b.group(
    'customs declaration rescan',
    'Both pages scanned again and sent over Bluetooth',
    (
      'Documents/Scans/Customs_declaration_CD88213.pdf',
      pdfDocument(scans: [
        for (final (i, page) in customs.indexed) _jpg(rescan(page, 10 + i))
      ]),
      _day(10, 15, 14)
    ),
    [
      (
        'Bluetooth/Customs_declaration_CD88213.pdf',
        'F05',
        pdfDocument(scans: [
          for (final (i, page) in customs.indexed)
            _jpg(rescan(page, 20 + i, dx: -.008, dy: .004, brightness: -10))
        ]),
        _day(10, 15, 15)
      ),
    ],
  );
  b.single(
      'Documents/Scans/Customs_declaration_CD88214.pdf',
      pdfDocument(scans: [
        _jpg(rescan(customs[0], 30)),
        _jpg(rescan(
            documentPage(
                'CUSTOMS DECLARATION', 'CD-88214  page 2 of 2', _goods(7)),
            31)),
      ]),
      _day(10, 15, 16),
      'Two-page scan whose first page matches but second page differs');

  // --- Meeting notes as plain text, over Bluetooth, and as Markdown -----
  final notes = _meetingNotes();
  b.group(
    'meeting notes',
    'Plain-text notes, the same notes received over Bluetooth from a '
        'Windows laptop (BOM, CRLF line ends, trailing spaces), and a '
        'Markdown copy',
    (
      'Documents/Notes/meeting_notes.txt',
      utf8.encode(notes.join('\n')),
      _day(10, 9, 17)
    ),
    [
      (
        'Bluetooth/meeting_notes.txt',
        'F02',
        [
          0xEF,
          0xBB,
          0xBF,
          ...utf8.encode('${notes.map((l) => '$l  ').join('\r\n')}\r\n\r\n')
        ],
        _day(10, 9, 18)
      ),
      (
        'Documents/Notes/meeting_notes.md',
        'F03',
        utf8.encode([
          '# ${notes.first}',
          '',
          for (final l in notes.skip(1))
            '- **${l.split(' ').first}** ${l.split(' ').skip(1).join(' ')}'
        ].join('\n')),
        _day(10, 9, 19)
      ),
    ],
  );
  b.single(
      'Documents/Notes/todo.txt',
      utf8.encode('Call Lakeside about the cold storage quote.\nRenew forklift '
          'certificate before Friday.\nOrder more pallet wrap.\n'),
      _day(10, 2),
      'An unrelated note');
  b.single(
      'Documents/Notes/short_note.txt',
      utf8.encode('Gate code changed to the new one this morning, ask Dana '
          'before the night shift.\n'),
      _day(10, 3),
      'Short note (fewer than 20 words)');
  b.single(
      'Documents/Notes/short_note copy.md',
      utf8.encode('**Gate code** changed to the new one this morning — ask '
          'Dana before the night shift!\n'),
      _day(10, 3, 10),
      'Same few words as short_note.txt: too short for "same text" to mean '
          'the same document');

  // --- A form whose PDF text can't be extracted (embedded CID font) -----
  final form = [
    'Export declaration form EX-1 for consignment NG-77211',
    'Exporter Northgate Logistics, 41 Harbor Rd, declared value 18,400 USD',
    'Goods: industrial shelving units, 14 pallets, gross weight 3,250 kg',
    'Country of origin: United States. Destination: Rotterdam, Netherlands',
  ];
  final formPdf =
      pdfDocument(pages: [form], glyphCodes: true, created: _day(9, 22));
  b.group(
    'customs form without readable text',
    'Text stored as glyph numbers, so only identical and re-saved copies '
        'can be found',
    ('Documents/Forms/export_declaration_EX1.pdf', formPdf, _day(9, 22)),
    [
      ('Download/export_declaration_EX1.pdf', 'F01', formPdf, _day(9, 23)),
      (
        'Telegram/Telegram Documents/export_declaration_EX1.pdf',
        'F02',
        pdfDocument(
            pages: [form],
            glyphCodes: true,
            producer: 'Telegram',
            id: '0123456789abcdef0123456789abcdef',
            created: _day(9, 24)),
        _day(9, 24)
      ),
    ],
  );

  // --- Not documents, but not images either: archives, audio, sheets ----
  final receipts = zipArchive({
    for (var i = 1; i <= 6; i++)
      'receipt_2026-09-${i.toString().padLeft(2, '0')}.txt':
          'Fuel receipt ${i * 13 + 400}: ${40 + i * 7}.50 USD at Harbor Rd station\n'
  });
  b.group(
    'receipts archive',
    'A ZIP of receipts downloaded again',
    ('Documents/Archive/receipts_2026_09.zip', receipts, _day(10, 1, 8)),
    [('Download/receipts_2026_09.zip', 'F01', receipts, _day(10, 4))],
  );
  final call = flacLike(48 * 1024, 7);
  b.group(
    'client call recording',
    'A recording shared to WhatsApp, which keeps a copy',
    ('Recordings/client_call_2026-10-02.flac', call, _day(10, 2, 15)),
    [
      (
        'WhatsApp/Media/WhatsApp Audio/AUD-20261002-WA0003.flac',
        'F01',
        call,
        _day(10, 2, 16)
      )
    ],
  );
  final rates = utf8.encode([
    'route,service,rate_usd,transit_days',
    for (var i = 0; i < 12; i++)
      'R${100 + i},${i.isEven ? 'standard' : 'express'},${120 + i * 15},${2 + i % 4}'
  ].join('\n'));
  b.group(
    'rate sheet',
    'A CSV forwarded on Telegram and saved again',
    ('Documents/rates.csv', rates, _day(9, 15)),
    [('Telegram/Telegram Documents/rates (1).csv', 'F01', rates, _day(9, 16))],
  );

  // --- Left alone: tiny, app-owned and image files ----------------------
  for (final path in ['Documents/Notes/ok.txt', 'Download/ok.txt']) {
    b.single(path, utf8.encode('ok thanks'), _day(10, 5),
        'Identical, but 9 bytes: too small to be worth grouping (X04)');
  }
  final config = utf8.encode(jsonEncode({
    'theme': 'system',
    'syncOnWifiOnly': true,
    'lastBackup': '2026-10-01T02:00:00Z',
    'notifications': {'deliveries': true, 'invoices': false},
  }));
  for (final app in ['com.northgate.driver', 'com.northgate.depot']) {
    b.single('Android/data/$app/files/config.json', config, _day(10, 1),
        'Identical settings in two apps\' private folders (X05)');
  }
  final photo =
      img.encodeJpg(img.copyResize(receiptPhoto(41), width: 450), quality: 85);
  for (final path in [
    'Pictures/receipt_fuel.jpg',
    'Download/receipt_fuel.jpg'
  ]) {
    b.single(path, photo, _day(10, 4),
        'Identical photos: the duplicate photo scan\'s job, not this one');
  }

  // --- Empty, unreadable and half-downloaded documents ------------------
  b.broken(
      'Download/Invoice_0042 (2).pdf',
      invoicePdf.sublist(0, (invoicePdf.length * 0.6).round()),
      'Download of Invoice_0042.pdf that stopped part way',
      rule: 'U06',
      partialCopyOf: 'Documents/Invoices/Invoice_0042.pdf');
  b.broken(
      'Download/Q3 Logistics Report (1).docx.crdownload',
      q3Docx.sublist(0, q3Docx.length ~/ 2),
      'Browser download of the Q3 report that never finished',
      rule: 'U03',
      partialCopyOf: 'Documents/Reports/Q3 Logistics Report.docx');
  final cutNow = invoicePdf.sublist(0, (invoicePdf.length * 0.4).round());
  b.broken(
      'Download/Invoice_0042 (3).pdf',
      cutNow,
      'Still downloading (modified just now): not judged during the '
          '10-minute grace period, a failed download of the invoice after it',
      observation: 'beingWritten',
      modified: now,
      graceEnds: now.add(const Duration(minutes: 10)),
      ruleAfterGrace: 'U06',
      partialAfterGrace: 'Documents/Invoices/Invoice_0042.pdf');
  b.broken('Documents/New Text Document.txt', const [],
      'Created and never written to',
      rule: 'E01');
  b.broken('Documents/New Text Document (2).txt', const [],
      'Identical to the one above, but empty: not a duplicate group',
      rule: 'E01');
  b.broken('Documents/Notes/notes_backup.txt', utf8.encode('   \n\n\t  \n'),
      'Only whitespace',
      rule: 'E02');
  b.broken(
      'Download/rates_export.csv',
      utf8.encode('route,service,rate_usd,transit_days\n'),
      'Export with a header and no rows',
      rule: 'E03');
  b.broken('Documents/Invoices/Invoice_template.pdf', _pdfWithoutPages(),
      'PDF with no pages',
      rule: 'E05');
  final signIn = utf8.encode('<!DOCTYPE html><html><head><title>Sign in</title>'
      '</head><body><form action="/login"><input name="user"><input '
      'type="password" name="pass"></form>Session expired. Please sign in to '
      'download statement_october.pdf</body></html>');
  for (final path in [
    'Download/statement_october.pdf',
    'Download/statement_october (1).pdf'
  ]) {
    b.broken(path, signIn,
        'A sign-in page saved as .pdf (twice): unreadable, not a duplicate',
        rule: 'U05');
  }
  b.broken('Documents/Contracts/broken_contract.pdf', Uint8List(8192),
      'Zero-filled: a copy that failed',
      rule: 'U04');
}

// --- Content --------------------------------------------------------------

Uint8List _jpg(img.Image page) => img.encodeJpg(page, quality: 82);

List<String> _goods(int seed) {
  final r = Random(seed);
  const names = [
    'Pallet wrap', 'Stretch film roll', 'Cardboard box L', 'Bubble mailer', //
    'Packing tape', 'Shipping labels x500', 'Corner protectors',
    'Strapping band', 'Void fill paper', 'Euro pallet',
  ];
  return [
    for (var i = 0; i < 6 + r.nextInt(6); i++)
      '${1 + r.nextInt(40)} x  ${names[r.nextInt(names.length)]}   '
          '\$${10 + r.nextInt(400)}.00'
  ];
}

List<String> _invoice(int number, String client, int seed) {
  final r = Random(seed);
  const services = [
    'Linehaul freight Atlanta to Savannah',
    'Cold storage per pallet week',
    'Cross-dock handling',
    'Fuel surcharge',
    'Liftgate delivery',
    'Pallet exchange',
    'Detention time per hour',
  ];
  final lines = [
    for (var i = 0; i < 4 + r.nextInt(3); i++)
      '${services[r.nextInt(services.length)]}  qty ${1 + r.nextInt(20)}  '
          'amount ${100 + r.nextInt(2400)}.00 USD'
  ];
  return [
    'Northgate Logistics  41 Harbor Rd  Savannah GA',
    'Invoice number INV-00$number  issued 2026-09-${(number - 12).toString().padLeft(2, '0')}',
    'Bill to $client, accounts payable department',
    ...lines,
    'Total due ${2000 + r.nextInt(6000)}.00 USD within 30 days of the invoice date',
    'Pay by bank transfer quoting invoice number INV-00$number',
  ];
}

List<String> _agreement(int page) => page == 1
    ? [
        'Master services agreement between Acme Industrial Supply and Northgate Logistics',
        'This agreement sets out the terms on which Northgate will store, handle and',
        'deliver goods for Acme from its Savannah warehouse. Northgate will keep the',
        'goods insured at replacement value and will report stock levels every week.',
        'Acme will give at least two working days notice for outbound orders over',
        'twenty pallets and will pay invoices within thirty days of receipt.',
      ]
    : [
        'Either party may end this agreement with ninety days written notice.',
        'Northgate is not liable for delays caused by weather, strikes or customs',
        'holds outside its control. Disputes will first be raised between account',
        'managers and then, if unresolved, referred to mediation in Savannah.',
        'Signed for Acme Industrial Supply and for Northgate Logistics.',
      ];

List<String> _report(
        String quarter, int shipments, double onTime, String month) =>
    [
      '$quarter Logistics Report',
      'Northgate handled $shipments shipments this quarter, with an on-time rate '
          'of ${(onTime * 100).toStringAsFixed(1)} percent across all lanes.',
      'Cold storage occupancy averaged ${quarter == 'Q3' ? 87 : 81} percent and '
          'peaked in $month when seasonal produce arrived early.',
      'The Savannah to Atlanta lane remained the busiest, followed by '
          'Jacksonville and Charleston.',
      'Claims for damaged goods fell to ${quarter == 'Q3' ? 14 : 22} cases, '
          'mostly from pallets that were wrapped too loosely at origin.',
      'Next quarter we will add a second shift at the cross-dock and renew the '
          'forklift fleet lease.',
    ];

/// A long manifest; [edits] swaps single words to make later drafts.
List<String> _manifest(Map<String, String> edits,
    {String consignment = 'NG-77209', String booking = '20261012'}) {
  final text = [
    'Shipping manifest for consignment $consignment, booking $booking.',
    'This manifest lists every pallet loaded onto trailer seven at the Savannah '
        'warehouse for delivery to the Atlanta distribution centre. The driver must '
        'check each pallet against this list before leaving the dock and again on '
        'arrival, and must note any damage, missing labels or loose wrapping on the '
        'delivery copy. Pallets one to twelve hold boxed kitchen appliances and must '
        'be kept upright at all times. Pallets thirteen to twenty hold garden '
        'furniture packed in flat cartons; these may be stacked two high. Pallet '
        'twenty one holds spare parts in a locked cage and needs a signature from the '
        'receiving supervisor. The trailer is booked to leave at six in the morning on '
        'Tuesday and should reach Atlanta before noon. If the trailer is delayed by '
        'more than an hour the driver must call the planning desk so the receiving '
        'team can move the unloading slot. Temperature control is not required for '
        'this load, but the doors must stay sealed until the receiving supervisor has '
        'checked the seal number against the one printed on this manifest. Any '
        'pallet refused at delivery returns to Savannah on the same trailer and is '
        'logged by the warehouse team the following morning. Questions about this '
        'manifest go to the planning desk, which is staffed from five in the morning '
        'until eight in the evening every weekday and on Saturday mornings. Keep '
        'this manifest with the delivery copy in the cab for the whole journey and '
        'hand both to the receiving supervisor when the unloading is finished, so '
        'the stock can be booked into the warehouse system the same day.',
  ];
  return [
    for (final para in text)
      edits.entries
          .fold(para, (s, e) => s.replaceFirst(' ${e.key} ', ' ${e.value} '))
  ];
}

List<String> _lease(String tenant, String unit) => [
      'Residential lease for unit $unit, 18 Riverside Court, Savannah.',
      'This lease is made between Riverside Court Properties as landlord and '
          '$tenant as tenant. The tenant will rent unit $unit for twelve months '
          'starting on the first day of next month, paying rent on the first of each '
          'month by bank transfer. A deposit equal to one month of rent is held for '
          'the whole lease and is returned within thirty days of the end of the lease, '
          'less the cost of any repairs beyond normal wear. The tenant must keep the '
          'unit clean, report leaks and broken fittings promptly, and must not sublet '
          'the unit or keep pets without written permission from the landlord. The '
          'landlord will keep the building insured, maintain the heating and hot '
          'water, and give at least a full day of notice before entering the unit '
          'except in an emergency. Either party may end the lease after the first six '
          'months with two months of written notice. $tenant confirms having read and '
          'understood these terms and signs below together with the landlord.',
    ];

List<String> _meetingNotes() => [
      'Weekly operations meeting notes',
      'Attendees Dana, Ethan, Priya and Marcus from planning and the depot',
      'Ethan will chase the three overdue invoices from Harbor Freight Partners',
      'Priya reported the cross-dock scanner is fixed and back in use',
      'Marcus asked for two more drivers on the Charleston lane next month',
      'Dana will confirm the forklift lease renewal before the end of October',
    ];

Uint8List _pdfWithoutPages() => Uint8List.fromList(latin1
    .encode('%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'
        '2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n'
        'trailer\n<< /Root 1 0 R >>\n%%EOF\n'));
