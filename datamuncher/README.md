# DataMuncher app

The phone app that brings the team's work together.

| Where in the app | What | Code | By |
|---|---|---|---|
| Home: Duplicates / Empty / Blurry, Munch my data | Photo library scan | `lib/core.dart`, `lib/rules.dart` | Nathan Kim |
| Home: bin icon | Garbage Bin viewer and Empty Bin (DAT-27/28) | `lib/*/garbage_bin/` | Nathan Kim |
| Home: Scan storage | Storage scan (DAT-1) using `packages/scan_engine` | `lib/*/storage_scan/` | dreece44 |
| Scan storage → Summary | Storage Scan Results with the wasted space notice | `lib/presentation/storage_results/` | coilehayden0 |
| Scan storage → By category | Garbage Collection: send categories to the bin | `lib/presentation/garbage_collection/` | coilehayden0 |
| Home: Garbage storage | The bin's compressed file storage (DAT-17): files moved to the bin by the scans are gzipped when that saves space | `lib/presentation/garbage_storage/`, `lib/data/garbage_bin/file_bin.dart` | coilehayden0 |
| Home: Scan a folder | Classifier (DAT-16) and one-tap munch (DAT-18); moves what it finds to the Garbage Bin | `lib/models.dart`, `lib/classifier.dart`, `lib/muncher.dart`, `lib/presentation/folder_munch/` | nathangh-ung |
| Notification + home banner | Storage-full warning (DAT-36) | `lib/*/storage_alert/` | dreece44 |

`lib/application/storage_scan/team_views.dart` and `lib/presentation/team_pages.dart`
connect the storage scan to coilehayden0's and nathangh-ung's pages.

## Run it on the Android emulator

```bash
flutter pub get
flutter run -d emulator-5554
```

Scan storage and Scan a folder need "All files access"; the app asks for
it. Unused apps also need "Usage access"; the scan results offer a button
for it. To give the scan something to find, push the sample phone first:

```bash
adb push ../packages/scan_engine/sample_phone /sdcard/TeamTest
```

Each teammate's page can also run on its own, as they were built:

```bash
flutter run -t lib/presentation/storage_results/storage_results.dart
flutter run -t lib/presentation/garbage_storage/main.dart
flutter run -t lib/presentation/garbage_collection/main.dart
flutter run -t lib/presentation/folder_munch/main.dart
```

## Storage-full notifications (DAT-36)

The app warns before the phone fills up:

- **Low**: less than 10% of the phone, or 5 GB, free (whichever is smaller).
- **Almost full**: less than 5%, or 1 GB, free.

The warning appears as a phone notification and as a banner on the home page.
The banner also covers users who turned notifications off. A warning is
repeated at most once a day at the same level. It is sent again right away if
storage gets worse, and cleared once space is freed. Tapping it opens Scan
storage.

| | Android 7–12 | Android 13+ | iOS 15+ (iPhone, iPad) |
|---|---|---|---|
| Permission | Allowed by default | Asked on first launch | Asked on first launch |
| Background check | Every hour (WorkManager), survives reboot | Same | iOS decides when (Background App Refresh) |
| Also checked | App open, app back in front, after munching or emptying the bin | Same | Same |

To try it on the emulator, fill it up below the threshold and reopen the app.
The fill file is just zeros. Delete it afterwards:

```bash
adb shell fallocate -l 6G /sdcard/Download/fill.bin
adb shell rm /sdcard/Download/fill.bin
```

To run the background check now instead of waiting an hour, find the app's
WorkManager job id with
`adb shell dumpsys jobscheduler | grep "JOB androidx.work.systemjobscheduler.*datamuncher"`
(the number after the `/`), then run
`adb shell cmd jobscheduler run -f -n androidx.work.systemjobscheduler com.example.datamuncher <id>`.
On Android 13 and older, leave out `-n androidx.work.systemjobscheduler`.
WorkManager won't run the job during the first 30 minutes after the app
schedules it, so wait that long after installing.

On iOS, Background App Refresh must be on (Settings → General). In Xcode you
can trigger the check from the debugger with
`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.example.datamuncher.storageCheck"]`.

## Garbage Bin files

Files moved to the bin by Scan storage or Scan a folder go to a hidden
`.DataMuncherBin` folder on the same storage volume, next to a
`.datamuncher-index.json` listing where each came from. If the app's data
is cleared or it's reinstalled, it reads that list (once it has file access)
and the files show up in the bin again. Files found there with no entry go
back to `Download` when recovered.

## Tests

```bash
flutter test
```

On-device test of the teammates' pages (needs the sample phone pushed and
file access granted). The test uninstalls the app when it finishes, so
install it and grant access before each run:

```bash
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell appops set com.example.datamuncher MANAGE_EXTERNAL_STORAGE allow
adb shell pm grant com.example.datamuncher android.permission.READ_MEDIA_IMAGES
flutter test integration_test -d emulator-5554
```
