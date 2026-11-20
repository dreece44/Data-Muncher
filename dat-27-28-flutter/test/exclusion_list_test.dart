import 'dart:convert';

import 'package:datamuncher/application/exclusion/exclusion_list.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  late DateTime now;
  late MemoryExclusionStore store;
  late ExclusionList list;

  setUp(() async {
    now = testNow;
    store = MemoryExclusionStore();
    list = ExclusionList(clock: () => now);
    await list.load(store);
  });

  test('excluding a file skips it for the chosen period', () async {
    await list.exclude('a', kind: ExcludedKind.file, label: 'beach.jpg');

    expect(list.isExcluded('a'), isTrue);
    expect(list.entryFor('a')!.until, testNow.add(const Duration(days: 30)));

    now = testNow.add(const Duration(days: 29, hours: 23));
    expect(list.isExcluded('a'), isTrue);

    now = testNow.add(const Duration(days: 30));
    expect(list.isExcluded('a'), isFalse,
        reason: 'the period has ended, so scans may collect it again');
  });

  test('files and apps with the same id are kept apart', () async {
    await list.exclude('x', kind: ExcludedKind.app);
    expect(list.isExcluded('x', kind: ExcludedKind.app), isTrue);
    expect(list.isExcluded('x'), isFalse);
  });

  test('excluding again restarts the period', () async {
    await list.exclude('a', kind: ExcludedKind.file);
    now = testNow.add(const Duration(days: 20));
    await list.exclude('a', kind: ExcludedKind.file);
    expect(list.entryFor('a')!.until, now.add(const Duration(days: 30)));
    expect(list.count(), 1);
  });

  test('every mark lasts exactly 30 days', () {
    expect(exclusionPeriod, const Duration(days: 30));
  });

  test('active list: soonest end first', () async {
    await list.exclude('first', kind: ExcludedKind.file, label: 'B');
    now = testNow.add(const Duration(days: 5));
    await list.exclude('later', kind: ExcludedKind.file, label: 'A');
    await list.exclude('app', kind: ExcludedKind.app, label: 'C');

    expect([for (final e in list.active) e.id], ['first', 'later', 'app']);
    expect(list.count(kind: ExcludedKind.app), 1);
    expect(list.count(kind: ExcludedKind.file), 2);
  });

  test('ended entries are not listed and purgeExpired forgets them',
      () async {
    await list.exclude('a', kind: ExcludedKind.file);
    now = testNow.add(const Duration(days: 10));
    await list.exclude('b', kind: ExcludedKind.file);
    now = testNow.add(const Duration(days: 31));

    expect([for (final e in list.active) e.id], ['b']);
    expect(await list.purgeExpired(), 1);
    expect(store.values[ExclusionList.storageKey], hasLength(1));
  });

  test('remove, removeAll and restore', () async {
    await list.excludeAll({'a': 'one.jpg', 'b': null, 'c': 'three.jpg'},
        kind: ExcludedKind.file);
    expect(list.count(), 3);
    expect(list.entryFor('b')!.displayName, 'Recovered file');

    final removed = await list.remove('a');
    expect(removed!.label, 'one.jpg');
    expect(list.isExcluded('a'), isFalse);
    expect(await list.remove('a'), isNull);

    expect(await list.removeAll(['b', 'c', 'missing']), 2);
    expect(list.count(), 0);

    await list.restore(removed);
    expect(list.entryFor('a'), removed);
  });

  test('notifies listeners on change', () async {
    var calls = 0;
    list.addListener(() => calls++);
    await list.exclude('a', kind: ExcludedKind.file);
    await list.remove('a');
    await list.removeAll(['nothing']);
    expect(calls, 2);
  });

  test('saves and loads back', () async {
    await list.exclude('a',
        kind: ExcludedKind.file, label: 'beach.jpg');
    await list.exclude('com.example.game',
        kind: ExcludedKind.app, label: 'Game');

    final reloaded = ExclusionList(clock: () => now);
    await reloaded.load(store);

    expect(reloaded.entryFor('a'), list.entryFor('a'));
    expect(reloaded.entryFor('com.example.game', kind: ExcludedKind.app)!.label,
        'Game');
  });

  test('moves entries from the old format and drops ended ones', () async {
    final future = testNow.add(const Duration(days: 10));
    final past = testNow.subtract(const Duration(days: 1));
    final old = MemoryExclusionStore({
      ExclusionList.legacyStorageKey: [
        'keep|${future.millisecondsSinceEpoch}',
        'ab|c/L0/001|${future.millisecondsSinceEpoch}',
        'ended|${past.millisecondsSinceEpoch}',
        'junk',
      ],
    });
    final migrated = ExclusionList(clock: () => now);
    await migrated.load(old);

    expect([for (final e in migrated.active) e.id]..sort(),
        ['ab|c/L0/001', 'keep']);
    expect(migrated.entryFor('keep')!.until, future);
    expect(old.values.containsKey(ExclusionList.legacyStorageKey), isFalse);
    expect(old.values[ExclusionList.storageKey], hasLength(2));
  });

  test('a damaged saved entry does not lose the rest', () async {
    final good = jsonEncode(Exclusion(
      id: 'a',
      kind: ExcludedKind.file,
      excludedAt: testNow,
      until: testNow.add(const Duration(days: 30)),
    ).toJson());
    final damaged = MemoryExclusionStore({
      ExclusionList.storageKey: [good, '{not json', '{"id": 5}', '[]'],
    });
    final loaded = ExclusionList(clock: () => now);
    await loaded.load(damaged);
    expect([for (final e in loaded.active) e.id], ['a']);
  });
}
