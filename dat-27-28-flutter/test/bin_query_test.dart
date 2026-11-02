import 'package:datamuncher/application/garbage_bin/bin_query.dart';
import 'package:datamuncher/data/garbage_bin/bin_entry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  // a: photo, 5 KB (4 KB in bin), 2 days ago, leaves in 1 day
  // b: video, 90 KB, 1 hour ago, leaves in 10 days
  // c: document, empty, 5 days ago, no time limit
  final a = makeEntry(
    id: 'a',
    fileName: 'Beach.jpg',
    originalPath: '/DCIM/Camera/Beach.jpg',
    category: FileCategory.photo,
    reason: CollectionReason.duplicate,
    originalSizeBytes: 5000,
    storedSizeBytes: 4000,
    collectedAt: testNow.subtract(const Duration(days: 2)),
    expiresAt: testNow.add(const Duration(days: 1)),
  );
  final b = makeEntry(
    id: 'b',
    fileName: 'clip.mp4',
    originalPath: '/Movies/clip.mp4',
    category: FileCategory.video,
    reason: CollectionReason.oldFile,
    originalSizeBytes: 90000,
    collectedAt: testNow.subtract(const Duration(hours: 1)),
    expiresAt: testNow.add(const Duration(days: 10)),
  );
  final c = makeEntry(
    id: 'c',
    fileName: 'notes.txt',
    originalPath: '/Documents/notes.txt',
    category: FileCategory.document,
    reason: CollectionReason.emptyFile,
    originalSizeBytes: 0,
    collectedAt: testNow.subtract(const Duration(days: 5)),
  );
  final entries = [c, a, b];

  List<String> ids(List<BinEntry> list) => [for (final e in list) e.id];
  List<String> sortedIds(BinSort sort) =>
      ids(applyBinQuery(entries, BinQuery(sort: sort)));

  group('sorting', () {
    test('newest first is the default', () {
      expect(ids(applyBinQuery(entries, const BinQuery())), ['b', 'a', 'c']);
    });

    test('oldest first', () {
      expect(sortedIds(BinSort.oldestFirst), ['c', 'a', 'b']);
    });

    test('largest first uses the original size', () {
      expect(sortedIds(BinSort.largestFirst), ['b', 'a', 'c']);
    });

    test('name A–Z ignores case', () {
      final apple = makeEntry(id: '1', fileName: 'apple.jpg');
      final banana = makeEntry(id: '2', fileName: 'Banana.jpg');
      final sorted = applyBinQuery(
        [banana, apple],
        const BinQuery(sort: BinSort.nameAToZ),
      );
      expect(ids(sorted), ['1', '2']);
    });

    test('leaving soonest puts files with no time limit last', () {
      expect(sortedIds(BinSort.leavingSoonest), ['a', 'b', 'c']);
    });

    test('ties are broken by name so the order is stable', () {
      final when = testNow.subtract(const Duration(hours: 3));
      final x = makeEntry(id: 'x', fileName: 'b.jpg', collectedAt: when);
      final y = makeEntry(id: 'y', fileName: 'a.jpg', collectedAt: when);
      expect(ids(applyBinQuery([x, y], const BinQuery())), ['y', 'x']);
    });
  });

  group('search and category', () {
    List<String> search(String text, {FileCategory? category}) => ids(
          applyBinQuery(
            entries,
            BinQuery(searchText: text, category: category),
          ),
        );

    test('matches the file name', () {
      expect(search('beach'), ['a']);
    });

    test('matches the folder it came from', () {
      expect(search('movies'), ['b']);
    });

    test('matches the reason it was collected', () {
      expect(search('empty'), ['c']);
    });

    test('ignores case and surrounding spaces', () {
      expect(search('  CLIP  '), ['b']);
    });

    test('blank search shows everything', () {
      expect(search('   '), ['b', 'a', 'c']);
    });

    test('category shows only that kind of file', () {
      expect(search('', category: FileCategory.video), ['b']);
    });

    test('search and category combine', () {
      expect(search('jpg', category: FileCategory.document), isEmpty);
      expect(search('jpg', category: FileCategory.photo), ['a']);
    });

    test('isFiltering is false for blank search and no category', () {
      expect(const BinQuery(searchText: '  ').isFiltering, isFalse);
      expect(const BinQuery(searchText: 'x').isFiltering, isTrue);
      expect(const BinQuery(category: FileCategory.app).isFiltering, isTrue);
    });
  });

  group('BinSummary', () {
    test('totals everything in the bin', () {
      final summary = BinSummary.of(entries, now: testNow);
      expect(summary.itemCount, 3);
      expect(summary.totalOriginalBytes, 95000);
      expect(summary.totalStoredBytes, 94000);
      expect(summary.bytesSavedByCompression, 1000);
      expect(summary.countFor(FileCategory.photo), 1);
      expect(summary.countFor(FileCategory.video), 1);
      expect(summary.countFor(FileCategory.document), 1);
      expect(summary.countFor(FileCategory.audio), 0);
    });

    test('counts files leaving within three days, including overdue ones', () {
      final summary = BinSummary.of(
        [
          makeEntry(id: '1', expiresAt: testNow.add(const Duration(days: 3))),
          makeEntry(
            id: '2',
            expiresAt: testNow.add(const Duration(days: 3, minutes: 1)),
          ),
          makeEntry(
            id: '3',
            expiresAt: testNow.subtract(const Duration(hours: 1)),
          ),
          makeEntry(id: '4'),
        ],
        now: testNow,
      );
      expect(summary.expiringSoonCount, 2);
    });

    test('a file that grew when compressed does not reduce the savings', () {
      final summary = BinSummary.of(
        [
          makeEntry(id: '1', originalSizeBytes: 100, storedSizeBytes: 120),
          makeEntry(id: '2', originalSizeBytes: 100, storedSizeBytes: 60),
        ],
        now: testNow,
      );
      expect(summary.bytesSavedByCompression, 40);
    });

    test('empty summary', () {
      expect(BinSummary.empty.itemCount, 0);
      expect(BinSummary.of(const [], now: testNow).itemCount, 0);
    });
  });

  group('BinEntry', () {
    test('originalFolder drops the file name', () {
      expect(makeEntry(originalPath: '/DCIM/Camera/a.jpg').originalFolder,
          '/DCIM/Camera');
      expect(makeEntry(originalPath: r'C:\Users\Jas\b.png').originalFolder,
          r'C:\Users\Jas');
      expect(makeEntry(originalPath: '/a.jpg').originalFolder, '/');
      expect(makeEntry(originalPath: 'a.jpg').originalFolder, '');
    });
  });
}
