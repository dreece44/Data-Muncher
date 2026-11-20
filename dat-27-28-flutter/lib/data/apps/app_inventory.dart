import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'installed_app.dart';

/// Whether the phone lets DataMuncher see which apps are unused.
enum AppAccess {
  /// Android with Usage access turned on.
  granted,

  /// Android, but the user still has to turn on Usage access in Settings.
  needsUsageAccess,

  /// iPhone: iOS doesn't let apps see which other apps are installed or how
  /// often they're used.
  unsupported,
}

/// Lists installed apps and uninstalls them.
abstract interface class AppInventory {
  Future<AppAccess> checkAccess();

  /// Opens the system screen where the user turns on Usage access.
  Future<void> openUsageAccessSettings();

  Future<List<InstalledApp>> listApps();

  /// PNG bytes of the app's icon, or null.
  Future<Uint8List?> appIcon(String packageName);

  /// Shows Android's uninstall confirmation. Returns true if the app is gone
  /// afterwards, false if the user cancelled.
  Future<bool> uninstall(String packageName);
}

/// Picks the right inventory for the phone the app is running on.
AppInventory platformAppInventory() =>
    defaultTargetPlatform == TargetPlatform.android
        ? MethodChannelAppInventory()
        : const UnsupportedAppInventory();

/// Talks to the Android code in `MainActivity.kt` (installed by
/// `dart run tool/setup_platforms.dart`).
class MethodChannelAppInventory implements AppInventory {
  MethodChannelAppInventory(
      [this.channel = const MethodChannel('datamuncher/apps')]);

  final MethodChannel channel;

  @override
  Future<AppAccess> checkAccess() async {
    final granted = await channel.invokeMethod<bool>('hasUsageAccess');
    return granted == true ? AppAccess.granted : AppAccess.needsUsageAccess;
  }

  @override
  Future<void> openUsageAccessSettings() =>
      channel.invokeMethod<void>('openUsageAccessSettings');

  @override
  Future<List<InstalledApp>> listApps() async {
    final raw = await channel.invokeListMethod<Object?>('listApps') ?? const [];
    return [
      for (final entry in raw)
        if (entry is Map) InstalledApp.fromJson(entry),
    ];
  }

  @override
  Future<Uint8List?> appIcon(String packageName) => channel
      .invokeMethod<Uint8List>('appIcon', {'packageName': packageName});

  @override
  Future<bool> uninstall(String packageName) async =>
      await channel.invokeMethod<bool>(
          'uninstall', {'packageName': packageName}) ==
      true;
}

/// iPhone (and anything else that isn't Android).
class UnsupportedAppInventory implements AppInventory {
  const UnsupportedAppInventory();

  @override
  Future<AppAccess> checkAccess() async => AppAccess.unsupported;

  @override
  Future<void> openUsageAccessSettings() async {}

  @override
  Future<List<InstalledApp>> listApps() async => const [];

  @override
  Future<Uint8List?> appIcon(String packageName) async => null;

  @override
  Future<bool> uninstall(String packageName) async => false;
}
