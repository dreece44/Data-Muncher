# DataMuncher (Flutter) — DAT-16 & DAT-18

| File | Ticket | What it does |
|---|---|---|
| `lib/models.dart` | — | Shared data shapes (`FileRecord`, `WasteCategory`, etc.) both tickets use |
| `lib/classifier.dart` | **DAT-16** | The ruleset: flags empty, unreadable, and duplicate files |
| `lib/muncher.dart` | **DAT-18** | Scans a folder and runs it through DAT-16 — the one-tap entry point |
| `lib/main.dart` | — | The app screen (matches the team wireframe) that calls DAT-18 |
| `test/classifier_test.dart` | DAT-16 | Unit tests for the ruleset |
| `test/muncher_test.dart` | DAT-18 | Tests the scan using a real temp folder |

## Setting this up

1. Install Flutter: https://docs.flutter.dev/get-started/install
2. Run `flutter create datamuncher` — this generates the `android/`, `ios/`,
   and other platform folders this zip doesn't include (they're
   machine-generated, not meant to be hand-edited or shared as plain files).
3. Copy this zip's `lib/`, `test/`, and `pubspec.yaml` into that generated
   project, replacing the placeholder files Flutter created.
4. Run `flutter pub get` to install `crypto` and `file_picker`.
5. Run `flutter test` — 7 tests should pass.
6. Run `flutter run` to launch it on a simulator or connected device.

## What's real vs. what's a placeholder

- **DUPLICATES** and **EMPTY** are fully working — same logic as the Python
  version, scanning whatever folder the user picks.
- **BLURRY** is shown on the screen but disabled — it's in your team's
  wireframe but isn't part of DAT-16/18's actual scope yet.
- **MUNCH MY DATA** scans and displays results, but does not delete real
  files. Actual deletion belongs to the separate Garbage Collection feature,
  not DAT-16/18.
- On a real phone, the folder picker only grants access to the folder the
  user explicitly picks — not the whole device. That's a normal iOS/Android
  security restriction, not a bug in this code.
