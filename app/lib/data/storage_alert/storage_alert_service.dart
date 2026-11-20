/// DAT-36 (PB-23): the phone side of storage-full notifications.
///
/// - Reads free space with `disk_space_plus`.
/// - Posts the notification with `flutter_local_notifications` (Android 7+,
///   iOS 13+; Android 13+ and iOS ask the user first).
/// - Checks in the background with `workmanager`: Android WorkManager every
///   hour (survives reboots and app being swiped away), iOS BGAppRefreshTask
///   (iOS picks the time based on how often the app is used).
/// - Also checks whenever the app opens or comes back to the front, and after
///   the user frees space, so the warning goes away as soon as it's fixed.
///
/// What to say and when lives in `application/storage_alert/storage_alert.dart`.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show Color, DartPluginRegistrant;

import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../application/storage_alert/storage_alert.dart';

/// Background check entry point. Runs in its own isolate with the app closed.
@pragma('vm:entry-point')
void storageAlertDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    DartPluginRegistrant.ensureInitialized();
    try {
      await StorageAlertService.instance.check();
    } catch (e) {
      debugPrint('Storage check failed: $e');
    }
    // Always succeed: a failed reading is retried at the next interval anyway,
    // and returning false would make Android back off the schedule.
    return true;
  });
}

class StorageAlertService {
  StorageAlertService._();

  static final StorageAlertService instance = StorageAlertService._();

  /// Background task id. On iOS it must match
  /// `BGTaskSchedulerPermittedIdentifiers` in `ios/Runner/Info.plist`.
  static const String taskId = 'com.example.datamuncher.storageCheck';

  /// Payload put on the notification so a tap can be recognised.
  static const String payload = 'storage-alert';

  static const int _notificationId = 36;
  static const String _prefsKey = 'storageAlert';
  static const String _channelId = 'storage_alerts';

  /// Android drawable used as the status-bar icon
  /// (`android/app/src/main/res/drawable/ic_stat_storage.xml`).
  static const String _androidIcon = 'ic_stat_storage';

  /// Notifications and background work only exist on phones; tests and
  /// desktop builds skip them.
  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  final StorageAlertPolicy policy = const StorageAlertPolicy();
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _init;

  /// Fires when the user taps a storage notification while the app is open.
  final StreamController<void> _taps = StreamController<void>.broadcast();
  Stream<void> get taps => _taps.stream;

  Future<void> _ensureInitialized() => _init ??= _initialize();

  Future<void> _initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_androidIcon),
        // Don't prompt on startup: the app asks once it can explain why.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload == payload) _taps.add(null);
      },
    );
  }

  /// Call once at app start: sets up notifications and schedules the
  /// background check. Never throws; a failure only means fewer warnings.
  Future<void> start() async {
    if (!supported) return;
    try {
      await _ensureInitialized();
    } catch (e) {
      debugPrint('Storage notifications unavailable: $e');
      return;
    }
    try {
      final wm = Workmanager();
      await wm.initialize(storageAlertDispatcher);
      await wm.registerPeriodicTask(
        taskId,
        taskId,
        frequency: const Duration(hours: 1), // Android; minimum is 15 min
        initialDelay: const Duration(minutes: 30), // iOS: earliest next run
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        constraints: Constraints(networkType: NetworkType.notRequired),
      );
    } catch (e) {
      debugPrint('Background storage check not scheduled: $e');
    }
  }

  /// Whether the app was opened by tapping a storage notification.
  Future<bool> launchedFromAlert() async {
    if (!supported) return false;
    try {
      await _ensureInitialized();
      final d = await _plugin.getNotificationAppLaunchDetails();
      return (d?.didNotificationLaunchApp ?? false) &&
          d?.notificationResponse?.payload == payload;
    } catch (_) {
      return false;
    }
  }

  /// Asks to show notifications: the Android 13+ prompt, or the iOS prompt.
  /// Older Android versions allow them without asking. Returns whether
  /// notifications are allowed.
  Future<bool> requestPermission() async {
    if (!supported) return false;
    try {
      await _ensureInitialized();
      if (Platform.isAndroid) {
        final android = _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        return await android?.requestNotificationsPermission() ?? false;
      }
      final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      return await ios?.requestPermissions(alert: true, sound: true) ?? false;
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
      return false;
    }
  }

  /// Free and total space now, or null if the phone didn't say.
  Future<StorageReading?> readStorage() async {
    try {
      final d = DiskSpacePlus();
      final free = await d.getFreeDiskSpace;
      final total = await d.getTotalDiskSpace;
      if (free == null || total == null) return null;
      final r = StorageReading.fromMb(freeMb: free, totalMb: total);
      return r.isValid ? r : null;
    } catch (_) {
      return null;
    }
  }

  /// Checks storage and posts, keeps or clears the notification.
  ///
  /// Pass [reading] when the caller already measured it. Returns the level
  /// so the app can show its own warning too.
  Future<StorageLevel> check({StorageReading? reading, DateTime? now}) async {
    if (!supported) return StorageLevel.ok;
    final r = reading ?? await readStorage();
    if (r == null) return StorageLevel.ok;

    final prefs = await SharedPreferences.getInstance();
    // The background isolate and the app each cache prefs; pick up the
    // other one's last write.
    await prefs.reload();
    final decision = decideStorageAlert(
      reading: r,
      memory: StorageAlertMemory.decode(prefs.getString(_prefsKey)),
      now: now ?? DateTime.now(),
      policy: policy,
    );

    await _ensureInitialized();
    switch (decision.action) {
      case StorageAlertAction.notify:
        await _show(StorageAlertMessage.of(decision.level, r));
      case StorageAlertAction.clear:
        await _plugin.cancel(id: _notificationId);
      case StorageAlertAction.none:
        break;
    }
    await prefs.setString(_prefsKey, decision.memory.encode());
    return decision.level;
  }

  Future<void> _show(StorageAlertMessage m) async {
    try {
      await _plugin.show(
        id: _notificationId, // same id: a new warning replaces the old one
        title: m.title,
        body: m.body,
        payload: payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Storage alerts',
            channelDescription: 'Warns you before your phone runs out of space.',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.status,
            color: const Color(0xFF1E5A12),
            ticker: m.title,
            // Long text wraps instead of being cut off on narrow screens.
            styleInformation: BigTextStyleInformation(m.body),
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: true,
            threadIdentifier: _channelId,
            interruptionLevel: InterruptionLevel.active,
          ),
        ),
      );
    } catch (e) {
      // Notifications turned off (iOS 27 throws instead of ignoring).
      debugPrint('Storage notification not shown: $e');
    }
  }

  /// Opens the phone's notification settings for this app, for users who
  /// said no to the prompt.
  Future<void> openSettings() async {
    if (!supported) return;
    try {
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.openAppNotificationSettings();
      } else {
        await _plugin
            .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
            ?.openAppNotificationSettings();
      }
    } catch (_) {}
  }
}
