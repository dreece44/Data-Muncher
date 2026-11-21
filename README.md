# DataMuncher - A Flutter Storage Cleaner

DataMuncher is a mobile app built with Flutter and Dart that finds wasted space on a phone and helps clear it safely. One tap scans the photo library for duplicates, blurry shots and black "pocket photos", sends them to a Garbage Bin where nothing is lost until you say so, scans the phone's files for empty, damaged and duplicate ones, warns before storage fills up, and points out apps you haven't opened in months. Every feature is free; an optional subscription removes the ads.

## Features

### Scanning
- **Munch My Data**: One-tap scan of the photo library.
- **Duplicate Photos**: Groups copies of the same photo and keeps the best one (sharpest, largest).
- **Blurry Photos**: Flags shots that are out of focus.
- **Empty Photos**: Flags black or blank "pocket photos".
- **Review Results**: Shows what the scan found, grouped as duplicates, blurry and empty, before anything is collected.
- **Scan Storage** (Android): Scans the phone's files for empty, unreadable and duplicate files and black photos, with a summary of wasted space, a swipe-through review of each kind, and a text report to export.
- **Scan a Folder** (Android): The same checks, plus blurry photos, for one folder you pick.
- **Storage-full Warning**: A notification and a home-screen banner when the phone is nearly full.

### Garbage Bin
- **Garbage Bin Viewer**: Every collected file with its preview, size, reason and where it came from.
- **Search, Sort and Filter**: By name, folder, reason, type, size or date.
- **Recover a File**: Put a file back if it was collected by mistake.
- **Empty the Bin**: Photos and videos go to the phone's Recently Deleted, so they can still be recovered for 30 days. Files from the storage scans are deleted for good, after a warning.
- **Compressed Storage**: Files from the storage scans are kept compressed in the bin when that saves space; the Garbage Storage page shows the space saved and can compress or delete several at once.

### Safety
- **Do Not Collect**: Mark a file or app so scans leave it alone for 30 days.
- **Manage the List**: See everything marked, allow it again or undo.

### Apps
- **Unused Apps** (Android): Lists apps not opened in 90 days with their size, and opens Android's uninstall screen. Essential, system and recently installed apps are never suggested. The storage scan lists them too.

### Plans
- **Free with Ads**: Every feature, with a small banner at the bottom of the screen. No pop-ups and nothing locked behind an ad.
- **Ad-free Subscription**: A monthly subscription through the App Store or Google Play that removes the ads, with Restore purchases.

## Getting Started

> DataMuncher runs on iPhone (iOS 15 or later) and Android (7.0 or later). Building the iPhone version needs a Mac with Xcode. The storage and folder scans and Unused Apps are Android only, because iOS doesn't let apps see other apps' files.

### Requirements

- [Flutter](https://docs.flutter.dev/get-started/install) 3.32 or later (includes Dart)
- For iPhone: a Mac with [Xcode](https://developer.apple.com/xcode/), an iOS Simulator runtime, and CocoaPods
- For Android: [Android Studio](https://developer.android.com/studio) with an emulator or a phone

Check your setup with:
```bash
flutter doctor
```

### Building From Source Code

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/dreece44/Data-Muncher.git
   ```
2. **Move Directory**:
   ```bash
   cd Data-Muncher/datamuncher
   ```
3. **Get Packages**:
   ```bash
   flutter pub get
   ```
4. **Open a Simulator** (Mac) or start an Android emulator:
   ```bash
   open -a Simulator
   ```
5. **Run App**:
   ```bash
   flutter run
   ```
   Tap **Allow Full Access** when the app asks for photos.

> **Tip**: Drag the photos in `datamuncher/tool/demo_photos/` onto the simulator window to give the scan something to find. `datamuncher/DEMO.md` has a full walkthrough, and `datamuncher/README.md` explains how to try the storage scan on an Android emulator.

> **Note**: Debug builds use a test mode for the subscription, so nothing is charged. The ads are Google's test ads.

### Running the Tests

```bash
cd Data-Muncher/datamuncher
flutter test
```

## Project Structure

| Folder | What it is |
|---|---|
| `datamuncher/` | The DataMuncher app: every feature above. See `datamuncher/README.md` for how it's built. |
| [`packages/scan_engine`](packages/scan_engine) | The scanning engine (pure Dart). Runs on phones and on a computer, with a command-line scanner for testing. |
| [`packages/scan_engine_flutter`](packages/scan_engine_flutter) | Android and iOS adapters for the engine: storage, photos, apps and permissions on real devices. |
| [`packages/deep_scans`](packages/deep_scans) | Focused scans for duplicate documents, blurry photos, screenshots and large old videos, with their rulesets in `docs/`. Command-line tools for now; they are not in the app yet. |

## Team

| Member | Work |
|---|---|
| Nathan Kim | App UI, file classification rules, Munch My Data, Garbage Bin viewer and emptying, unused apps, Do not collect, post-scan summary, ads and subscription |
| Devin Reece | Scan engine, storage permissions, duplicate, blurry, screenshot, empty and large video detection |
| Hayden Coile | Architecture, Garbage Bin storage and compression, bulk deletion, backups, file recovery, storage results, swipe review |
