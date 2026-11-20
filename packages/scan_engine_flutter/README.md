# scan_engine_flutter

Connects [`scan_engine`](../scan_engine) to real phones. The app imports
`package:scan_engine_flutter/scan_engine_flutter.dart` and calls
`currentDevice()`; this package picks the right adapter.

| Device | Adapter | What it scans |
|---|---|---|
| Any Android phone or tablet (Pixel, Samsung Galaxy, Motorola, OnePlus…) | `AndroidDeviceAdapter` | All shared storage: internal and SD cards, including DCIM, Pictures, Download, Documents, Movies, WhatsApp media. Installed apps and when they were last used. |
| iPhone / iPad | `IosDeviceAdapter` | The Photos library, plus any folders the user picks in the Files app |

**iOS limits.** iOS does not let any app browse the phone's file system or see
other installed apps. Empty/unreadable-file checks therefore only cover
folders the user picks, and unused apps are reported as unsupported on
iPhone. This is an iOS rule, not something this code can work around.

## Native code

Dart does the scanning; native code covers only what Dart can't reach:

- `android/src/main/kotlin/.../ScanEngineFlutterPlugin.kt`: storage volume
  locations and totals, usage-access check, installed apps with last-used
  times and sizes.
- `ios/Classes/ScanEngineFlutterPlugin.swift`: Photos library listing,
  greyscale thumbnails, storage totals.
- Permission prompts use
  [`permission_handler`](https://pub.dev/packages/permission_handler).

Android permissions are declared in this plugin's `AndroidManifest.xml` and
merge into the app automatically. **Publishing note:** Google Play only
allows `MANAGE_EXTERNAL_STORAGE` after a policy declaration explaining why
the app needs all-files access. A storage cleaner qualifies, but the
declaration is required.

## App setup (iOS)

In the app's `ios/Runner/Info.plist`:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>DataMuncher looks through your photos to find duplicates and blank shots you may want to delete.</string>
```

In the app's `ios/Podfile`, inside `post_install`, enable permission_handler's
photos permission:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
        '$(inherited)',
        'PERMISSION_PHOTOS=1',
      ]
    end
  end
end
```

## Testing on a phone, emulator or simulator

You need the [Flutter SDK](https://docs.flutter.dev/get-started/install).

- **Android emulator:** add Android Studio. This works on Windows.
- **iOS simulator or iPhone:** needs a Mac with Xcode. Apple doesn't allow iOS builds on Windows.

### One-time: generate the harness app's platform folders

```bash
cd packages/scan_engine_flutter/example
flutter create --platforms=android,ios --org com.datamuncher .
flutter pub get
```

This only adds missing files. It keeps `lib/main.dart` and the tests. For
iOS, also apply the Info.plist and Podfile changes above to
`example/ios/`.

### Android emulator (from Windows)

1. Start an emulator from Android Studio's Device Manager.
2. Put the sample waste on it. Generate it first with
   `dart run tool/make_sample_storage.dart` in `packages/scan_engine`:

   ```bash
   adb push ../../scan_engine/sample_phone /sdcard/DataMuncherSample
   ```

3. Check that the scan is refused before permission is granted:

   ```bash
   flutter test integration_test --dart-define=EXPECT_ACCESS=false
   ```

4. Grant permissions. Either tap them in the harness app (`flutter run`, then
   the "Storage access" and "App usage access" buttons), or use adb:

   ```bash
   adb shell appops set --uid com.datamuncher.scan_engine_flutter_example MANAGE_EXTERNAL_STORAGE allow
   ```

   ```bash
   adb shell appops set com.datamuncher.scan_engine_flutter_example GET_USAGE_STATS allow
   ```

5. Run the scan on the emulator. The report prints in your terminal:

   ```bash
   flutter test integration_test
   ```

   Findings under `DataMuncherSample/` should match the table in
   `scan_engine/README.md`. An emulator has few real apps with little usage
   history, so its unused-app results will differ. You'll also see issues or
   notes about folders Android keeps private.

To revoke access and check the refusal again:
`adb shell appops set --uid com.datamuncher.scan_engine_flutter_example MANAGE_EXTERNAL_STORAGE deny`.

### Real Android phone (Pixel, Samsung…)

Enable Developer options → USB debugging, plug in, and run the same
commands; `flutter devices` should list the phone. Scans only read storage,
never delete anything.

### iOS simulator (on a Mac)

```bash
xcrun simctl addmedia booted ../../scan_engine/sample_phone/DCIM/Camera/*.jpg
```

```bash
flutter test integration_test --dart-define=EXPECT_ACCESS=false
```

```bash
xcrun simctl privacy booted grant photos com.datamuncher.scanEngineFlutterExample
```

```bash
flutter test integration_test
```

In order: add the sample photos, check the scan is refused, grant photo
access, then run the scan.
