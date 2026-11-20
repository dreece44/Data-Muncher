import 'package:datamuncher/application/garbage_bin/empty_bin.dart';
import 'package:datamuncher/presentation/garbage_bin/format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  const trash = Duration(days: 30);
  // p1 4.2 MB, v1 900 MB, d1 350 KB
  final before = sampleEntries();

  EmptyBinReport report(Set<String> removed, {Duration? restorable}) =>
      EmptyBinReport.of(
        before,
        EmptyBinOutcome(removedIds: removed, restorableFor: restorable),
      );

  group('EmptyBinReport', () {
    test('counts only files the user saw', () {
      final r = report({'p1', 'd1', 'stale-id'});
      expect(r.requestedCount, 3);
      expect(r.removedCount, 2);
      expect(r.removedBytes, 4200000 + 350000);
      expect(r.keptCount, 1);
    });

    test('nothing removed', () {
      final r = EmptyBinReport.of(before, EmptyBinOutcome.nothingRemoved);
      expect(r.removedCount, 0);
      expect(r.keptCount, 3);
    });
  });

  group('describeEmptyBin', () {
    test('nothing removed', () {
      expect(describeEmptyBin(report({})),
          'Nothing was deleted. Your files are still in the bin.');
    });

    test('everything, permanently', () {
      expect(describeEmptyBin(report({'p1', 'v1', 'd1'})),
          'Emptied the bin and freed 905 MB.');
    });

    test('everything, to the trash', () {
      expect(
        describeEmptyBin(report({'p1', 'v1', 'd1'}, restorable: trash)),
        "Emptied the bin: 3 files (905 MB). You can restore them from your "
        "phone's trash for 30 days; the space is freed after that.",
      );
    });

    test('some, permanently', () {
      expect(describeEmptyBin(report({'p1', 'd1'})),
          'Deleted 2 files and freed 4.5 MB. 1 file is still in the bin.');
    });

    test('one, to the trash', () {
      expect(
        describeEmptyBin(report({'v1'}, restorable: trash)),
        'Removed 1 file (900 MB) from the bin. 2 files are still in the bin. '
        "You can restore it from your phone's trash for 30 days; "
        'the space is freed after that.',
      );
    });
  });
}
