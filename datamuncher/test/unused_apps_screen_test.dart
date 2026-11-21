import 'package:datamuncher/application/apps/unused_apps_controller.dart';
import 'package:datamuncher/application/exclusion/exclusion_list.dart';
import 'package:datamuncher/data/apps/app_inventory.dart';
import 'package:datamuncher/presentation/apps/app_icon.dart';
import 'package:datamuncher/presentation/apps/unused_apps_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_app_inventory.dart';
import 'support/fixtures.dart';

void main() {
  late ExclusionList exclusions;

  setUp(() async {
    exclusions = ExclusionList(clock: () => testNow);
    await exclusions.load(MemoryExclusionStore());
  });

  Future<UnusedAppsController> pumpScreen(
    WidgetTester tester,
    AppInventory inventory, {
    VoidCallback? onOpenDoNotCollect,
  }) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller =
        UnusedAppsController(inventory: inventory, exclusions: exclusions);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: UnusedAppsScreen(
        controller: controller,
        icons: AppIconCache(inventory.appIcon),
        onOpenDoNotCollect: onOpenDoNotCollect,
      ),
    ));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> dismissSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('lists unused apps with why and how big', (tester) async {
    await pumpScreen(tester, FakeAppInventory());

    expect(find.text('2 unused apps · 430 MB'), findsOneWidget);
    expect(find.text('Puzzle Quest'), findsOneWidget);
    expect(find.text('Last opened 200 days ago · 310 MB'), findsOneWidget);
    expect(find.text('Not opened in at least 90 days · 120 MB'),
        findsOneWidget);
    expect(find.text('Maps'), findsNothing);
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('asks for usage access and loads after coming back',
      (tester) async {
    final inventory =
        FakeAppInventory(access: AppAccess.needsUsageAccess);
    await pumpScreen(tester, inventory);

    expect(find.text('Allow usage access'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(inventory.openSettingsCalls, 1);

    inventory.access = AppAccess.granted;
    // Leave for Settings and come back, one valid step at a time.
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();

    expect(find.text('Puzzle Quest'), findsOneWidget);
  });

  testWidgets('explains that iPhone does not allow it', (tester) async {
    await pumpScreen(tester, const UnsupportedAppInventory());
    expect(find.text('Not available on iPhone'), findsOneWidget);
  });

  testWidgets('shows the setup step when the Android code is missing',
      (tester) async {
    final inventory = FakeAppInventory()
      ..listError = MissingPluginException('none');
    await pumpScreen(tester, inventory);

    expect(find.text(appInventoryNotSetUpMessage), findsOneWidget);

    inventory.listError = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Puzzle Quest'), findsOneWidget);
  });

  testWidgets('says so when nothing is unused', (tester) async {
    await pumpScreen(tester, FakeAppInventory(apps: []));
    expect(find.text('No unused apps'), findsOneWidget);
  });

  testWidgets('details sheet, then Uninstall removes the app',
      (tester) async {
    final inventory = FakeAppInventory();
    await pumpScreen(tester, inventory);

    await tester.tap(find.text('Puzzle Quest'));
    await tester.pumpAndSettle();
    expect(find.text('Why it was flagged'), findsOneWidget);
    expect(find.text('Mar 21, 2026'), findsOneWidget);
    expect(find.text('com.example.puzzle'), findsOneWidget);

    await tester.tap(find.text('Uninstall'));
    await tester.pumpAndSettle();

    expect(inventory.uninstallCalls, ['com.example.puzzle']);
    expect(find.text('Uninstalled Puzzle Quest and freed 310 MB.'),
        findsOneWidget);
    expect(find.text('Puzzle Quest'), findsNothing);
    expect(find.text('1 unused app · 120 MB'), findsOneWidget);
    await dismissSnackBar(tester);
  });

  testWidgets('cancelling Android\'s dialog keeps the app', (tester) async {
    final inventory = FakeAppInventory()..confirmUninstall = false;
    await pumpScreen(tester, inventory);

    await tester.tap(find.text('Puzzle Quest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uninstall'));
    await tester.pumpAndSettle();

    expect(find.text("Puzzle Quest wasn't uninstalled."), findsOneWidget);
    expect(find.text('Puzzle Quest'), findsOneWidget);
    await dismissSnackBar(tester);
  });

  testWidgets('Keep hides the app for 30 days (DAT-32)',
      (tester) async {
    await pumpScreen(tester, FakeAppInventory());

    await tester.tap(find.text('Lingua+'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();

    expect(find.text('Keep Lingua+?'), findsOneWidget);
    expect(
        find.text("DataMuncher won't suggest removing it again for 30 days."),
        findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Keep'));
    await tester.pumpAndSettle();

    expect(find.text("Lingua+ won't be suggested until Nov 6, 2026."),
        findsOneWidget);
    expect(find.text('Lingua+'), findsNothing);
    expect(exclusions.isExcluded('com.example.lingua', kind: ExcludedKind.app),
        isTrue);
    await dismissSnackBar(tester);
  });

  testWidgets('cancelling Keep changes nothing', (tester) async {
    await pumpScreen(tester, FakeAppInventory());

    await tester.tap(find.text('Lingua+'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Lingua+'), findsOneWidget);
    expect(exclusions.count(), 0);
  });

  testWidgets('links to the Do-not-collect list', (tester) async {
    var opened = 0;
    await pumpScreen(tester, FakeAppInventory(),
        onOpenDoNotCollect: () => opened++);
    await tester.tap(find.byTooltip('Do-not-collect list'));
    expect(opened, 1);
  });
}
