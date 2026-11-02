# DataMuncher app

The phone app that brings the team's work together.

| Where in the app | What | Code | By |
|---|---|---|---|
| Home: Duplicates / Empty / Blurry, Munch my data | Photo library scan | `lib/core.dart`, `lib/rules.dart` | Nathan Kim |
| Home: bin icon | Garbage Bin viewer and Empty Bin (DAT-27/28) | `lib/*/garbage_bin/` | Nathan Kim |
| Home: Scan storage | Storage scan (DAT-1) using `packages/scan_engine` | `lib/*/storage_scan/` | dreece44 |
| Scan storage → Summary | Storage Scan Results with the wasted space notice | `lib/presentation/storage_results/` | coilehayden0 |
| Scan storage → By category | Garbage Collection: send categories to the bin | `lib/presentation/garbage_collection/` | coilehayden0 |
| Home: Garbage storage | Compressed temporary storage (DAT-17) | `lib/presentation/garbage_storage/` | coilehayden0 |
| Home: Scan a folder | Classifier (DAT-16) and one-tap munch (DAT-18) | `lib/models.dart`, `lib/classifier.dart`, `lib/muncher.dart`, `lib/presentation/folder_munch/` | nathangh-ung |

`lib/application/storage_scan/team_views.dart` and `lib/presentation/team_pages.dart`
connect the storage scan to coilehayden0's and nathangh-ung's pages.

## Run it on the Android emulator

```bash
flutter pub get
flutter run -d emulator-5554
```

Scan storage and Scan a folder need "All files access"; the app asks for
it. To give the scan something to find, push the sample phone first:

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
