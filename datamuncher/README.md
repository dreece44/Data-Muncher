# DataMuncher app

The phone app that brings the team's work together. Every feature is in
this one app.

| Where in the app | What | Code | By |
|---|---|---|---|
| Home: Duplicates / Empty / Blurry, Munch my data | Photo library scan; duplicates grouped with the best copy kept (DAT-34) | `lib/core.dart`, `lib/rules.dart`, `lib/*/duplicate_groups/` | Nathan Kim, dreece44 |
| Home: bin icon | Garbage Bin viewer and Empty Bin (DAT-27/28) | `lib/*/garbage_bin/` | Nathan Kim |
| Home: Unused apps | Unused app detection with Uninstall and Keep (DAT-25) | `lib/*/apps/`, `android/.../MainActivity.kt` | Nathan Kim |
| Home: Do-not-collect list; Recover in the bin | Collection exclusion (DAT-32) | `lib/*/exclusion/` | Nathan Kim |
| Home: Plan; banner under each screen | Free with ads (DAT-38) and the ad-free subscription (DAT-39) | `lib/*/monetization/`, `lib/data/ads/` | Nathan Kim |
| Home: Scan storage | Storage scan (DAT-1) using `packages/scan_engine` | `lib/*/storage_scan/` | dreece44 |
| Scan storage → Summary | Storage Scan Results with the wasted space notice and Export Results | `lib/presentation/storage_results/` | coilehayden0 |
| Scan storage → Summary → Review Suggestions | Swipe review (PB-20): one card per kind of waste; swipe left to move it to the bin | `lib/presentation/storage_results/` | coilehayden0 |
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

**Unused apps on an emulator.** Every app on a fresh emulator was installed
in the last 90 days, so none count as unused. Run
`flutter run --dart-define=UNUSED_APP_DAYS=0` to list every app you installed
yourself.

**Billing mode.** Debug builds (`flutter run`) use **test mode**: subscribing
is simulated and no money is charged, so the emulator and demos just work.
Release builds always use the real App Store / Google Play. Override with
`--dart-define=BILLING=store` (e.g. to try Apple's sandbox) or
`--dart-define=BILLING=test`. The ads are Google's test ads.

**Demo photos.** `tool/demo_photos/` has seven photos made for the photo scan:
two duplicate pairs, a blurry photo, a black "pocket photo" and one keeper.
Drag them onto the iPhone Simulator, or `adb push` them to `/sdcard/Pictures/`
on Android. `DEMO.md` has the Sprint 4 demo script.

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

## DAT-25 — Unused app detection: acceptance criteria

1. An UNUSED APPS button on the home screen, with the number found once known.
2. Android: if Usage access is off, the screen explains why it's needed and opens the right Settings page; returning to the app checks again.
3. Apps not opened in 90 days are listed largest first, each with its icon, why it was flagged ("Last opened 200 days ago" / "Not opened in at least 90 days") and its size, plus a total.
4. Never suggested: pre-installed system apps, apps without a launcher icon, the default home screen, keyboard, SMS and phone apps, and apps installed in the last 90 days.
5. Tapping an app shows when it was last opened, installed, its size and package name.
6. Uninstall shows Android's own confirmation; the app leaves the list only if it was actually removed, and the message says how much space was freed.
7. Keep stops it being suggested for 30 days (DAT-32); it appears in the Do-not-collect list.
8. iPhone: the screen explains that iOS doesn't allow this and points to Settings → General → iPhone Storage.
9. If the Android code is missing from a build, the screen says so instead of failing silently.
10. Scan storage lists unused apps too, with a button to this screen.

Same detection rules as `UnusedAppDetector` in the scan engine (DAT-1), which Scan storage uses.

## DAT-32 — Collection Exclusion ("Do not collect"): acceptance criteria

1. Recovering a file from the Garbage Bin asks whether to mark it "Do not collect" for 30 days; "Just recover" recovers without it.
2. Scans skip marked files until their period ends; after that they can be flagged again. This covers the photo scan, Scan storage and Scan a folder (storage files are marked by path).
3. Image Select / Video Select show a shield on marked files. Collecting one by hand asks first and removes the mark.
4. A Do-not-collect list (home screen, and the shield icon on Unused Apps) shows every marked file and kept app with its end date ("Until Nov 30, 2026 · 30 days left").
5. Allow removes a mark early, with Undo.
6. Marks survive restarting the app; ended marks are cleared automatically. Marks made with the earlier version (30 days, no name) are carried over.

## DAT-38 — Ad-supported free tier: acceptance criteria

1. The app is free, and **every feature works on the free plan**. Ads never block, delay or unlock anything: there are no pop-up (interstitial) ads and no "watch an ad to unlock".
2. On the free plan, a small banner ad sits at the bottom of the home screen and the other screens (Garbage Bin, review pages, Unused apps, Do-not-collect list), below the content, never over it. The Plans screen has none.
3. Each banner has a **Remove ads** link to the Plans screen.
4. If an ad can't load (offline, no ad available), nothing is shown: no empty gap and no error.
5. The ad SDK isn't even started for ad-free users.
6. Uses Google AdMob with Google's official **test** ids, which show a "Test Ad" and pay nothing.

## DAT-39 — Ad-free subscription: acceptance criteria

1. A **Plans** screen (home → "Plan: Free · Remove ads", or any banner's Remove ads) compares Free and Ad-free and says plainly that both include every feature.
2. The price comes from the App Store / Google Play in the user's currency, shown as e.g. "$0.99 / month".
3. **Go ad-free** opens the store's own purchase sheet. When it completes, every banner disappears at once and the plan is remembered across restarts.
4. Cancelling the store sheet changes nothing; a failed payment says why; Ask to Buy shows "waiting for approval" and goes ad-free when approved.
5. **Restore purchases** finds an existing subscription on a new phone or after reinstalling.
6. On Android the app checks at each launch that the subscription is still active and brings ads back if it has ended. (On iPhone it doesn't check by itself, because a restore can ask the user to sign in; see limits.)
7. The screen states the billing terms the stores require: billed monthly, renews automatically, how and when to cancel, per store.
8. If the subscription can't be offered (store unreachable, product not set up), the screen says so with Try again.
9. Test mode (the default in debug builds, or `--dart-define=BILLING=test`) shows a clear "Test mode: no money is charged" notice, asks before a test purchase, and has **End test subscription** to switch back.

## Known limits / open decisions

- **Price (DAT-39 open question).** The app shows whatever price is set in the stores. Test mode uses a proposed **$0.99/month**; the team needs to confirm it.
- **Before release, the stores need setting up:** create a monthly auto-renewing subscription with product id `datamuncher_ad_free_monthly` in App Store Connect and the Google Play Console. Until then, real-billing builds show "subscription isn't available".
- **Real ads need an AdMob account:** replace Google's test app ids (`android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`) and banner ids (`--dart-define=ADMOB_BANNER_IOS=…` / `ADMOB_BANNER_ANDROID=…`). Never click real ads during testing.
- **Privacy consent isn't built yet.** Before releasing in the EU/UK, ads need Google's consent form (UMP), and on iPhone the App Tracking Transparency prompt if ads are personalised.
- **Subscriptions are checked on the phone only.** Without a server that verifies receipts, an iPhone keeps "Ad-free" after the subscription ends until the user restores purchases, and a restore can count an ended iPhone subscription. A receipt-checking server would fix both.

- **The "defined period of time" is 30 days** (team decision for DAT-32), set in one place: `exclusionPeriod` in `lib/application/exclusion/exclusion_list.dart`. Marking something again restarts its 30 days.
- **Unused apps is Android only.** iOS doesn't let apps see other apps. Usage access is a special permission the user turns on in Settings; it can't be granted from a pop-up.
- **The 90-day rule matches the scan engine's default** (`ScanRules.unusedAppAfter`). DAT-16 may tune it.
- **Uninstalling is one app at a time**, because Android requires a confirmation for each.

- **Space isn't freed immediately on phones with a trash.** The phone frees it after 30 days or when the user clears the trash. DAT-28 says "the space is reclaimed", so the team should confirm this is acceptable.
- **Retention is the phone's 30 days**, not a DataMuncher setting. DAT-31 still lists the retention period as an open question.
- **Only storage files are compressed.** Photo library items stay in the library (the bin is a list of their ids); files from Scan storage and Scan a folder are moved to the bin folder and gzipped when that helps (DAT-17). Nothing in the bin expires on its own.
- **Recover is one file at a time.** Selecting several files belongs to DAT-29.
- **Sizes are read from each file the first time**, which can be slow for iCloud photos; they're cached afterwards.

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
