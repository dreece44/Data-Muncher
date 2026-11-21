import Flutter
import UIKit
import UserNotifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Storage-full notifications (DAT-36): show them while the app is open,
    // and pass taps to flutter_local_notifications.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate

    // The background storage check runs in its own Flutter engine; give it
    // the app's plugins (disk space, notifications, preferences).
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // iOS only accepts background task handlers registered before launch
    // finishes. With the UIScene lifecycle, plugins register after this
    // method returns, so register the storage check here. The id must match
    // StorageAlertService.taskId and BGTaskSchedulerPermittedIdentifiers.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "com.example.datamuncher.storageCheck",
      earliestBeginInSeconds: 30 * 60)
    WorkmanagerPlugin.registerLaunchHandlers()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
