import 'package:datamuncher/core.dart';
import 'package:datamuncher/data/garbage_bin/bin_entry.dart';
import 'package:datamuncher/rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Verdict v(WasteCategory c, String rule) => Verdict('a', c, rule, '');

  group('reasonForVerdicts', () {
    test('not flagged', () {
      expect(reasonForVerdicts(const []), isNull);
    });

    test('unreadable and black screen', () {
      expect(reasonForVerdicts([v(WasteCategory.empty, 'R1-unreadable')]),
          CollectionReason.unreadable);
      expect(reasonForVerdicts([v(WasteCategory.empty, 'R2-black-frame')]),
          CollectionReason.blank);
    });

    test('duplicate wins over blurry', () {
      expect(
        reasonForVerdicts([
          v(WasteCategory.blurry, 'R3-blurry'),
          v(WasteCategory.duplicate, 'R4-duplicate'),
        ]),
        CollectionReason.duplicate,
      );
      expect(reasonForVerdicts([v(WasteCategory.blurry, 'R3-blurry')]),
          CollectionReason.blurry);
    });
  });

  group('BinRecord', () {
    test('round-trips, including ids that contain |', () {
      final when = DateTime.fromMillisecondsSinceEpoch(1790000000000);
      final record = BinRecord(CollectionReason.duplicate, when);
      final decoded = BinRecord.decode(record.encode('ab|c/L0/001'))!;
      expect(decoded.key, 'ab|c/L0/001');
      expect(decoded.value.reason, CollectionReason.duplicate);
      expect(decoded.value.collectedAt, when);
    });

    test('unknown reason falls back to other; junk is ignored', () {
      expect(BinRecord.decode('id|nonsense|5')!.value.reason,
          CollectionReason.other);
      expect(BinRecord.decode('garbage'), isNull);
      expect(BinRecord.decode('id|duplicate|notanumber'), isNull);
    });
  });
}
