import 'package:datamuncher/application/storage_alert/storage_alert.dart';
import 'package:datamuncher/core.dart';
import 'package:datamuncher/presentation/storage_alert/storage_alert_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const int gb = 1024 * 1024 * 1024;

StorageReading reading(double freeGb, double totalGb) =>
    StorageReading(freeBytes: (freeGb * gb).round(), totalBytes: (totalGb * gb).round());

void main() {
  const policy = StorageAlertPolicy();
  final t0 = DateTime(2026, 11, 10, 9);

  group('StorageAlertPolicy.levelOf', () {
    test('small phone (32 GB) warns by share: low under 3.2 GB, critical under 1 GB', () {
      expect(policy.levelOf(reading(4, 32)), StorageLevel.ok);
      expect(policy.levelOf(reading(3, 32)), StorageLevel.low);
      expect(policy.levelOf(reading(0.9, 32)), StorageLevel.critical);
    });

    test('large phone (512 GB) warns by amount, not at 50 GB free', () {
      expect(policy.levelOf(reading(50, 512)), StorageLevel.ok);
      expect(policy.levelOf(reading(4.5, 512)), StorageLevel.low);
      expect(policy.levelOf(reading(0.5, 512)), StorageLevel.critical);
    });

    test('tiny phone (8 GB) uses the 5% share for critical', () {
      expect(policy.levelOf(reading(0.5, 8)), StorageLevel.low);
      expect(policy.levelOf(reading(0.3, 8)), StorageLevel.critical);
    });

    test('a missing or nonsense reading never warns', () {
      expect(policy.levelOf(const StorageReading(freeBytes: 0, totalBytes: 0)), StorageLevel.ok);
      expect(policy.levelOf(reading(10, 5)), StorageLevel.ok);
    });

    test('fromMb converts disk_space_plus megabytes', () {
      final r = StorageReading.fromMb(freeMb: 1024, totalMb: 32768);
      expect(r.freeBytes, gb);
      expect(r.totalBytes, 32 * gb);
    });
  });

  group('decideStorageAlert', () {
    StorageAlertDecision decide(StorageReading r, StorageAlertMemory m, DateTime now) =>
        decideStorageAlert(reading: r, memory: m, now: now);

    test('plenty of space: nothing to do', () {
      final d = decide(reading(20, 64), const StorageAlertMemory(), t0);
      expect(d.action, StorageAlertAction.none);
      expect(d.memory.level, StorageLevel.ok);
    });

    test('first time low: notify and remember', () {
      final d = decide(reading(3, 64), const StorageAlertMemory(), t0);
      expect(d.action, StorageAlertAction.notify);
      expect(d.level, StorageLevel.low);
      expect(d.memory.notifiedAt, t0);
    });

    test('still low an hour later: stay quiet', () {
      final m = StorageAlertMemory(level: StorageLevel.low, notifiedAt: t0);
      final d = decide(reading(2.8, 64), m, t0.add(const Duration(hours: 1)));
      expect(d.action, StorageAlertAction.none);
      expect(d.memory.notifiedAt, t0);
    });

    test('still low a day later: remind', () {
      final m = StorageAlertMemory(level: StorageLevel.low, notifiedAt: t0);
      final d = decide(reading(2.8, 64), m, t0.add(const Duration(hours: 24)));
      expect(d.action, StorageAlertAction.notify);
    });

    test('low turns critical: notify right away', () {
      final m = StorageAlertMemory(level: StorageLevel.low, notifiedAt: t0);
      final d = decide(reading(0.5, 64), m, t0.add(const Duration(minutes: 15)));
      expect(d.action, StorageAlertAction.notify);
      expect(d.level, StorageLevel.critical);
    });

    test('critical eases to low: no new alert, keeps the reminder clock', () {
      final m = StorageAlertMemory(level: StorageLevel.critical, notifiedAt: t0);
      final d = decide(reading(3, 64), m, t0.add(const Duration(hours: 2)));
      expect(d.action, StorageAlertAction.none);
      expect(d.memory.level, StorageLevel.low);
      expect(d.memory.notifiedAt, t0);
    });

    test('space freed: clear the notification and forget', () {
      final m = StorageAlertMemory(level: StorageLevel.critical, notifiedAt: t0);
      final d = decide(reading(20, 64), m, t0.add(const Duration(hours: 2)));
      expect(d.action, StorageAlertAction.clear);
      expect(d.memory.level, StorageLevel.ok);
      expect(d.memory.notifiedAt, isNull);
    });

    test('clock set back: treat the reminder as due rather than never', () {
      final m = StorageAlertMemory(level: StorageLevel.low, notifiedAt: t0);
      final d = decide(reading(3, 64), m, t0.subtract(const Duration(days: 3)));
      expect(d.action, StorageAlertAction.notify);
    });
  });

  group('StorageAlertMemory', () {
    test('round-trips', () {
      final m = StorageAlertMemory(level: StorageLevel.critical, notifiedAt: t0);
      final back = StorageAlertMemory.decode(m.encode());
      expect(back.level, StorageLevel.critical);
      expect(back.notifiedAt, t0);
      expect(StorageAlertMemory.decode(const StorageAlertMemory().encode()).level, StorageLevel.ok);
    });

    test('bad or missing data falls back to nothing shown', () {
      expect(StorageAlertMemory.decode(null).level, StorageLevel.ok);
      expect(StorageAlertMemory.decode('garbage').level, StorageLevel.ok);
      expect(StorageAlertMemory.decode('low|notanumber').notifiedAt, isNull);
    });
  });

  group('StorageAlertMessage', () {
    test('critical mentions the camera risk and space left', () {
      final m = StorageAlertMessage.of(StorageLevel.critical, reading(0.5, 64));
      expect(m.title, 'Storage almost full');
      expect(m.body, contains('512 MB'));
      expect(m.body, contains('photos and videos may not save'));
    });

    test('low shows free space and percent', () {
      final m = StorageAlertMessage.of(StorageLevel.low, reading(3.2, 64));
      expect(m.title, 'Storage running low');
      expect(m.body, startsWith('3.2 GB free (5%)'));
    });
  });

  test('MunchState takes its warning level from the reading', () {
    final s = MunchState();
    s.setStorageReading(reading(0.5, 128));
    expect(s.storageLevel, StorageLevel.critical);
    s.setStorageReading(reading(40, 128));
    expect(s.storageLevel, StorageLevel.ok);
  });

  group('StorageAlertBanner', () {
    // Small phone (iPhone SE / compact Android) and an XL text setting.
    for (final (name, size, scale) in [
      ('small phone', const Size(320, 568), 1.0),
      ('small phone, 200% text', const Size(320, 568), 2.0),
      ('tablet', const Size(1024, 1366), 1.3),
    ]) {
      testWidgets('fits on $name', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var tapped = false;
        await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: ListView(padding: const EdgeInsets.all(16), children: [
                StorageAlertBanner(
                  level: StorageLevel.critical,
                  reading: reading(0.4, 32),
                  onFreeUp: () => tapped = true,
                ),
              ]),
            ),
          ),
        ));
        expect(tester.takeException(), isNull);
        expect(find.text('Storage almost full'), findsOneWidget);
        // With large text the button can sit below the fold; the list scrolls.
        await tester.ensureVisible(find.text('FREE UP SPACE'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('FREE UP SPACE'));
        expect(tapped, isTrue);
      });
    }
  });
}
