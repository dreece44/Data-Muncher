import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final now = DateTime(2026, 9, 28);
  DateTime daysAgo(int d) => now.subtract(Duration(days: d));

  final apps = [
    InstalledApp(
        packageName: 'old.game',
        label: 'Old Game',
        sizeBytes: 400,
        installedAt: daysAgo(400),
        lastUsedAt: daysAgo(200)),
    InstalledApp(
        packageName: 'never.used',
        label: 'Never Used',
        sizeBytes: 900,
        installedAt: daysAgo(300)),
    InstalledApp(
        packageName: 'daily',
        label: 'Daily',
        sizeBytes: 100,
        installedAt: daysAgo(300),
        lastUsedAt: daysAgo(1)),
    InstalledApp(
        packageName: 'new.install',
        label: 'New',
        sizeBytes: 100,
        installedAt: daysAgo(5)),
    InstalledApp(
        packageName: 'launcher',
        label: 'Launcher',
        sizeBytes: 100,
        installedAt: daysAgo(300),
        isEssential: true),
    InstalledApp(
        packageName: 'system.camera',
        label: 'Camera',
        sizeBytes: 100,
        installedAt: daysAgo(300),
        isSystem: true),
  ];

  Future<ScanReport> run({
    AppInventory? inventory,
    PermissionState usage = PermissionState.granted,
    DevicePlatform platform = DevicePlatform.android,
  }) =>
      ScanEngine(
        device: FakeDevice(
          const {},
          platform: platform,
          apps: inventory,
          permissions: {
            ScanPermission.storage: PermissionState.granted,
            ScanPermission.photos: PermissionState.granted,
            ScanPermission.appUsage: usage,
          },
        ),
        detectors: [const UnusedAppDetector()],
        clock: () => now,
      ).scan();

  test('reports apps not opened for 90+ days, largest first', () async {
    final report = await run(inventory: FakeApps(apps));
    expect([for (final f in report.findings) f.items.single.id],
        ['never.used', 'old.game']);
    expect(report.findings[1].reason, 'Last opened 200 days ago');
    expect(report.findings[0].reason, 'Not opened in at least 90 days');
    expect(report.reclaimableBytesFor(WasteCategory.unusedApp), 1300);
  });

  test('is skipped (not failed) without usage access', () async {
    final report =
        await run(inventory: FakeApps(apps), usage: PermissionState.denied);
    expect(report.categories[WasteCategory.unusedApp]!.state,
        CategoryState.skipped);
    expect(report.findings, isEmpty);
  });

  test('is reported as unsupported where apps cannot be listed (iPhone)',
      () async {
    final report = await run(platform: DevicePlatform.ios);
    final result = report.categories[WasteCategory.unusedApp]!;
    expect(result.state, CategoryState.unsupported);
    expect(result.note, contains("doesn't let apps see"));
  });
}
