import 'package:datamuncher/application/storage_scan/storage_scan.dart';
import 'package:datamuncher/application/storage_scan/team_views.dart';
import 'package:datamuncher/data/garbage_bin/bin_entry.dart';
import 'package:datamuncher/data/garbage_bin/file_bin.dart';
import 'package:datamuncher/models.dart' as dat16;
import 'package:datamuncher/presentation/folder_munch/main.dart' show MunchHome;
import 'package:datamuncher/presentation/garbage_collection/garbage_collection.dart';
import 'package:datamuncher/presentation/garbage_storage/garbage_collection_storage.dart';
import 'package:datamuncher/presentation/storage_results/storage_results.dart';
import 'package:datamuncher/presentation/team_pages.dart' show candidatesFromFolderScan;
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

  test('reviewSuggestionsFrom makes one swipe card per reason, largest first', () {
    final cards = reviewSuggestionsFrom(candidates);
    expect([for (final c in cards.keys) '${c.title}: ${c.storageSize}, ${c.itemCount}'], [
      'Duplicates: 3.5 MB, 2',
      'Unreadable files: 500 KB, 1',
      'Empty files: 0 B, 1',
    ]);
    expect(cards.keys.first.category, 'Photos');
    expect(cards.values.first.map((c) => c.path), ['/DCIM/1.jpg', '/DCIM/2.jpg']);
  });

  group('SwipeReviewPage (PB-20)', () {
    /// Taps [label], then waits for its message to go so it doesn't cover
    /// the buttons.
    Future<void> waitForMessage(WidgetTester tester) async {
      await tester.pumpAndSettle(); // slides in
      await tester.pump(const Duration(seconds: 3)); // shown for 2 s
      await tester.pumpAndSettle(); // slides out
    }

    Future<void> press(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await waitForMessage(tester);
    }

    testWidgets('with the scan, Move to bin sends that card to the bin', (tester) async {
      final cards = reviewSuggestionsFrom(candidates);
      final removed = <String>[];
      await tester.pumpWidget(app(SwipeReviewPage(
        suggestions: cards.keys.toList(),
        onRemove: (card) async {
          removed.add(card.id);
          return null;
        },
      )));
      expect(find.text('Duplicates'), findsOneWidget);
      await tester.tap(find.text('Move to bin'));
      await tester.pumpAndSettle();
      expect(removed, ['duplicate']);
      expect(find.text('Moved Duplicates (3.5 MB) to the Garbage Bin.'), findsOneWidget);
      await waitForMessage(tester);

      await press(tester, 'Keep');
      await press(tester, 'Skip');
      expect(find.text('Review Complete!'), findsOneWidget);
      expect(find.text('Moved to the Garbage Bin: 1'), findsOneWidget);
      expect(removed, ['duplicate'], reason: 'Keep and Skip move nothing');

      await press(tester, 'Review Again');
      await press(tester, 'Move to bin');
      expect(removed, ['duplicate'], reason: 'already in the bin');
    });

    testWidgets('on its own, it shows the sample cards and moves nothing', (tester) async {
      await tester.pumpWidget(app(const SwipeReviewPage()));
      expect(find.text('Old Screenshots'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(find.text('Move to bin'), findsNothing);
    });

    testWidgets('says so when there is nothing to review', (tester) async {
      await tester.pumpWidget(app(SwipeReviewPage(suggestions: const [], onRemove: (_) async => null)));
      expect(find.textContaining('Nothing to review'), findsOneWidget);
    });
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
        onSend: (chosen) async {
          sent = chosen;
          return null;
        },
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

  testWidgets('GarbageCollectionPage shows the app message when some files failed', (tester) async {
    final rows = collectionGroupsFrom(candidates);
    await tester.pumpWidget(app(GarbageCollectionPage(
      items: rows.keys.toList(),
      onSend: (chosen) async => "1 couldn't be moved.",
    )));
    await tester.tap(find.text('Send selected items to garbage bin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue?'));
    await tester.pumpAndSettle();
    expect(find.text("1 couldn't be moved."), findsOneWidget);
    expect(find.text('Selected items sent to the garbage bin.'), findsNothing);
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

  testWidgets('StorageResultsPage says so when nothing is wasted', (tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final results = scanResultsFrom(report(), const [], const []);
    await tester.pumpWidget(app(StorageResultsPage(scanResults: results)));
    expect(find.text('Wasted Digital Space Detected'), findsNothing);
    expect(find.text('No wasted space found'), findsOneWidget);
    expect(find.text('Nothing to reclaim.'), findsOneWidget);
  });

  testWidgets('StorageResultsPage buttons call the app, and are off without it', (tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var details = 0, exports = 0;
    await tester.pumpWidget(app(StorageResultsPage(
      scanResults: scanResultsFrom(report(), candidates, const []),
      onReview: () => details++,
      onExport: () => exports++,
    )));
    await tester.tap(find.text('Review Suggestions'));
    await tester.tap(find.text('Export Results'));
    expect((details, exports), (1, 1));

    await tester.pumpWidget(app(const StorageResultsPage()));
    final buttons = tester.widgetList<ButtonStyleButton>(find.byWidgetPredicate((w) => w is ButtonStyleButton));
    expect(buttons.every((b) => b.onPressed == null), isTrue, reason: 'the standalone preview has nothing to open');
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

  testWidgets('GarbageStoragePage stat cards fit a phone screen', (tester) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const GarbageStoragePage()));
    expect(tester.takeException(), isNull, reason: 'no overflow');
    expect(find.text('Storage Used'), findsOneWidget);
  });

  group('GarbageStoragePage with the bin (DAT-17)', () {
    FileBinRecord rec(String id, int size, {int? stored}) => FileBinRecord(
          id: id,
          originalPath: '/sdcard/Download/$id.txt',
          storedPath: '/sdcard/.DataMuncherBin/$id.txt',
          sizeBytes: size,
          storedSizeBytes: stored ?? size,
          compressed: stored != null,
          reason: CollectionReason.other,
          collectedAt: DateTime(2026, 11, 1),
        );

    Future<_FakeStorage> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = _FakeStorage([rec('log', 10240, stored: 2048), rec('notes', 512)]);
      await tester.pumpWidget(app(GarbageStoragePage(source: storage)));
      return storage;
    }

    testWidgets('shows what the bin really stores', (tester) async {
      await pump(tester);
      expect(find.text('2.6 KB'), findsWidgets, reason: 'storage used: 2048 + 512 bytes, as the Garbage Bin shows it');
      expect(find.text('8.2 KB'), findsOneWidget, reason: 'space saved by compression');
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1 of 2 file(s) compressed'), findsOneWidget);
      expect(find.text('Collect Files'), findsNothing, reason: "the picker can't remove originals");
    });

    testWidgets('Optimize compresses the file in the bin', (tester) async {
      final storage = await pump(tester);
      await tester.tap(find.byTooltip('Optimize File').last);
      await tester.pumpAndSettle();
      expect(storage.compressed, ['notes']);
      expect(find.text('Optimized notes.txt: saved 412 B.'), findsOneWidget);
      expect(find.text('2 of 2 file(s) compressed'), findsOneWidget);
    });

    testWidgets('Remove asks first and deletes for good', (tester) async {
      final storage = await pump(tester);
      await tester.tap(find.byTooltip('Remove File').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('deleted for good'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(storage.deleted, isEmpty);

      await tester.tap(find.byTooltip('Remove File').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(storage.deleted, ['log']);
      expect(find.text('1 file(s) deleted successfully.'), findsOneWidget);
      expect(find.text('log.txt'), findsNothing);
    });
  });

  testWidgets('MunchHome opens before any scan', (tester) async {
    await tester.pumpWidget(app(const MunchHome()));
    expect(find.text('PICK A FOLDER'), findsOneWidget);
    for (final label in ['DUPLICATES', 'EMPTY', 'UNREADABLE', 'BLURRY']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.textContaining('not built yet'), findsNothing);
    expect(find.textContaining('GARBAGE BIN'), findsNothing, reason: 'nothing to move before a scan');
  });

  test('folder-scan findings go to the bin with matching reasons', () {
    final file = dat16.FileRecord(path: '/sdcard/Download/a.pdf', sizeBytes: 42);
    final c = candidatesFromFolderScan([
      dat16.ClassificationResult(file, dat16.WasteCategory.unreadable, 'File could not be opened.'),
      dat16.ClassificationResult(file, dat16.WasteCategory.blurry, 'Sharpness 3.0 is below 60.'),
    ]);
    expect(c.map((x) => x.reason), [CollectionReason.unreadable, CollectionReason.blurry]);
    expect(c.first.path, '/sdcard/Download/a.pdf');
    expect(c.first.item.displayName, 'a.pdf');
    expect(c.first.item.sizeBytes, 42);
  });
}

/// In-memory stand-in for the bin's file storage.
class _FakeStorage extends ChangeNotifier implements GarbageStorageSource {
  _FakeStorage(this.files);

  @override
  final List<FileBinRecord> files;
  final compressed = <String>[];
  final deleted = <String>[];

  @override
  Future<FileBinRecord?> compress(String id) async {
    final i = files.indexWhere((f) => f.id == id);
    final f = files[i];
    final packed = FileBinRecord(
      id: f.id,
      originalPath: f.originalPath,
      storedPath: '${f.storedPath}$compressedSuffix',
      sizeBytes: f.sizeBytes,
      storedSizeBytes: 100,
      compressed: true,
      reason: f.reason,
      collectedAt: f.collectedAt,
    );
    files[i] = packed;
    compressed.add(id);
    notifyListeners();
    return packed;
  }

  @override
  Future<Set<String>> deleteForGood(List<String> ids) async {
    files.removeWhere((f) => ids.contains(f.id));
    deleted.addAll(ids);
    notifyListeners();
    return ids.toSet();
  }
}
