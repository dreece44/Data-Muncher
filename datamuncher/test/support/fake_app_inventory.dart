import 'dart:async';
import 'dart:typed_data';

import 'package:datamuncher/data/apps/app_inventory.dart';
import 'package:datamuncher/data/apps/installed_app.dart';

import 'fixtures.dart';

/// An [AppInventory] the test controls.
class FakeAppInventory implements AppInventory {
  FakeAppInventory({
    this.access = AppAccess.granted,
    List<InstalledApp>? apps,
  }) : apps = apps ?? sampleApps();

  AppAccess access;
  List<InstalledApp> apps;
  Object? listError;

  /// What the user does in Android's uninstall dialog.
  bool confirmUninstall = true;
  final List<String> uninstallCalls = [];
  int openSettingsCalls = 0;
  int listCalls = 0;

  /// When set, uninstall waits for the test to complete it.
  Completer<bool>? pendingUninstall;

  @override
  Future<AppAccess> checkAccess() async => access;

  @override
  Future<void> openUsageAccessSettings() async => openSettingsCalls++;

  @override
  Future<List<InstalledApp>> listApps() async {
    listCalls++;
    final error = listError;
    if (error != null) throw error;
    return List.of(apps);
  }

  @override
  Future<Uint8List?> appIcon(String packageName) async => null;

  @override
  Future<bool> uninstall(String packageName) async {
    uninstallCalls.add(packageName);
    final gone = await (pendingUninstall?.future ?? Future.value(confirmUninstall));
    if (gone) apps.removeWhere((a) => a.packageName == packageName);
    return gone;
  }
}

/// Days before [testNow].
DateTime daysAgo(int days) => testNow.subtract(Duration(days: days));

/// - Puzzle Quest: 310 MB, last opened 200 days ago → unused
/// - Lingua+: 120 MB, never opened, installed a year ago → unused
/// - Maps: opened yesterday → used
/// - New Game: installed 10 days ago, never opened → too new
/// - Keyboard: essential → never suggested
/// - Settings: system → never suggested
List<InstalledApp> sampleApps() => [
      InstalledApp(
        packageName: 'com.example.puzzle',
        label: 'Puzzle Quest',
        sizeBytes: 310000000,
        installedAt: daysAgo(400),
        lastUsedAt: daysAgo(200),
      ),
      InstalledApp(
        packageName: 'com.example.lingua',
        label: 'Lingua+',
        sizeBytes: 120000000,
        installedAt: daysAgo(365),
      ),
      InstalledApp(
        packageName: 'com.example.maps',
        label: 'Maps',
        sizeBytes: 90000000,
        installedAt: daysAgo(500),
        lastUsedAt: daysAgo(1),
      ),
      InstalledApp(
        packageName: 'com.example.newgame',
        label: 'New Game',
        sizeBytes: 800000000,
        installedAt: daysAgo(10),
      ),
      InstalledApp(
        packageName: 'com.example.keyboard',
        label: 'Keyboard',
        sizeBytes: 40000000,
        installedAt: daysAgo(700),
        isEssential: true,
      ),
      InstalledApp(
        packageName: 'com.android.settings',
        label: 'Settings',
        sizeBytes: 50000000,
        installedAt: daysAgo(900),
        isSystem: true,
      ),
    ];
