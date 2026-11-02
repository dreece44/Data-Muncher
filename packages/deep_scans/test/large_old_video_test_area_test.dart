import 'dart:io';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

/// Builds the large & old video test area in a temp folder and checks every
/// planted video, exactly as the CLI's verify mode does, now and at the
/// points where the answers change with time.
void main() {
  late Directory temp;
  late LargeOldVideoTestArea area;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('deep_scans_videos_');
    area = await buildLargeOldVideoTestArea('${temp.path}/area');
  });
  tearDownAll(() => temp.deleteSync(recursive: true));

  Future<VideoVerification> scan({DateTime? at}) async {
    final result = await LargeOldVideoScan(
      device: LocalDeviceAdapter(
          root: area.filesDir,
          permissions: StaticPermissionService(
              {ScanPermission.storage: PermissionState.granted})),
      rules: area.rules,
      clock: at == null ? null : () => at,
    ).run();
    return verifyVideos(result, area.videos, area.filesDir);
  }

  test('the test area plants every rule, broken files and look-alikes', () {
    final planted = {for (final e in area.videos) e.rule};
    expect(planted, containsAll([for (final r in VideoRule.values) r.code]));
    expect(planted, containsAll(['E01', 'U03', 'U04', 'U06']));
    final observations = {for (final e in area.videos) e.observation};
    expect(
        observations,
        containsAll([
          'recent', 'activeProject', 'stillWriting', 'appData', //
          'notParsed', 'datesDisagree', 'badMetadataDate',
        ]));
    expect(area.videos.where((e) => e.rule == null).length,
        greaterThanOrEqualTo(10));
    expect(readExpectedVideos(area.manifest).length, area.videos.length);
    expect(readVideoTestAreaScale(area.manifest), videoTestAreaScale);
  });

  test('every video gets the expected rule', () async {
    final v = await scan();
    expect(v.passed, isTrue, reason: formatVideoVerification(v));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('answers that change with time change when expected', () async {
    // 11 minutes on, the recording still being written is judged (V04);
    // 15 days on, the recent ones are flagged; 26 days on, the 11-month
    // clip is old and large.
    for (final later in [
      const Duration(minutes: 11),
      const Duration(days: 15),
      const Duration(days: 26),
    ]) {
      final v = await scan(at: DateTime.now().add(later));
      expect(v.passed, isTrue,
          reason: 'at +$later:\n${formatVideoVerification(v)}');
    }
    expect(area.videos.where((e) => e.changesAt != null).length, 4);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
