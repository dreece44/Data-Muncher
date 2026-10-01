/// Android and iOS support for the DataMuncher scan engine.
///
/// Re-exports `package:scan_engine`, so apps only need this import.
library;

export 'package:scan_engine/scan_engine.dart';

export 'src/android_device_adapter.dart';
export 'src/current_device.dart';
export 'src/flutter_permission_service.dart';
export 'src/flutter_thumbnail_decoder.dart';
export 'src/ios_device_adapter.dart';
export 'src/native_bridge.dart';
