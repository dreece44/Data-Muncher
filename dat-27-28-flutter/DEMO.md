# DataMuncher demo (iPhone Simulator)

Sprint 4: **DAT-38 Free with ads** and **DAT-39 Ad-free subscription**, in the full app (Garbage Bin, Do not collect, unused apps from earlier sprints).

## Before the demo (once, ~10 minutes)

In Terminal, in this folder:

```
dart run tool/setup_platforms.dart
flutter pub get
flutter test
```

`flutter test` should end with **All tests passed!**

Then:

1. Open the simulator: `open -a Simulator` (or Xcode → Open Developer Tool → Simulator).
2. Drag the 7 photos from `tool/demo_photos/` onto the simulator window. They land in the Photos app.
3. Start the app: `flutter run`. Pick the iPhone if asked. The first build takes a few minutes.
4. Tap **Allow Full Access** when it asks for photos.
5. Do a quick rehearsal. To reset afterwards: delete the app from the simulator (long-press the icon → Remove App), then `flutter run` again.

Debug builds use **test mode** for the subscription: it's simulated and nothing is charged. The banner ads are Google's **test ads** (labelled "Test Ad") and need the Mac to be online.

## What the scan will find

| Photo | Found as |
|---|---|
| Yosemite trail + (copy) | 1 duplicate |
| Receipt scan + (2) | 1 duplicate |
| Sunset (blurry) | blurry |
| Pocket photo (black) | empty (black screen) |
| City at night | kept |

## Script (about 3 minutes)

**Intro** *(home screen)*
"This sprint I built how DataMuncher makes money without taking anything away: DAT-38, a free plan with ads, and DAT-39, an optional subscription that removes them."

**DAT-38: Free with ads** *(point to the banner at the bottom)*
"On the free plan every feature works. The only difference is this small banner at the bottom. It sits under the content, never over it, and there are no pop-up ads or 'watch an ad to unlock'."

*(Tap DUPLICATES, then back; open the Garbage Bin icon, then back)*
"Every screen works the same, with the banner underneath. If an ad can't load, nothing shows, so there's never an empty gap. These are Google's test ads, so nothing is real or paid."

**DAT-39: Ad-free subscription** *(tap **Remove ads** under the banner)*
"Remove ads opens the Plans screen. Both plans list every feature; Ad-free just removes the ads. The price comes from the App Store, and the screen states the billing terms Apple requires: monthly, renews automatically, how to cancel."

*(Point to the Test mode notice)*
"For the demo it's in test mode, so no money is charged. In the real app this is Apple's own purchase sheet."

*(Tap **Go ad-free for $0.99 / month** → **Subscribe (test)**)*
"I'll subscribe..." *(the screen changes to "You're ad-free")*

*(Go back to home)*
"...and every banner is gone, everywhere. The plan is remembered after restarting, and Restore purchases brings it back on a new phone."

*(Optional: Plans → **End test subscription**, back to home: the banner returns)*
"In test mode I can end it to show the ads come back."

**Quick recap of the app** *(if time allows)*
"With ads or without, the app is the same: **MUNCH MY DATA** sends the duplicate, blurry and black photos to the Garbage Bin; I can recover one and mark it **Do not collect** for 30 days, and empty the bin into the phone's Recently Deleted."

**Wrap-up**
"Open decisions for the team: the price (I proposed $0.99 a month), setting up the subscription in App Store Connect and Google Play, a real AdMob account, and the EU consent form for ads before release."

## If something goes wrong

- **No banner:** the Mac is offline, or Google had no test ad. The app still works; say "ads load in the background and never block anything".
- **Plans says the subscription isn't available:** the app was run with `--dart-define=BILLING=store`. Run plain `flutter run`.
- **Build error about CocoaPods or the iOS version:** run `dart run tool/setup_platforms.dart` again, then `flutter run`.
- **Scan finds nothing:** check the photos were dragged in and photo access was allowed (Settings → Privacy & Security → Photos → DataMuncher → Full Access).
