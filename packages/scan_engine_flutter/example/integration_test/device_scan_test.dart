import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scan_engine_flutter/scan_engine_flutter.dart';

/// Runs the real scan engine on the connected phone, emulator or simulator
/// and prints the report in your computer's terminal.
///
///   flutter test integration_test --dart-define=EXPECT_ACCESS=false
///     Storage access not granted yet: passes if the scan is refused.
///   flutter test integration_test
///     Storage access granted: passes if the scan runs and finds files.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const expectAccess = bool.fromEnvironment(
    'EXPECT_ACCESS',
    defaultValue: true,
  );

  testWidgets('scan engine on this device', (tester) async {
    final engine = ScanEngine(device: await currentDevice());
    final permissions = await engine.checkPermissions();
    debugPrint(
      'Permissions: '
      '${permissions.entries.map((e) => '${e.key.name}=${e.value.name}').join(', ')}',
    );

    if (!expectAccess) {
      await expectLater(
        engine.scan(),
        throwsA(isA<PermissionDeniedException>()),
      );
      debugPrint(
        'PASS: scan was refused because storage access is not granted.',
      );
      return;
    }

    final report = await engine.scan();
    formatReport(report).split('\n').forEach(debugPrint);
    expect(
      report.itemsScanned,
      greaterThan(0),
      reason: 'Storage access is granted but no files were found.',
    );
  }, timeout: const Timeout(Duration(minutes: 15)));
}
