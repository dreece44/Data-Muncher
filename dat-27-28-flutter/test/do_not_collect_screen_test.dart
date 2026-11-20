import 'package:datamuncher/application/exclusion/exclusion_list.dart';
import 'package:datamuncher/presentation/exclusion/do_not_collect_screen.dart';
import 'package:datamuncher/presentation/exclusion/do_not_collect_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  late ExclusionList exclusions;

  setUp(() async {
    exclusions = ExclusionList(clock: () => testNow);
    await exclusions.load(MemoryExclusionStore());
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
        MaterialApp(home: DoNotCollectScreen(exclusions: exclusions)));
    await tester.pumpAndSettle();
  }

  testWidgets('explains an empty list', (tester) async {
    await pumpScreen(tester);
    expect(find.text('Nothing is excluded'), findsOneWidget);
  });

  testWidgets('lists files and apps with when they end', (tester) async {
    await exclusions.exclude('a',
        kind: ExcludedKind.file, label: 'beach.jpg');
    await pumpScreen(tester);

    expect(find.text('beach.jpg'), findsOneWidget);
    expect(find.text('Recovered file · Until Nov 6, 2026 · 30 days left'),
        findsOneWidget);
  });

  testWidgets('kept apps are listed too, ending soonest first',
      (tester) async {
    var now = testNow;
    final list = ExclusionList(clock: () => now);
    await list.load(MemoryExclusionStore());
    await list.exclude('a', kind: ExcludedKind.file, label: 'beach.jpg');
    now = testNow.add(const Duration(days: 2));
    await list.exclude('com.example.game',
        kind: ExcludedKind.app, label: 'Game');

    await tester.pumpWidget(
        MaterialApp(home: DoNotCollectScreen(exclusions: list)));
    await tester.pumpAndSettle();

    expect(find.text('Kept app · Until Nov 8, 2026 · 30 days left'),
        findsOneWidget);
    expect(tester.getTopLeft(find.text('beach.jpg')).dy,
        lessThan(tester.getTopLeft(find.text('Game')).dy));
  });

  testWidgets('Allow removes an entry, and Undo puts it back',
      (tester) async {
    await exclusions.exclude('a',
        kind: ExcludedKind.file, label: 'beach.jpg');
    await pumpScreen(tester);

    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();

    expect(exclusions.isExcluded('a'), isFalse);
    expect(find.text('Nothing is excluded'), findsOneWidget);
    expect(
        find.text('beach.jpg can be collected again from the next scan.'),
        findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(exclusions.isExcluded('a'), isTrue);
    expect(find.text('beach.jpg'), findsOneWidget);
  });

  testWidgets('ended entries are cleared when the screen opens',
      (tester) async {
    var now = testNow;
    final list = ExclusionList(clock: () => now);
    final store = MemoryExclusionStore();
    await list.load(store);
    await list.exclude('old', kind: ExcludedKind.file);
    now = testNow.add(const Duration(days: 40));

    await tester.pumpWidget(MaterialApp(home: DoNotCollectScreen(exclusions: list)));
    await tester.pumpAndSettle();

    expect(find.text('Nothing is excluded'), findsOneWidget);
    expect(store.values[ExclusionList.storageKey], isEmpty);
  });

  test('describeExclusionEnd', () {
    Exclusion endingIn(Duration d) => Exclusion(
        id: 'x',
        kind: ExcludedKind.file,
        excludedAt: testNow,
        until: testNow.add(d));
    expect(describeExclusionEnd(endingIn(const Duration(days: 1)), testNow),
        'Until Oct 8, 2026 · 1 day left');
    expect(describeExclusionEnd(endingIn(const Duration(hours: 3)), testNow),
        'Until Oct 7, 2026 · ends today');
  });

  group('Do not collect dialog', () {
    Future<bool?> openAndTap(WidgetTester tester, String button) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDoNotCollectDialog(
                context,
                title: 'Do not collect?',
                message: 'Stop collecting beach.jpg for '
                    '$exclusionPeriodLabel?',
                confirmLabel: 'Do not collect',
                declineLabel: 'Just recover',
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Stop collecting beach.jpg for 30 days?'),
          findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('confirming returns true', (tester) async {
      expect(await openAndTap(tester, 'Do not collect'), isTrue);
    });

    testWidgets('declining returns false', (tester) async {
      expect(await openAndTap(tester, 'Just recover'), isFalse);
    });
  });
}
