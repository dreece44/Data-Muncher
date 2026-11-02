import 'dart:io';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

/// Builds the blurry photo test area in a temp folder and checks every
/// planted photo and the ranking order, exactly as the CLI's verify mode
/// does.
void main() {
  late Directory temp;
  late BlurryTestArea area;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('deep_scans_blur_');
    area = await buildBlurryPhotoTestArea('${temp.path}/area');
  });
  tearDownAll(() => temp.deleteSync(recursive: true));

  test('the test area plants every rule, broken photos and look-alikes', () {
    final planted = {for (final e in area.photos) e.rule};
    expect(planted, containsAll([for (final r in BlurRule.values) r.code]));
    expect(planted, containsAll(['E01', 'U03', 'U04', 'U05', 'U06', 'U08']));
    final lookAlikes = area.photos.where((e) => e.rule == null).length;
    expect(lookAlikes, greaterThanOrEqualTo(15));
    final (photos, order) = readExpectedPhotos(area.manifest);
    expect(photos.length, area.photos.length);
    expect(order, area.rankingOrder);
  });

  test('every photo gets the expected rule and the ranking is right', () async {
    final result = await BlurryPhotoScan(
      device: LocalDeviceAdapter(
          root: area.filesDir,
          permissions: StaticPermissionService(
              {ScanPermission.storage: PermissionState.granted})),
    ).run();
    final outcomes = verifyBlurryPhotos(result, area.photos, area.filesDir);
    final rankingOk = rankingFollows(result, area.rankingOrder, area.filesDir);
    expect(allBlurryExpectationsMet(outcomes, rankingOk: rankingOk), isTrue,
        reason: formatBlurryVerification(outcomes,
            rankingOrder: area.rankingOrder, rankingOk: rankingOk));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
