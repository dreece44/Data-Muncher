import 'package:datamuncher/data/apps/app_inventory.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('datamuncher/apps');
  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  final inventory = MethodChannelAppInventory();

  test('usage access', () async {
    answer((_) => true);
    expect(await inventory.checkAccess(), AppAccess.granted);
    answer((_) => false);
    expect(await inventory.checkAccess(), AppAccess.needsUsageAccess);
    expect(calls.last.method, 'hasUsageAccess');
  });

  test('reads the app list Android sends', () async {
    answer((_) => [
          {
            'packageName': 'com.example.a',
            'label': 'A',
            'sizeBytes': 5000,
            'installedAt': 1700000000000,
            'lastUsedAt': null,
            'isSystem': false,
            'isEssential': false,
          },
        ]);
    final apps = await inventory.listApps();
    expect(apps.single.packageName, 'com.example.a');
    expect(apps.single.sizeBytes, 5000);
    expect(calls.single.method, 'listApps');
  });

  test('passes the package name to uninstall and icons', () async {
    answer((call) => switch (call.method) {
          'uninstall' => true,
          'appIcon' => Uint8List.fromList([1, 2, 3]),
          _ => null,
        });
    expect(await inventory.uninstall('com.example.a'), isTrue);
    expect(calls.last.arguments, {'packageName': 'com.example.a'});
    expect(await inventory.appIcon('com.example.a'), [1, 2, 3]);
  });

  test('iPhone and others get the unsupported inventory', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(platformAppInventory(), isA<UnsupportedAppInventory>());
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(platformAppInventory(), isA<MethodChannelAppInventory>());
    debugDefaultTargetPlatformOverride = null;
  });
}
