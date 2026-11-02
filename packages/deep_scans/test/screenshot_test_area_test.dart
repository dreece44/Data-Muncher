import 'dart:io';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

/// Builds the screenshot test area in a temp folder and checks every
/// planted image, exactly as the CLI's verify mode does.
void main() {
  late Directory temp;
  late ScreenshotTestArea area;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('deep_scans_shots_');
    area = await buildScreenshotTestArea('${temp.path}/area');
  });
  tearDownAll(() => temp.deleteSync(recursive: true));

  test('the test area plants every rule, broken files and look-alikes', () {
    final planted = {for (final e in area.images) e.rule};
    expect(
        planted, containsAll([for (final r in ScreenshotRule.values) r.code]));
    expect(planted, containsAll(['E01', 'U03', 'U04', 'U06', 'U07', 'U08']));
    final observations = {for (final e in area.images) e.observation};
    expect(
        observations,
        containsAll([
          'cameraPhoto',
          'recent',
          'possibleScreenshot',
          'screenRecording'
        ]));
    expect(area.images.where((e) => e.rule == null).length,
        greaterThanOrEqualTo(10));
    expect(readExpectedScreenshots(area.manifest).length, area.images.length);
  });

  test('every image gets the expected rule', () async {
    final result = await ScreenshotScan(
      device: LocalDeviceAdapter(
          root: area.filesDir,
          permissions: StaticPermissionService(
              {ScanPermission.storage: PermissionState.granted})),
    ).run();
    final outcomes = verifyScreenshots(result, area.images, area.filesDir);
    expect(allScreenshotExpectationsMet(outcomes), isTrue,
        reason: formatScreenshotVerification(outcomes));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the recent screenshot is flagged once it is no longer recent',
      () async {
    final later = DateTime.now().add(const Duration(days: 3));
    final result = await ScreenshotScan(
      device: LocalDeviceAdapter(
          root: area.filesDir,
          permissions: StaticPermissionService(
              {ScanPermission.storage: PermissionState.granted})),
      clock: () => later,
    ).run();
    final outcomes = verifyScreenshots(result, area.images, area.filesDir);
    final path = area.images.singleWhere((e) => e.thenRule != null).path;
    final recent = outcomes.singleWhere((o) => o.expected.path == path);
    expect(recent.expected.rule, 'S01');
    expect(recent.passed, isTrue,
        reason: formatScreenshotVerification(outcomes));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
