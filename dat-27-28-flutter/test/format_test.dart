import 'package:datamuncher/presentation/garbage_bin/format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  group('formatBytes', () {
    test('shows plain bytes under 1 KB', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
    });

    test('one decimal under 100, none from 100 up', () {
      expect(formatBytes(1500), '1.5 KB');
      expect(formatBytes(2000000), '2 MB');
      expect(formatBytes(4200000), '4.2 MB');
      expect(formatBytes(123456789), '123 MB');
      expect(formatBytes(1240000000), '1.2 GB');
    });

    test('rolls over to the next unit instead of showing 1000', () {
      expect(formatBytes(999400), '999 KB');
      expect(formatBytes(999600), '1 MB');
    });
  });

  group('formatCollectedAt', () {
    test('today, yesterday, and days ago', () {
      expect(formatCollectedAt(testNow.subtract(const Duration(hours: 5)), testNow),
          'Today');
      expect(formatCollectedAt(testNow.subtract(const Duration(days: 1)), testNow),
          'Yesterday');
      expect(formatCollectedAt(testNow.subtract(const Duration(days: 3)), testNow),
          '3 days ago');
    });

    test('goes by calendar day, not 24-hour periods', () {
      final lateLastNight = DateTime(2026, 10, 6, 23, 30);
      final earlyToday = DateTime(2026, 10, 7, 0, 30);
      expect(formatCollectedAt(lateLastNight, earlyToday), 'Yesterday');
    });

    test('shows a date once it is a week old', () {
      expect(formatCollectedAt(testNow.subtract(const Duration(days: 10)), testNow),
          'Sep 27, 2026');
    });

    test('a slightly future time (clock skew) counts as today', () {
      expect(formatCollectedAt(testNow.add(const Duration(minutes: 5)), testNow),
          'Today');
    });
  });

  group('formatTimeLeft', () {
    test('days left', () {
      expect(formatTimeLeft(testNow.add(const Duration(days: 2)), testNow),
          '2 days left');
      expect(formatTimeLeft(testNow.add(const Duration(days: 1, hours: 5)), testNow),
          '1 day left');
    });

    test('under a day, and overdue', () {
      expect(formatTimeLeft(testNow.add(const Duration(hours: 5)), testNow),
          'Less than a day left');
      expect(formatTimeLeft(testNow, testNow), 'Due for removal');
      expect(formatTimeLeft(testNow.subtract(const Duration(hours: 1)), testNow),
          'Due for removal');
    });
  });

  test('formatDate', () {
    expect(formatDate(DateTime(2026, 1, 3)), 'Jan 3, 2026');
  });

  test('pluralize', () {
    expect(pluralize(0, 'file'), '0 files');
    expect(pluralize(1, 'file'), '1 file');
    expect(pluralize(12, 'file'), '12 files');
  });
}
