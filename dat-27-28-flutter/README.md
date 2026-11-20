# DataMuncher — DAT-27 Garbage Bin Viewer & DAT-28 Garbage Bin Empty

Built on the photo-library draft app (`core.dart`, `pages.dart`, `rules.dart`, `main.dart`), which is included here because it isn't on GitHub yet. The Garbage Bin work is in `lib/data`, `lib/application`, `lib/presentation`, plus changes to `core.dart` and `pages.dart`.

## Setting this up

1. Run `flutter create datamuncher` to generate the `android/`, `ios/` and other platform folders.
2. Copy this folder's `lib/`, `test/` and `pubspec.yaml` into that project, replacing the placeholder files.
3. Add photo library permissions as described in the `photo_manager` setup guide (`AndroidManifest.xml` and iOS `Info.plist`).
4. `flutter pub get`, then `flutter test`.
5. `flutter run` on a phone. Test emptying the bin on an iPhone and on an Android 11+ phone; the trash behaviour only shows up on a real device.

`photo_manager` must be 3.x or later (it provides `editor.android.moveToTrash`).

## What's where

| Layer | Files |
|---|---|
| Data | `lib/data/garbage_bin/` — `BinEntry`, `GarbageBinStore` interface, `MunchBinStore` (reads the app's real bin), `InMemoryGarbageBinStore` (tests) |
| Application | `lib/application/garbage_bin/` — search/filter/sort, totals, viewer controller, Empty Bin outcome |
| Presentation | `lib/presentation/garbage_bin/` — Garbage Bin screen, list rows, details sheet, text formatting |
| App wiring | `lib/pages.dart` (`BinPage`), `lib/core.dart` (`MunchState`: reasons, deletion, trash detection) |

## DAT-27 — Garbage Bin Viewer: acceptance criteria

1. The bin icon on the home screen opens the Garbage Bin and lists every file in it.
2. Each row shows a thumbnail (or type icon), file name, why it was collected, size, when it was collected, and the folder it came from.
3. A summary shows the number of files and their total size.
4. Newest first by default; can sort by oldest, largest, name, or leaving soonest.
5. Search by name, folder or reason; filter by type; "Showing X of Y" while filtering; a way back when nothing matches.
6. Tapping a file shows its details and a larger preview.
7. An empty bin shows an explanatory message.
8. If the bin can't be read: error with Try again, nothing changed. A failed refresh keeps the last list with a warning.
9. The list updates on its own when files enter or leave the bin; pull-to-refresh works.
10. Recover returns a file to the library and offers "Do not collect" for 30 days.
11. Delete asks first, goes to the phone's trash where there is one, and asks again before a permanent delete.
12. Files deleted outside DataMuncher are cleaned out of the bin so the home-screen count stays right.

## DAT-28 — Garbage Bin Empty: acceptance criteria

1. An Empty Bin button in the Garbage Bin's top bar, shown only when the bin has files.
2. The confirmation states the number of files and their size, where they go, and warns when a search or filter is hiding some of them.
3. iOS: files go to Recently Deleted. Android 11+: files go to the system trash. Either way they can be restored for 30 days (PB-17).
4. Android 10 and older (no trash): the confirmation says the files can't be recovered; nothing is deleted permanently without that warning.
5. Afterwards a message says what happened: everything removed, only some (the phone's own prompt can be refused), or nothing, and how much space is involved.
6. A progress bar shows while emptying and the button can't be pressed twice.
7. The home screen's storage ring and bin count update afterwards.

## Known limits / open decisions

- **Space isn't freed immediately on phones with a trash.** The phone frees it after 30 days or when the user clears the trash. DAT-28 says "the space is reclaimed", so the team should confirm this is acceptable.
- **Retention is the phone's 30 days**, not a DataMuncher setting. DAT-31 still lists the retention period as an open question.
- **No compression or time limit in the bin yet.** The bin is a list of ids, so files never show as compressed and have no expiry until DAT-17 (bin storage) is built.
- **Recover is one file at a time.** Selecting several files belongs to DAT-29.
- **Sizes are read from each file the first time**, which can be slow for iCloud photos; they're cached afterwards.
- Not compiled here (no Flutter SDK available). All files pass a Dart syntax check and every expected value in the tests was recomputed independently.
