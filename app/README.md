# DataMuncher app — Garbage Bin (DAT-27, 28), Unused apps (DAT-25), Do not collect (DAT-32), Free with ads (DAT-38), Ad-free subscription (DAT-39)

Built on the photo-library draft app (`core.dart`, `pages.dart`, `rules.dart`, `main.dart`), which is included here because it isn't on GitHub yet. Sprint 2 added the Garbage Bin; Sprint 3 unused app detection and the Do-not-collect list; Sprint 4 the free-with-ads plan and the optional ad-free subscription.

## Setting this up

From this folder:

```
dart run tool/setup_platforms.dart
flutter pub get
flutter test
flutter run
```

`tool/setup_platforms.dart` does the platform setup that used to be manual, and is safe to run again:

- runs `flutter create` if `android/` or `ios/` is missing, and removes Flutter's sample test;
- adds the photo, usage-access and uninstall permissions to `AndroidManifest.xml`;
- installs the Android code for unused apps into `MainActivity.kt` (edit `tool/android/MainActivity.kt`, not the generated copy);
- adds the photo library messages iPhone requires to `Info.plist`;
- adds the AdMob app ids (Google's test ids) to Android and iPhone, and raises Android to API 24 / iPhone to iOS 13 if lower (needed by the ads and subscription plugins).

- names the app "DataMuncher" and installs its icon (`tool/branding/`).

**Billing mode.** Debug builds (`flutter run`) use **test mode**: subscribing is simulated and no money is charged, so the simulator and demos just work. Release builds always use the real App Store / Google Play. Override with `--dart-define=BILLING=store` (e.g. to try Apple's sandbox) or `--dart-define=BILLING=test`.

**Demo photos.** `tool/demo_photos/` has seven photos made for the scan: two duplicate pairs, a blurry photo, a black "pocket photo" and one keeper. Drag them onto the simulator window. See `DEMO.md` for the full demo script.

`photo_manager` must be 3.x or later (it provides `editor.android.moveToTrash`). Test emptying the bin on an iPhone and on an Android 11+ phone, and unused apps on an Android phone or emulator; those only show up on a real device.

## What's where

| Layer | Files |
|---|---|
| Data | `lib/data/garbage_bin/` — `BinEntry`, `GarbageBinStore` interface, `MunchBinStore` (reads the app's real bin), `InMemoryGarbageBinStore` (tests) |
| | `lib/data/apps/` — `InstalledApp`, `AppInventory` (Android channel, iPhone "unsupported") |
| | `lib/data/exclusion/` — saves the Do-not-collect list in SharedPreferences |
| Application | `lib/application/garbage_bin/` — search/filter/sort, totals, viewer controller, Empty Bin outcome |
| | `lib/application/apps/` — unused-app rules, Unused Apps controller |
| | `lib/application/exclusion/` — `ExclusionList` (periods, expiry, saving) |
| Presentation | `lib/presentation/garbage_bin/` — Garbage Bin screen, list rows, details sheet, text formatting |
| | `lib/presentation/apps/` — Unused Apps screen, app icons |
| | `lib/presentation/exclusion/` — Do-not-collect screen, period picker |
| | `lib/application/monetization/` — plans, `MonetizationController`, `SubscriptionGateway` interface |
| | `lib/data/monetization/` — App Store / Google Play billing, test mode, saved plan |
| | `lib/data/ads/` — AdMob banners (`AdProvider`) |
| | `lib/presentation/monetization/` — Plans screen, banner slot |
| Android | `tool/android/MainActivity.kt` — usage history, installed apps, sizes, icons, uninstall dialog |
| App wiring | `lib/main.dart` (home buttons), `lib/pages.dart` (`BinPage`, `ReviewPage`, `DoNotCollectPage`), `lib/core.dart` (`MunchState`) |

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
10. Recover returns a file to the library and offers "Do not collect" (see DAT-32).
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

## DAT-25 — Unused app detection: acceptance criteria

1. An UNUSED APPS button on the home screen, with the number found once known.
2. Android: if Usage access is off, the screen explains why it's needed and opens the right Settings page; returning to the app checks again.
3. Apps not opened in 90 days are listed largest first, each with its icon, why it was flagged ("Last opened 200 days ago" / "Not opened in at least 90 days") and its size, plus a total.
4. Never suggested: pre-installed system apps, apps without a launcher icon, the default home screen, keyboard, SMS and phone apps, and apps installed in the last 90 days.
5. Tapping an app shows when it was last opened, installed, its size and package name.
6. Uninstall shows Android's own confirmation; the app leaves the list only if it was actually removed, and the message says how much space was freed.
7. Keep stops it being suggested for 30 days (DAT-32); it appears in the Do-not-collect list.
8. iPhone: the screen explains that iOS doesn't allow this and points to Settings → General → iPhone Storage.
9. If the Android code is missing from a build, the screen says to run the setup script instead of failing silently.

For a demo on an emulator, where every app is newly installed, run `flutter run --dart-define=UNUSED_APP_DAYS=0` so every app you installed yourself is listed.

Same detection rules as `UnusedAppDetector` in Devin's scan engine (DAT-1); `InstalledApp` uses the same fields, so the two can be swapped once that package is merged.

## DAT-32 — Collection Exclusion ("Do not collect"): acceptance criteria

1. Recovering a file from the Garbage Bin asks whether to mark it "Do not collect" for 30 days; "Just recover" recovers without it.
2. Scans skip marked files until their period ends; after that they can be flagged again.
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
- **Real ads need an AdMob account:** replace Google's test app ids (`tool/setup_platforms.dart`) and banner ids (`--dart-define=ADMOB_BANNER_IOS=…` / `ADMOB_BANNER_ANDROID=…`). Never click real ads during testing.
- **Privacy consent isn't built yet.** Before releasing in the EU/UK, ads need Google's consent form (UMP), and on iPhone the App Tracking Transparency prompt if ads are personalised.
- **Subscriptions are checked on the phone only.** Without a server that verifies receipts, an iPhone keeps "Ad-free" after the subscription ends until the user restores purchases, and a restore can count an ended iPhone subscription. A receipt-checking server would fix both.

- **The "defined period of time" is 30 days** (team decision for DAT-32), set in one place: `exclusionPeriod` in `lib/application/exclusion/exclusion_list.dart`. Marking something again restarts its 30 days.
- **Unused apps is Android only.** iOS doesn't let apps see other apps. Usage access is a special permission the user turns on in Settings; it can't be granted from a pop-up.
- **The 90-day rule matches the scan engine's default** (`ScanRules.unusedAppAfter`). DAT-16 may tune it.
- **Uninstalling is one app at a time**, because Android requires a confirmation for each.

- **Space isn't freed immediately on phones with a trash.** The phone frees it after 30 days or when the user clears the trash. DAT-28 says "the space is reclaimed", so the team should confirm this is acceptable.
- **Retention is the phone's 30 days**, not a DataMuncher setting. DAT-31 still lists the retention period as an open question.
- **No compression or time limit in the bin yet.** The bin is a list of ids, so files never show as compressed and have no expiry until DAT-17 (bin storage) is built.
- **Recover is one file at a time.** Selecting several files belongs to DAT-29.
- **Sizes are read from each file the first time**, which can be slow for iCloud photos; they're cached afterwards.
## How this was checked

- `dart analyze` with `flutter_lints` against **Flutter 3.47.9** and the real plugin sources: no issues in `lib/`, `test/` or `tool/`.
- The non-UI tests (92: scan rules, formatting, Garbage Bin queries and Empty Bin reports, Do-not-collect list, unused-app rules and controller, subscription logic) were run on the Dart VM.
- The demo photos were run through the app's real scan rules (`rules.dart`): 2 duplicates, 1 blurry, 1 black screen, 3 kept.
- `tool/setup_platforms.dart` was run twice on a project built from Flutter 3.47.9's own `flutter create` templates.
- Not run here: the widget (screen) tests and the app on a device, which need Flutter's engine. Run `flutter test` and try it on the simulator.
