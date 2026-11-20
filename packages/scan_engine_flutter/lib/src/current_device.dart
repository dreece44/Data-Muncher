import 'dart:io';

import 'package:scan_engine/scan_engine.dart';

import 'android_device_adapter.dart';
import 'ios_device_adapter.dart';

/// The adapter for the phone this app is running on.
///
/// ```dart
/// final engine = ScanEngine(device: await currentDevice());
/// ```
Future<DeviceAdapter> currentDevice({
  List<String> iosPickedFolders = const [],
}) async {
  if (Platform.isAndroid) return AndroidDeviceAdapter.create();
  if (Platform.isIOS) return IosDeviceAdapter(pickedFolders: iosPickedFolders);
  throw UnsupportedError(
    'DataMuncher scans Android and iOS devices. On a '
    'computer, use LocalDeviceAdapter from package:scan_engine.',
  );
}
