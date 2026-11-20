# scan_engine

The DataMuncher scanning engine (Jira **DAT-1**). It walks a device's storage
and reports wasted space. It has no UI and no Flutter dependency, so the same
code runs on phones and on a development computer.

| Category | What counts | Detector |
|---|---|---|
| Empty files | 0-byte files; small files holding only whitespace or zero bytes. `.nomedia` markers are ignored. | `EmptyFileDetector` |
| Unreadable files | Won't open; unfinished downloads (`.crdownload`, `.part`…); contents don't match the type (a "PDF" that's really a 404 page); zero-filled; cut off (PDF/PNG/ZIP/MP4 missing their end); videos missing their index; damaged image data | `UnreadableFileDetector` |
| Duplicate photos | Identical or near-identical photos (re-saved, resized, burst shots). Grouped with one copy to keep. | `DuplicatePhotoDetector` |
| Blank photos | Photos that are one flat colour: pocket shots, all-white screenshots | `BlankPhotoDetector` |
| Unused apps | Apps not opened in 90 days (Android only; iOS doesn't allow it) | `UnusedAppDetector` |

Thresholds live in `ScanRules` (`lib/src/scan/scan_rules.dart`) for the
classification ruleset story (DAT-16) to tune.

## Permissions

`ScanEngine.scan()` checks the device's storage permission **before reading
anything**. If it isn't granted, the scan throws `PermissionDeniedException`
and no storage is touched. The device's storage source is also wrapped in
`PermissionGuardedStorageSource`, which refuses to list or read without
permission, so the rule holds even for code that bypasses the engine.

| Device | Required to scan | Optional |
|---|---|---|
| Android | Storage access ("All files access" on Android 11+) | Usage access, for unused apps |
| iPhone | Photo library access (Full or Limited) | none |

A missing optional permission skips that one category; the rest still runs.

## Using it

```dart
final engine = ScanEngine(device: await currentDevice()); // from scan_engine_flutter
final report = await engine.scan(onProgress: (p) => print(p));
print(formatReport(report));      // human-readable
final json = report.toJson();     // for the UI
```

## Testing on your computer

Requires the Dart SDK (included with Flutter). From this folder:

```bash
dart pub get
```

**1. Automated tests.** 47 tests, including the permission gate, each detector and a full scan of a real folder.

```bash
dart test
```

**2. Build a fake phone.** This writes `sample_phone/` (fake phone storage with planted waste) and `sample_phone_apps.json` (fake installed apps).

```bash
dart run tool/make_sample_storage.dart
```

**3. Check the permission gate.** Without `--grant-access` the scan must refuse (exit code 2):

```bash
dart run scan_engine:scan sample_phone
```

**4. Run a full scan** as an Android phone with storage and usage access granted:

```bash
dart run scan_engine:scan sample_phone --grant-access --apps sample_phone_apps.json --grant-usage-access
```

It should find exactly this:

| Category | Expected |
|---|---|
| Empty files (2) | `Documents/todo.txt`, `Download/podcast_episode.mp3` |
| Unreadable files (8) | damaged `IMG_20260917_080000.jpg`, zero-filled `scan_copy.jpg`, `.crdownload`, cut-off `invoice_0042 (1).pdf`, fake `lease_agreement.pdf`, cut-off `receipts_backup.zip`, two broken `.mp4`s |
| Duplicate photos (2 groups) | the 4 hike shots (incl. the WhatsApp copy); the receipt photographed twice |
| Blank photos (2) | the black pocket shot, the white screenshot |
| Unused apps (2) | Lingua+ (never opened), Puzzle Quest (200 days) |

It should *not* report: the different receipt `IMG_20260914_091500.jpg`, the
small `red_dot.png` icon, `.nomedia`, the hidden `.thumbnails` cache, the
valid PDF/ZIP/MP4, the recently installed game, or the essential and system
apps.

**5. Try variations**

```bash
dart run scan_engine:scan sample_phone --simulate ios --grant-access
```

Follows iPhone rules: needs photo access; unused apps show as unsupported.

```bash
dart run scan_engine:scan sample_phone --grant-access --limited
```

Limited access: the report adds a note about it.

```bash
dart run scan_engine:scan sample_phone --grant-access --json
```

Full JSON report, the shape the UI will consume.

You can point the scanner at any folder, e.g. a copy of your own phone's
photos, to see how it behaves on real data. It only reads; it never deletes
or changes anything.

Testing on a real phone or emulator is covered in
[`../scan_engine_flutter/README.md`](../scan_engine_flutter/README.md).

## Layout

```
lib/src/scan/          ScanEngine, ScanRules, ScanContext (shared per-scan state), progress
lib/src/permissions/   ScanPermission, PermissionService, the permission-guarded source
lib/src/detectors/     one file per waste category
lib/src/imaging/       thumbnails, perceptual hashes, pure-Dart decoder
lib/src/platform/      interfaces a device implements: DeviceAdapter, StorageSource, AppInventory
lib/src/sources/       folder, composite and in-memory sources; the desktop LocalDeviceAdapter
bin/scan.dart          command-line scanner
tool/                  sample-storage generator
```

To add a category (blurry photos DAT-22, screenshots DAT-23, old videos
DAT-24, duplicate documents DAT-3): add it to `WasteCategory`, write a
`WasteDetector` subclass, and add it to `ScanEngine.defaultDetectors()`.
