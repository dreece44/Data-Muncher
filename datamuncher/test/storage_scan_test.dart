import 'dart:io';

import 'package:datamuncher/application/storage_scan/storage_scan.dart';
import 'package:datamuncher/data/garbage_bin/bin_entry.dart';
import 'package:datamuncher/data/garbage_bin/file_bin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scan_engine_flutter/scan_engine_flutter.dart' as engine;

engine.StorageItem item(String path, [int size = 10]) =>
    engine.StorageItem(id: path, path: path, displayName: p.basename(path), sizeBytes: size);

engine.ScanReport report(List<engine.Finding> findings) => engine.ScanReport(
      platform: engine.DevicePlatform.android,
      startedAt: DateTime(2026),
      finishedAt: DateTime(2026),
      storage: null,
      itemsScanned: 0,
      bytesScanned: 0,
      findings: findings,
      categories: const {},
      issues: const [],
      notes: const [],
    );

void main() {
  group('candidatesFrom', () {
    test('maps each category to its bin reason', () {
      final r = report([
        engine.Finding(category: engine.WasteCategory.emptyFile, items: [item('/a.txt')], reason: 'Empty'),
        engine.Finding(category: engine.WasteCategory.unreadableFile, items: [item('/b.pdf')], reason: 'Cut off'),
        engine.Finding(category: engine.WasteCategory.blankPhoto, items: [item('/c.jpg')], reason: 'Black'),
      ]);
      final reasons = {for (final c in candidatesFrom(r)) p.basename(c.path): c.reason};
      expect(reasons, {
        'a.txt': CollectionReason.emptyFile,
        'b.pdf': CollectionReason.unreadable,
        'c.jpg': CollectionReason.blank,
      });
      expect(candidatesFrom(r)[1].explanation, 'Cut off');
    });

    test('leaves out the copy to keep in a duplicate group', () {
      final keep = item('/DCIM/1.jpg');
      final r = report([
        engine.Finding(
          category: engine.WasteCategory.duplicatePhoto,
          items: [keep, item('/DCIM/2.jpg'), item('/WhatsApp/1.jpg')],
          keep: keep,
          reason: 'Same photo',
        ),
      ]);
      expect([for (final c in candidatesFrom(r)) c.path], ['/DCIM/2.jpg', '/WhatsApp/1.jpg']);
    });

    test('a file flagged twice appears once with the clearest reason', () {
      final photo = item('/DCIM/x.jpg');
      final r = report([
        engine.Finding(category: engine.WasteCategory.duplicatePhoto, items: [item('/k.jpg'), photo],
            keep: null, reason: 'dup'),
        engine.Finding(category: engine.WasteCategory.blankPhoto, items: [photo], reason: 'blank'),
      ]);
      final found = candidatesFrom(r).where((c) => c.path == '/DCIM/x.jpg').toList();
      expect(found, hasLength(1));
      expect(found.single.reason, CollectionReason.blank);
    });

    test('skips apps, items without a path, and excluded paths', () {
      final r = report([
        engine.Finding(
          category: engine.WasteCategory.unusedApp,
          items: [const engine.InstalledApp(packageName: 'com.x', label: 'X', sizeBytes: 5)],
          reason: 'Not opened in 90 days',
        ),
        engine.Finding(
          category: engine.WasteCategory.blankPhoto,
          items: [
            engine.StorageItem(id: 'ios-asset', displayName: 'IMG.jpg', sizeBytes: 1, origin: engine.ItemOrigin.photoLibrary),
            item('/keep-me.jpg'),
            item('/bin-me.jpg'),
          ],
          reason: 'Black',
        ),
      ]);
      expect([for (final c in candidatesFrom(r, skip: (path) => path == '/keep-me.jpg')) c.path], ['/bin-me.jpg']);
      expect([for (final a in unusedAppsFrom(r)) a.packageName], ['com.x']);
    });
  });

  // The flow the app runs on the emulator, with a folder standing in for the
  // phone: scan sample_phone with the real engine, then move every result to
  // the bin.
  final sample = Directory(p.join('..', 'packages', 'scan_engine', 'sample_phone'));
  test('scanning sample_phone and moving the results to the bin', () async {
    final root = await Directory.systemTemp.createTemp('sample_phone_');
    addTearDown(() => root.delete(recursive: true));
    await for (final e in sample.list(recursive: true)) {
      if (e is! File) continue;
      final target = File(p.join(root.path, p.relative(e.path, from: sample.path)));
      await target.parent.create(recursive: true);
      await e.copy(target.path);
    }

    final device = engine.LocalDeviceAdapter(
      root: root.path,
      permissions: engine.StaticPermissionService({engine.ScanPermission.storage: engine.PermissionState.granted}),
    );
    final scan = await engine.ScanEngine(device: device).scan();
    final candidates = candidatesFrom(scan);
    String rel(String path) => p.relative(path, from: root.path).replaceAll(r'\', '/');

    // Matches the expected findings in packages/scan_engine/README.md.
    final byReason = <CollectionReason, int>{};
    for (final c in candidates) {
      byReason.update(c.reason, (n) => n + 1, ifAbsent: () => 1);
    }
    expect(byReason[CollectionReason.emptyFile], 2);
    expect(byReason[CollectionReason.unreadable], 8);
    expect(byReason[CollectionReason.blank], 2);
    expect(byReason[CollectionReason.duplicate], 4); // 3 extra hike shots + 1 receipt
    expect(candidates.map((c) => rel(c.path)), isNot(contains('DCIM/Camera/IMG_20260914_091500.jpg')));

    final fileBin = FileBin(binFolderFor: (path) => binFolderUnder([root.path], path));
    for (final c in candidates) {
      await fileBin.collect(c.path, c.reason);
    }
    expect(fileBin.length, candidates.length);
    for (final c in candidates) {
      expect(File(c.path).existsSync(), isFalse, reason: '${rel(c.path)} should have left its folder');
    }

    // The bin folder is hidden, so a rescan finds nothing left to munch.
    final rescan = await engine.ScanEngine(device: device).scan();
    expect(candidatesFrom(rescan), isEmpty);
  }, skip: sample.existsSync() ? false : 'Run `dart run tool/make_sample_storage.dart` in packages/scan_engine first');
}
