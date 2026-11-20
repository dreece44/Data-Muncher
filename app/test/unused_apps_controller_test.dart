import 'dart:async';

import 'package:datamuncher/application/apps/unused_apps_controller.dart';
import 'package:datamuncher/application/exclusion/exclusion_list.dart';
import 'package:datamuncher/data/apps/app_inventory.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_app_inventory.dart';
import 'support/fixtures.dart';

void main() {
  late FakeAppInventory inventory;
  late ExclusionList exclusions;
  late UnusedAppsController controller;

  setUp(() async {
    inventory = FakeAppInventory();
    exclusions = ExclusionList(clock: () => testNow);
    await exclusions.load(MemoryExclusionStore());
    controller =
        UnusedAppsController(inventory: inventory, exclusions: exclusions);
  });

  tearDown(() => controller.dispose());

  List<String> names() => [for (final u in controller.unused) u.app.label];

  test('lists unused apps once usage access is on', () async {
    expect(controller.status, UnusedAppsStatus.loading);
    expect(controller.count, isNull);

    await controller.load();

    expect(controller.status, UnusedAppsStatus.ready);
    expect(names(), ['Puzzle Quest', 'Lingua+']);
    expect(controller.count, 2);
    expect(controller.totalBytes, 430000000);
  });

  test('asks for usage access, then loads when the user comes back',
      () async {
    inventory.access = AppAccess.needsUsageAccess;
    await controller.load();
    expect(controller.status, UnusedAppsStatus.needsAccess);
    expect(inventory.listCalls, 0, reason: 'nothing is read without access');

    await controller.openUsageAccessSettings();
    expect(inventory.openSettingsCalls, 1);

    inventory.access = AppAccess.granted;
    await controller.onResumed();
    expect(controller.status, UnusedAppsStatus.ready);
    expect(controller.count, 2);
  });

  test('losing usage access clears the list', () async {
    await controller.load();
    inventory.access = AppAccess.needsUsageAccess;
    await controller.onResumed();
    expect(controller.status, UnusedAppsStatus.needsAccess);
    expect(controller.unused, isEmpty);
  });

  test('iPhone is unsupported and is not re-checked on resume', () async {
    final iphone = UnusedAppsController(
        inventory: const UnsupportedAppInventory(), exclusions: exclusions);
    addTearDown(iphone.dispose);
    await iphone.load();
    expect(iphone.status, UnusedAppsStatus.unsupported);
    await iphone.onResumed();
    expect(iphone.status, UnusedAppsStatus.unsupported);
  });

  test('missing Android code gives the setup message', () async {
    inventory.listError = MissingPluginException('no handler');
    await controller.load();
    expect(controller.status, UnusedAppsStatus.failed);
    expect(controller.error, appInventoryNotSetUpMessage);
  });

  test('other failures can be retried', () async {
    inventory.listError = PlatformException(code: 'failed');
    await controller.load();
    expect(controller.status, UnusedAppsStatus.failed);

    inventory.listError = null;
    await controller.load();
    expect(controller.status, UnusedAppsStatus.ready);
  });

  test('uninstalling removes the app from the list', () async {
    await controller.load();
    final puzzle = controller.unused.first;

    expect(await controller.uninstall(puzzle), isTrue);
    expect(inventory.uninstallCalls, ['com.example.puzzle']);
    expect(names(), ['Lingua+']);
  });

  test('cancelling Android\'s uninstall dialog keeps the app', () async {
    await controller.load();
    inventory.confirmUninstall = false;
    expect(await controller.uninstall(controller.unused.first), isFalse);
    expect(names(), ['Puzzle Quest', 'Lingua+']);
  });

  test('marks an app as uninstalling and ignores a second tap', () async {
    await controller.load();
    final puzzle = controller.unused.first;
    inventory.pendingUninstall = Completer<bool>();

    final first = controller.uninstall(puzzle);
    expect(controller.isUninstalling('com.example.puzzle'), isTrue);
    expect(await controller.uninstall(puzzle), isFalse);

    inventory.pendingUninstall!.complete(true);
    expect(await first, isTrue);
    expect(controller.isUninstalling('com.example.puzzle'), isFalse);
    expect(inventory.uninstallCalls, hasLength(1));
  });

  test('keeping an app hides it and adds it to the Do-not-collect list',
      () async {
    await controller.load();
    final lingua = controller.unused[1];

    final entry = await controller.keep(lingua);

    expect(names(), ['Puzzle Quest']);
    expect(entry.kind, ExcludedKind.app);
    expect(entry.label, 'Lingua+');
    expect(entry.until, testNow.add(const Duration(days: 30)));
    expect(exclusions.isExcluded('com.example.lingua', kind: ExcludedKind.app),
        isTrue);

    // Allowing it again (from the Do-not-collect list) brings it back.
    await exclusions.remove('com.example.lingua', kind: ExcludedKind.app);
    expect(names(), ['Puzzle Quest', 'Lingua+']);
  });
}
