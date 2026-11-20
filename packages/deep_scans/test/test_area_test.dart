import 'dart:io';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

/// Builds the test area in a temp folder and checks the deep scan gets
/// every planted example right, exactly as the CLI's verify mode does.
void main() {
  late Directory temp;
  late TestArea area;
  final generatedAt = DateTime.now();

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('deep_scans_');
    area = await buildEmptyUnreadableTestArea('${temp.path}/area',
        now: generatedAt);
  });
  tearDownAll(() async {
    if (!Platform.isWindows) {
      await Process.run('chmod', ['-R', 'u+rw', temp.path]);
    }
    temp.deleteSync(recursive: true);
  });

  Future<DeepScanResult> scanAt(DateTime now) => EmptyUnreadableScan(
        device: LocalDeviceAdapter(
            root: area.filesDir,
            permissions: StaticPermissionService(
                {ScanPermission.storage: PermissionState.granted})),
        clock: () => now,
      ).run();

  test('the test area covers every rule and has healthy look-alikes', () {
    final planted = {for (final c in area.cases) c.rule ?? c.ruleAfterGrace};
    final expected = {
      for (final r in DeepRule.values)
        if (r != DeepRule.u01CannotOpen && r != DeepRule.u02ShortRead) r.code
    };
    expect(planted, containsAll(expected));
    expect(area.cases.where((c) => c.rule == null).length, greaterThan(30));
    expect(readExpectedCases(area.manifest).length, area.cases.length);
  });

  test('every expectation is met', () async {
    final now = generatedAt.add(const Duration(minutes: 1));
    final outcomes =
        verify(await scanAt(now), area.cases, root: area.filesDir, now: now);
    final failed = outcomes.where((o) => !o.passed).toList();
    expect(failed, isEmpty, reason: formatVerification(failed));
  });

  test('a download left alone past the grace period becomes U03', () async {
    final now = generatedAt.add(const Duration(minutes: 11));
    final outcomes =
        verify(await scanAt(now), area.cases, root: area.filesDir, now: now);
    final active = outcomes.singleWhere(
        (o) => o.path == 'unreadable/still_downloading.zip.crdownload');
    expect(active.actual?.rule, DeepRule.u03UnfinishedDownload);
    expect(outcomes.every((o) => o.passed), isTrue);
  });

  test('refuses to replace a folder it did not make', () async {
    final other = Directory('${temp.path}/mine')..createSync();
    File('${other.path}/keep.txt').writeAsStringSync('mine');
    await expectLater(
        buildEmptyUnreadableTestArea(other.path), throwsA(isA<StateError>()));
    expect(File('${other.path}/keep.txt').existsSync(), isTrue);
  });
}
