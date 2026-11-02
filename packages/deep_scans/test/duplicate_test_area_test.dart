import 'dart:io';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

/// Builds the duplicate photo test area in a temp folder and checks every
/// planted group and single, exactly as the CLI's verify mode does.
void main() {
  late Directory temp;
  late DuplicateTestArea area;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('deep_scans_dup_');
    area = await buildDuplicatePhotoTestArea('${temp.path}/area');
  });
  tearDownAll(() => temp.deleteSync(recursive: true));

  test('the test area plants every rule and has look-alikes', () {
    final planted = {
      for (final g in area.groups) ...g.members.values,
    };
    expect(planted, {for (final r in DuplicateRule.values) r.code});
    expect(area.singles.length, greaterThanOrEqualTo(10));
    final (groups, singles) = readExpectedGroups(area.manifest);
    expect(groups.length, area.groups.length);
    expect(singles.length, area.singles.length);
  });

  test('every group, keeper and rule is right and singles stay apart',
      () async {
    final result = await DuplicatePhotoScan(
      device: LocalDeviceAdapter(
          root: area.filesDir,
          permissions: StaticPermissionService(
              {ScanPermission.storage: PermissionState.granted})),
    ).run();
    final score = GroupScore(
        area.groups, area.singles, deepGroups(result, area.filesDir));
    expect(score.allPassed, isTrue, reason: formatGroupVerification(score));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
