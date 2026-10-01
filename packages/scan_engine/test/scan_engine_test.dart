import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('ScanEngine on a real folder', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('datamuncher_test_');
      void write(String rel, List<int> bytes) {
        final f = File(p.join(root.path, rel));
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(bytes);
      }

      final photo = jpg(scene(1));
      write('DCIM/Camera/IMG_1.jpg', photo);
      write('Pictures/WhatsApp/IMG_1.jpg', photo);
      write('DCIM/Camera/IMG_2.jpg', jpg(scene(2)));
      write('DCIM/Camera/pocket.jpg', jpg(jitter(flat(5), noise: 2)));
      write('Download/failed.zip', []);
      write('Download/lease.pdf', ascii('<html>404</html>'));
      write('Documents/notes.txt', ascii('real notes'));
      write('.nomedia', []);
      write('Pictures/.thumbnails/IMG_1.jpg', photo); // hidden cache
      write('Android/data/com.app/cache.bin', []);
    });

    tearDown(() => root.delete(recursive: true));

    LocalDeviceAdapter device({bool granted = true}) => LocalDeviceAdapter(
          root: root.path,
          permissions: StaticPermissionService({
            if (granted) ScanPermission.storage: PermissionState.granted,
          }),
        );

    test('finds every kind of waste and skips hidden folders', () async {
      final report =
          await ScanEngine(device: device(), rules: testRules).scan();

      String rel(Reclaimable r) =>
          p.relative(r.id, from: root.path).replaceAll(r'\', '/');
      Set<String> found(WasteCategory c) => {
            for (final f in report.findingsFor(c))
              for (final i in f.items) rel(i)
          };

      expect(found(WasteCategory.emptyFile),
          {'Download/failed.zip', 'Android/data/com.app/cache.bin'});
      expect(found(WasteCategory.unreadableFile), {'Download/lease.pdf'});
      expect(found(WasteCategory.duplicatePhoto),
          {'DCIM/Camera/IMG_1.jpg', 'Pictures/WhatsApp/IMG_1.jpg'});
      expect(found(WasteCategory.blankPhoto), {'DCIM/Camera/pocket.jpg'});
      expect(report.categories[WasteCategory.unusedApp]!.state,
          CategoryState.unsupported,
          reason: 'no app inventory was given');
      expect(report.itemsScanned, 8,
          reason: '.nomedia and .thumbnails are hidden');
      expect(report.reclaimableBytes, greaterThan(0));
    });

    test('refuses to scan the folder without permission', () async {
      await expectLater(ScanEngine(device: device(granted: false)).scan(),
          throwsA(isA<PermissionDeniedException>()));
    });

    test('report converts to JSON and text', () async {
      final report =
          await ScanEngine(device: device(), rules: testRules).scan();
      final json =
          jsonDecode(jsonEncode(report.toJson())) as Map<String, Object?>;
      expect(json['itemsScanned'], 8);
      expect((json['categories'] as Map)['duplicatePhoto'],
          containsPair('findings', 1));

      final text = formatReport(report, relativeTo: root.path);
      expect(text, contains('Duplicate photos'));
      expect(text, contains('keep'));
      expect(text, contains('Download/lease.pdf'));
    });
  });

  test('reports progress through every phase', () async {
    final phases = <ScanPhase>{};
    final categories = <WasteCategory?>{};
    await ScanEngine(
            device: FakeDevice({'a.jpg': jpg(scene(1))}), rules: testRules)
        .scan(onProgress: (p) {
      phases.add(p.phase);
      categories.add(p.category);
    });
    expect(
        phases,
        containsAll([
          ScanPhase.checkingPermissions,
          ScanPhase.detecting,
          ScanPhase.finishing
        ]));
    expect(categories,
        containsAll([WasteCategory.emptyFile, WasteCategory.duplicatePhoto]));
  });

  test('can be cancelled', () async {
    final token = ScanCancelToken();
    final scan =
        ScanEngine(
                device: FakeDevice({'a.txt': ascii('x'), 'b.txt': ascii('y')}))
            .scan(
                cancelToken: token,
                onProgress: (p) {
                  if (p.phase == ScanPhase.detecting) token.cancel();
                });
    await expectLater(scan, throwsA(isA<ScanCancelledException>()));
  });

  test('a crashing detector is reported without stopping the others', () async {
    final report = await ScanEngine(
      device: FakeDevice({'empty.txt': []}),
      detectors: [_CrashingDetector(), const EmptyFileDetector()],
    ).scan();
    expect(report.categories[WasteCategory.blankPhoto]!.state,
        CategoryState.failed);
    expect(report.findingsFor(WasteCategory.emptyFile), hasLength(1));
  });

  test('counts an item flagged twice only once in the total', () async {
    final item = StorageItem(id: 'x', displayName: 'x.jpg', sizeBytes: 100);
    final report = ScanReport(
      platform: DevicePlatform.android,
      startedAt: DateTime(2026),
      finishedAt: DateTime(2026),
      storage: null,
      itemsScanned: 1,
      bytesScanned: 100,
      findings: [
        Finding(category: WasteCategory.blankPhoto, items: [item], reason: ''),
        Finding(
            category: WasteCategory.unreadableFile, items: [item], reason: ''),
      ],
      categories: const {},
      issues: const [],
      notes: const [],
    );
    expect(report.reclaimableBytes, 100);
  });

  group('LocalDirectorySource', () {
    test('reports missing folders as issues instead of failing', () async {
      final issues = <ScanIssue>[];
      final items = await LocalDirectorySource(
              [p.join(Directory.systemTemp.path, 'does_not_exist_dm')])
          .listItems(onIssue: issues.add)
          .toList();
      expect(items, isEmpty);
      expect(issues.single.message, contains('not found'));
    });

    test('skips excluded folders and clamps reads to the file size', () async {
      final root = await Directory.systemTemp.createTemp('datamuncher_src_');
      addTearDown(() => root.delete(recursive: true));
      File(p.join(root.path, 'keep.txt')).writeAsStringSync('hello');
      Directory(p.join(root.path, 'Android', 'data'))
          .createSync(recursive: true);
      File(p.join(root.path, 'Android', 'data', 'secret.bin'))
          .writeAsStringSync('x');

      final source = LocalDirectorySource([root.path],
          excludedPaths: [p.join(root.path, 'Android', 'data')]);
      final items = await source.listItems().toList();
      expect(items.map((i) => i.displayName), ['keep.txt']);
      expect(await source.readRange(items.single, 2, 1000), ascii('llo'));
    });
  });
}

final class _CrashingDetector extends WasteDetector {
  @override
  WasteCategory get category => WasteCategory.blankPhoto;

  @override
  Future<List<Finding>> detect(ScanContext context) async =>
      throw StateError('boom');
}
