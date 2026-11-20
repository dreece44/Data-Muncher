import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:scan_engine/scan_engine.dart';

/// Calls into the Kotlin (Android) and Swift (iOS) half of this plugin for
/// the things Dart can't reach on its own.
final class NativeBridge {
  const NativeBridge();

  static const _channel = MethodChannel('datamuncher/scan_engine');

  // --- Android ---------------------------------------------------------------

  Future<int> androidSdkInt() async =>
      (await _channel.invokeMethod<int>('getSdkInt'))!;

  /// Root of each shared storage volume: internal storage
  /// (`/storage/emulated/0`) plus any SD card. Reading these needs storage
  /// access; finding out where they are doesn't.
  Future<List<String>> androidStorageRoots() async =>
      await _channel.invokeListMethod<String>('getStorageRoots') ?? const [];

  Future<bool> hasUsageAccess() async =>
      await _channel.invokeMethod<bool>('hasUsageAccess') ?? false;

  /// Opens Settings → Usage access. The user flips the switch there.
  Future<void> openUsageAccessSettings() =>
      _channel.invokeMethod<void>('openUsageAccessSettings');

  Future<List<InstalledApp>> installedApps() async {
    final apps =
        await _channel.invokeListMethod<Map<Object?, Object?>>(
          'listInstalledApps',
        ) ??
        const [];
    return [for (final app in apps) InstalledApp.fromJson(app.cast())];
  }

  // --- Both ------------------------------------------------------------------

  Future<StorageStats?> storageStats() async {
    final stats = await _channel.invokeMapMethod<String, int>(
      'getStorageStats',
    );
    if (stats == null) return null;
    return StorageStats(
      totalBytes: stats['totalBytes']!,
      freeBytes: stats['freeBytes']!,
    );
  }

  // --- iOS -------------------------------------------------------------------

  /// Every image in the Photos library: `id`, `filename`, `sizeBytes`,
  /// `width`, `height`, and `createdAt` / `modifiedAt` in epoch ms.
  Future<List<Map<String, Object?>>> iosPhotoAssets() async {
    final assets =
        await _channel.invokeListMethod<Map<Object?, Object?>>(
          'listPhotoAssets',
        ) ??
        const [];
    return [for (final asset in assets) asset.cast()];
  }

  /// A `size`×`size` greyscale thumbnail of a Photos asset, or null if iOS
  /// has no local copy to draw it from.
  Future<Uint8List?> iosPhotoThumbnail(String id, int size) => _channel
      .invokeMethod<Uint8List>('photoThumbnail', {'id': id, 'size': size});
}
