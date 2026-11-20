import 'package:datamuncher/application/apps/unused_apps.dart';
import 'package:datamuncher/data/apps/installed_app.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_app_inventory.dart';
import 'support/fixtures.dart';

void main() {
  List<String> names(List<UnusedApp> found) =>
      [for (final u in found) u.app.label];

  test('finds apps not opened in 90 days, largest first', () {
    final found = findUnusedApps(sampleApps(), now: testNow);
    expect(names(found), ['Puzzle Quest', 'Lingua+']);
    expect(found[0].reason, 'Last opened 200 days ago');
    expect(found[0].daysUnused, 200);
    expect(found[1].reason, 'Not opened in at least 90 days');
    expect(found[1].daysUnused, isNull);
  });

  test('never suggests system, essential, recent or recently used apps', () {
    final found = names(findUnusedApps(sampleApps(), now: testNow));
    expect(found, isNot(contains('Settings')));
    expect(found, isNot(contains('Keyboard')));
    expect(found, isNot(contains('New Game')));
    expect(found, isNot(contains('Maps')));
  });

  test('the cut-off is exact', () {
    InstalledApp app(int lastUsedDaysAgo) => InstalledApp(
          packageName: 'p$lastUsedDaysAgo',
          label: 'App $lastUsedDaysAgo',
          sizeBytes: 1,
          installedAt: daysAgo(1000),
          lastUsedAt: daysAgo(lastUsedDaysAgo),
        );
    final found = findUnusedApps([app(89), app(90), app(91)], now: testNow);
    expect(names(found), ['App 91']);
  });

  test('a shorter rule finds more', () {
    final found = findUnusedApps(
      sampleApps(),
      now: testNow,
      rules: const UnusedAppRules(unusedAfter: Duration(days: 7)),
    );
    expect(names(found), ['New Game', 'Puzzle Quest', 'Lingua+']);
  });

  test('kept apps are skipped', () {
    final found = findUnusedApps(
      sampleApps(),
      now: testNow,
      isKept: (pkg) => pkg == 'com.example.puzzle',
    );
    expect(names(found), ['Lingua+']);
  });

  group('InstalledApp.fromJson', () {
    test('reads what Android sends', () {
      final app = InstalledApp.fromJson({
        'packageName': 'com.example.a',
        'label': 'A',
        'sizeBytes': 1234,
        'installedAt': 1700000000000,
        'lastUsedAt': null,
        'isSystem': false,
        'isEssential': true,
      });
      expect(app.label, 'A');
      expect(app.sizeBytes, 1234);
      expect(app.installedAt,
          DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(app.lastUsedAt, isNull);
      expect(app.isEssential, isTrue);
    });

    test('also reads the scan engine JSON shape', () {
      final app = InstalledApp.fromJson({
        'packageName': 'com.example.b',
        'installedAt': '2026-01-02T03:04:05.000',
        'lastUsedAt': 0,
      });
      expect(app.label, 'com.example.b');
      expect(app.sizeBytes, 0);
      expect(app.installedAt, DateTime(2026, 1, 2, 3, 4, 5));
      expect(app.lastUsedAt, isNull, reason: '0 means no record');
    });

    test('rejects an entry without a package name', () {
      expect(() => InstalledApp.fromJson({'label': 'x'}),
          throwsFormatException);
    });
  });
}
