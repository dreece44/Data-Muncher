import 'package:datamuncher/application/storage_scan/storage_scan.dart';
import 'package:datamuncher/application/storage_scan/team_views.dart';
import 'package:datamuncher/data/garbage_bin/bin_entry.dart';
import 'package:datamuncher/presentation/folder_munch/main.dart' show MunchHome;
import 'package:datamuncher/presentation/garbage_collection/garbage_collection.dart';
import 'package:datamuncher/presentation/garbage_storage/garbage_collection_storage.dart';
import 'package:datamuncher/presentation/storage_results/storage_results.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scan_engine_flutter/scan_engine_flutter.dart' as engine;

engine.StorageItem item(String path, int size) =>
    engine.StorageItem(id: path, path: path, displayName: p.basename(path), sizeBytes: size);

ScanCandidate candidate(String path, int size, CollectionReason reason) =>
    ScanCandidate(item: item(path, size), reason: reason, explanation: '');

engine.ScanReport report({engine.StorageStats? storage}) => engine.ScanReport(
      platform: engine.DevicePlatform.android,
      startedAt: DateTime(2026),
      finishedAt: DateTime(2026),
      storage: storage,
      itemsScanned: 120,
      bytesScanned: 0,
      foldersScanned: 9,
      findings: const [],
      categories: const {},
      issues: const [],
      notes: const [],
    );

final candidates = [
  candidate('/Download/a.zip', 0, CollectionReason.emptyFile),
  candidate('/DCIM/1.jpg', 2000000, CollectionReason.duplicate),
  candidate('/DCIM/2.jpg', 1500000, CollectionReason.duplicate),
  candidate('/Download/b.pdf', 500000, CollectionReason.unreadable),
];

Widget app(Widget page) => MaterialApp(home: page);

void main() {
  group('scanResultsFrom', () {
    test('fills the results page from a scan', () {
      final r = scanResultsFrom(
        report(storage: const engine.StorageStats(totalBytes: 64000000000, freeBytes: 16000000000)),
        candidates,
        [const engine.InstalledApp(packageName: 'com.x', label: 'X', sizeBytes: 1000000)],
      );
      expect(r.totalStorage, '64 GB');
      expect(r.usedStorage, '48 GB');
      expect(r.freeStorage, '16 GB');
      expect(r.usedPercent, 0.75);
      expect(r.wastedStorage, '5 MB');
      expect(r.reclaimable, {
        'Empty file': '0 B',
        'Duplicate': '3.5 MB',
        'Unreadable file': '500 KB',
        unusedAppsLabel: '1 MB',
      });
      expect(r.filesScanned, 120);
      expect(r.directoriesScanned, 9);
    });

    test('says Unknown when the phone reports no storage totals', () {
      final r = scanResultsFrom(report(), const [], const []);
      expect(r.totalStorage, 'Unknown');
      expect(r.usedPercent, 0);
      expect(r.wastedStorage, '0 B');
      expect(r.reclaimable, isEmpty);
    });
  });

  test('collectionGroupsFrom makes one ticked row per reason', () {
    final groups = collectionGroupsFrom(candidates);
    expect([for (final row in groups.keys) '${row.name}: ${row.size}'], [
      'Empty file (1): 0 B',
      'Duplicate (2): 3.5 MB',
      'Unreadable file (1): 500 KB',
    ]);
    expect(groups.keys.every((row) => row.selected), isTrue);
    expect(groups.values.elementAt(1).map((c) => c.path), ['/DCIM/1.jpg', '/DCIM/2.jpg']);
  });

  group('GarbageCollectionPage', () {
    testWidgets('sample data totals the ticked rows', (tester) async {
      await tester.pumpWidget(app(const GarbageCollectionPage()));
      expect(find.text('3 items selected'), findsOneWidget);
      expect(find.text('95 GB'), findsOneWidget, reason: '42 + 38 + 15 GB, as in the original mock-up');
      await tester.tap(find.text('Duplicate Files'));
      await tester.pump();
      expect(find.text('57 GB'), findsOneWidget);
    });

    testWidgets('sends the ticked rows and drops them from the list', (tester) async {
      final rows = collectionGroupsFrom(candidates);
      List<StorageItem>? sent;
      await tester.pumpWidget(app(GarbageCollectionPage(
        items: rows.keys.toList(),
        onSend: (chosen) async => sent = chosen,
      )));
      expect(find.text('4 MB'), findsOneWidget);
      await tester.tap(find.text('Empty file (1)'));
      await tester.pump();
      await tester.tap(find.text('Send selected items to garbage bin'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue?'));
      await tester.pumpAndSettle();
      expect(sent?.map((r) => r.name), ['Duplicate (2)', 'Unreadable file (1)']);
      expect(find.text('Duplicate (2)'), findsNothing);
      expect(find.text('Empty file (1)'), findsOneWidget);
      expect(find.text('Selected items sent to the garbage bin.'), findsOneWidget);
    });
  });

  testWidgets('StorageResultsPage shows real results and the wasted space notice', (tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final results = scanResultsFrom(
      report(storage: const engine.StorageStats(totalBytes: 64000000000, freeBytes: 16000000000)),
      candidates,
      const [],
    );
    await tester.pumpWidget(app(StorageResultsPage(scanResults: results)));
    expect(find.text('Wasted Digital Space Detected'), findsOneWidget);
    expect(find.text('4 MB of storage may be wasted.'), findsOneWidget);
    expect(find.text('Duplicate'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);
    expect(find.text('128 GB'), findsNothing, reason: 'sample data is replaced');
  });

  testWidgets('StorageResultsPage still shows its sample without results', (tester) async {
    await tester.pumpWidget(app(const StorageResultsPage()));
    expect(find.text('8.7 GB of storage may be wasted.'), findsOneWidget);
  });

  testWidgets('GarbageStoragePage opens empty', (tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const GarbageStoragePage()));
    expect(find.text('Your garbage bin is empty.'), findsOneWidget);
    expect(find.text('0 B'), findsWidgets);
  });

  testWidgets('MunchHome opens before any scan', (tester) async {
    await tester.pumpWidget(app(const MunchHome()));
    expect(find.text('MUNCH MY DATA'), findsOneWidget);
    expect(find.text('BLURRY (not built yet)'), findsOneWidget);
  });
}
