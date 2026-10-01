import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final files = {'DCIM/a.txt': ascii('hello'), 'Download/empty.bin': <int>[]};

  group('scan refuses to run without storage access', () {
    for (final state in [
      PermissionState.denied,
      PermissionState.permanentlyDenied,
      PermissionState.restricted,
    ]) {
      test('when storage access is ${state.name}', () async {
        final device =
            FakeDevice(files, permissions: {ScanPermission.storage: state});

        await expectLater(
          scan(device),
          throwsA(isA<PermissionDeniedException>().having(
              (e) => e.missing, 'missing', {ScanPermission.storage: state})),
        );
        expect(device.memory.accessCount, 0,
            reason: 'storage must not be touched');
      });
    }

    test('when no permission has been answered at all', () async {
      final device = FakeDevice(files, permissions: {});
      await expectLater(
          scan(device), throwsA(isA<PermissionDeniedException>()));
      expect(device.memory.accessCount, 0);
    });

    test('on iOS, when only the Android storage permission is granted',
        () async {
      final device = FakeDevice(files,
          platform: DevicePlatform.ios,
          permissions: {ScanPermission.storage: PermissionState.granted});
      await expectLater(
        scan(device),
        throwsA(isA<PermissionDeniedException>()
            .having((e) => e.missing.keys, 'missing', [ScanPermission.photos])),
      );
      expect(device.memory.accessCount, 0);
    });

    test('checks permissions before anything else', () async {
      final device = FakeDevice(files, permissions: {});
      final phases = <ScanPhase>[];
      await expectLater(
        ScanEngine(device: device).scan(onProgress: (p) => phases.add(p.phase)),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(phases, [ScanPhase.checkingPermissions]);
      expect(device.permissions.checks, [ScanPermission.storage]);
    });

    test('when a device declares no storage permission', () async {
      await expectLater(
        ScanEngine(device: _NoPermissionDevice(files)).scan(),
        throwsStateError,
      );
    });
  });

  group('scan runs once access is granted', () {
    test('with full access', () async {
      final report = await scan(FakeDevice(files));
      expect(report.itemsScanned, 2);
      expect(report.notes, isEmpty);
    });

    test('with iOS limited photo access, and says so in the report', () async {
      final report = await scan(FakeDevice(files,
          platform: DevicePlatform.ios,
          permissions: {ScanPermission.photos: PermissionState.limited}));
      expect(report.itemsScanned, 2);
      expect(report.notes.single, contains('limited'));
    });
  });

  group('PermissionGuardedStorageSource', () {
    test('refuses to list without permission', () async {
      final memory = MemoryStorageSource(files);
      final guarded = PermissionGuardedStorageSource(
          memory, StaticPermissionService(), {ScanPermission.storage});

      await expectLater(guarded.listItems().toList(),
          throwsA(isA<PermissionDeniedException>()));
      expect(memory.accessCount, 0);
    });

    test('refuses reads before a permission-checked listing', () async {
      final memory = MemoryStorageSource(files);
      final item = (await memory.listItems().first);
      final guarded = PermissionGuardedStorageSource(
          memory,
          StaticPermissionService(
              {ScanPermission.storage: PermissionState.granted}),
          {ScanPermission.storage});

      expect(() => guarded.readRange(item, 0, 10), throwsStateError);
      await guarded.listItems().toList();
      expect(await guarded.readRange(item, 0, 5), ascii('hello'));
    });

    test('re-checks on every listing, so revoked access stops reads', () async {
      final memory = MemoryStorageSource(files);
      final permissions = StaticPermissionService(
          {ScanPermission.storage: PermissionState.granted});
      final guarded = PermissionGuardedStorageSource(
          memory, permissions, {ScanPermission.storage});
      final item = (await guarded.listItems().toList()).first;

      permissions.set(ScanPermission.storage, PermissionState.denied);
      await expectLater(guarded.listItems().toList(),
          throwsA(isA<PermissionDeniedException>()));
      expect(() => guarded.readRange(item, 0, 5), throwsStateError);
    });
  });
}

final class _NoPermissionDevice extends FakeDevice {
  _NoPermissionDevice(super.files);
  @override
  Set<ScanPermission> get storagePermissions => const {};
}
