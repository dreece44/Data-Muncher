import 'dart:io';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

/// Builds the duplicate document test area in a temp folder and checks every
/// planted group, look-alike and empty/unreadable document, exactly as the
/// CLI's verify mode does.
void main() {
  late Directory temp;
  late DocumentTestArea area;
  final generatedAt = DateTime.now();

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('deep_scans_docs_');
    area = await buildDuplicateDocumentTestArea('${temp.path}/area',
        now: generatedAt);
  });
  tearDownAll(() => temp.deleteSync(recursive: true));

  Future<DuplicateDocumentResult> scanAt(DateTime now) => DuplicateDocumentScan(
        device: LocalDeviceAdapter(
            root: area.filesDir,
            permissions: StaticPermissionService(
                {ScanPermission.storage: PermissionState.granted})),
        clock: () => now,
      ).run();

  test('the test area plants every rule, look-alikes and broken documents', () {
    final planted = {for (final g in area.groups) ...g.members.values};
    expect(planted, {for (final r in DocumentRule.values) r.code});
    expect(area.singles.length, greaterThanOrEqualTo(15));
    final healthRules = {for (final h in area.health) h.rule};
    expect(healthRules,
        containsAll(['E01', 'E02', 'E03', 'E05', 'U03', 'U04', 'U05', 'U06']));
    final (groups, singles, health) = readExpectedDocuments(area.manifest);
    expect(groups.length, area.groups.length);
    expect(singles.length, area.singles.length);
    expect(health.length, area.health.length);
  });

  for (final (label, offset) in [
    ('while a download is in progress', const Duration(minutes: 1)),
    ('after the grace period', const Duration(minutes: 11)),
  ]) {
    test('every expectation is met $label', () async {
      final now = generatedAt.add(offset);
      final result = await scanAt(now);
      final score = GroupScore(
          area.groups, area.singles, documentGroups(result, area.filesDir));
      final health = verifyHealth(result, area.health, area.filesDir, now: now);
      expect(allDocumentExpectationsMet(score, health), isTrue,
          reason: formatDocumentVerification(score, health));
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('refuses to replace a folder it did not make', () async {
    final other = Directory('${temp.path}/mine')..createSync();
    File('${other.path}/keep.txt').writeAsStringSync('mine');
    await expectLater(
        buildDuplicateDocumentTestArea(other.path), throwsA(isA<StateError>()));
    expect(File('${other.path}/keep.txt').existsSync(), isTrue);
  });
}
