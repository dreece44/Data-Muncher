# deep_scans

Focused deep scans for DataMuncher. Each one targets a single kind of waste
in more depth than the mass scan in [`scan_engine`](../scan_engine), and can
be run, tested and tuned on its own. They'll be merged back into the mass
scan once each has been optimised. `scan_engine` itself is not modified;
this package only depends on it.

| Scan | Jira | Ruleset |
|---|---|---|
| Empty & unreadable files | DAT-20 | [docs/EMPTY_UNREADABLE_RULESET.md](docs/EMPTY_UNREADABLE_RULESET.md) |
| Duplicate photos | DAT-21 | [docs/DUPLICATE_PHOTO_RULESET.md](docs/DUPLICATE_PHOTO_RULESET.md) |
| Duplicate documents (non-image files) | DAT-3 | [docs/DUPLICATE_DOCUMENT_RULESET.md](docs/DUPLICATE_DOCUMENT_RULESET.md) |
| Blurry photos | DAT-22 | [docs/BLURRY_PHOTO_RULESET.md](docs/BLURRY_PHOTO_RULESET.md) |
| Screenshots | DAT-23 | [docs/SCREENSHOT_RULESET.md](docs/SCREENSHOT_RULESET.md) |
| Large & old videos | DAT-24 | [docs/LARGE_OLD_VIDEO_RULESET.md](docs/LARGE_OLD_VIDEO_RULESET.md) |

From this folder (`packages/deep_scans`), install dependencies and run the
automated tests for every scan (unit tests per rule, plus a full run over
each freshly generated test area):

```bash
dart pub get
```

```bash
dart test
```

Every scan's command-line tool refuses to run without `--grant-access`
(exit code 2), the same permission gate as the mass scan. They only read:
you can point them at any folder.

## Empty & unreadable files

14 rules (E01–E05 empty, U01–U09 unreadable), each with a confidence level
(`certain` / `likely`) and evidence for tuning. See the ruleset for the full
list, precedence, knobs and the accuracy/performance baseline.

**1. Build the test area.** Writes `test_area/empty_unreadable/` (git-ignored):
92 planted files in `files/empty`, `files/unreadable` and `files/healthy`
(look-alikes that must *not* be flagged), plus `expected.json` with the rule
each file should get and why.

```bash
dart run tool/make_empty_unreadable_test_area.dart
```

**2. Scan it.** Pointed at a test area, the scanner checks every result
against `expected.json` and exits 1 if any don't match. It should end with
`Deep scan: 92/92 expectations met`.

```bash
dart run deep_scans:empty_unreadable_scan test_area/empty_unreadable --grant-access
```

**3. Compare with the mass scan.** Adds a column showing what the current
`EmptyFileDetector` + `UnreadableFileDetector` say about each file.

```bash
dart run deep_scans:empty_unreadable_scan test_area/empty_unreadable --grant-access --compare
```

## Duplicate photos

Six rules (D01 identical, D02 resized/re-saved, D03 rotated/mirrored, D04
borders added, D05 edited, D06 near-identical shot), exclusions for blank,
tiny and damaged photos, and a keeper suggestion (K01–K07: sharpest shot,
highest resolution, camera details, original folder…). See the ruleset for
the thresholds and the measurements behind them.

**1. Build the test area.** Writes `test_area/duplicate_photos/`
(git-ignored): a fake phone's photo folders with 8 planted duplicate groups,
one per scenario in the project doc (Alexa's hike shot copied six ways, her
food burst, Ethan's receipt retakes, Jasmine's wedding deliveries, a
screenshot copy, RAW and vacation backups), plus 11 look-alikes that must
stay apart (different receipts in the same layout, the same view a week
later, blank and sticker copies…). `expected.json` lists every group, its
keeper and each member's rule.

```bash
dart run tool/make_duplicate_photo_test_area.dart
```

**2. Scan it.** Checks every group, keeper and rule, and exits 1 on any miss.
It should end with `Deep scan: 8/8 groups exactly right, 0 unexpected; pair
precision 100%, recall 100%`.

```bash
dart run deep_scans:duplicate_photo_scan test_area/duplicate_photos --grant-access
```

**3. Compare with the mass scan.** Adds the current `DuplicatePhotoDetector`'s
result for each group, and its precision/recall.

```bash
dart run deep_scans:duplicate_photo_scan test_area/duplicate_photos --grant-access --compare
```

## Duplicate documents

Five rules for non-image files (F01 identical, F02 re-saved with new
metadata/compression/encoding, F03 same text in another file or format, F04
lightly edited version, F05 repeated scan), guards that keep records from
one template apart (related names, reference numbers, scan time window), and
a keeper suggestion (K01–K07: newest version, clearest scan, original
folder…). Empty and unreadable files are left to the empty & unreadable
scan, which runs alongside; cut-off downloads are linked to the document
they're a copy of. Images are left to the duplicate photo scan. There is no
mass-scan equivalent yet, so there's no `--compare`.

**1. Build the test area.** Writes `test_area/duplicate_documents/`
(git-ignored): a fake phone's Documents, Download, WhatsApp, Telegram and
Bluetooth folders with 11 planted groups (Ethan's re-downloaded invoice,
his rescanned delivery note, a report copied, re-zipped and exported to
PDF, manifest drafts…), 19 look-alikes that must stay apart (invoices and
leases from one template, next month's manifest, next week's delivery
note…), and 11 empty, unreadable or still-downloading documents that must
be left out with the right E/U rule.

```bash
dart run tool/make_duplicate_document_test_area.dart
```

**2. Scan it.** Checks every group, keeper and rule, every look-alike and
every left-out document, and exits 1 on any miss. It should end with
`Deep scan: 11/11 groups exactly right, 0 unexpected; pair precision 100%,
recall 100%; 11/11 empty/unreadable cases right`.

```bash
dart run deep_scans:duplicate_document_scan test_area/duplicate_documents --grant-access
```

One planted download counts as "in progress" for 10 minutes after the area
is built. The expectations follow the clock, and `--grace-minutes 0` judges
it straight away.

## Blurry photos

Four rules (B01 severely blurry, B02 blurry, B03 motion blur, B04 blurry
attempt with a sharper retake), each photo scored 0–100 and ranked
blurriest first. Blur is the width of the photo's edges in its *sharpest*
region, so portrait-mode and panning shots with a sharp subject aren't
flagged; fog, screenshots, icons and blank shots are left out. The empty &
unreadable checks run alongside, and photos they flag (0-byte, cut-off,
damaged, still downloading) are reported under their E/U rules. There is no
mass-scan equivalent yet, so there's no `--compare`.

**1. Build the test area.** Writes `test_area/blurry_photos/` (git-ignored):
a fake phone's camera roll with blurry photos from each scenario in the
project doc (Alexa's hike attempt and shaky lunch, Gerald's mini-golf swing
and food fight, Ethan's receipt retakes), 7 empty or unreadable photos from
failed downloads, and 21 look-alikes that must not be flagged (portrait
mode, panning, fog, night shots, small and compressed copies, a different
receipt that looks like a retake…).

```bash
dart run tool/make_blurry_photo_test_area.dart
```

**2. Scan it.** Checks every photo's rule, every retake and the ranking
order, and exits 1 on any miss. It should end with `Deep scan: 37/37
expectations met (blurry 9/9, empty/unreadable 7/7, look-alikes 21/21);
ranking right`.

```bash
dart run deep_scans:blurry_photo_scan test_area/blurry_photos --grant-access
```

Try `--blurry-width 2.0`, `--severe-width 3.0` or `--analysis-size 768` to
see how the thresholds move results, and `--top 20` to list more of the
ranking.

## Screenshots

Six rules: four that recognise a screenshot (S01 named by the capture
tool, S02 marked in its metadata, S03 in a screenshots folder, S04 looks
like a phone screen: status bar plus an app's flat background) and two
for screenshots with nothing on them (S05 blank, S06 only the status bar
or taskbar). Camera data always wins (a photo in the Screenshots folder
isn't flagged), and screenshots from the last two days are held back. The
empty & unreadable checks run alongside: screenshot files that saved as 0
bytes, were cut off, never synced or never finished downloading are
reported under their E/U rules. Findings are grouped into batches for bulk
review (blank & empty, can't be opened, phone, computer…). There is no
mass-scan equivalent yet, so there's no `--compare`.

**1. Build the test area.** Writes `test_area/screenshot_detection/`
(git-ignored): Alexa's phone screenshots (Instagram, recipes, chats, a
Netflix black frame, a page that hadn't loaded, one shared over WhatsApp),
Ethan's iPhone export and broken screenshot files, Timmy's Windows, Mac,
Linux, Game Bar and Steam captures, and 13 images that must not be flagged
(camera photos, a photo of a screen, a wallpaper, a story graphic, an
exported slide, a screen recording, a boarding pass taken an hour ago…).

```bash
dart run tool/make_screenshot_test_area.dart
```

**2. Scan it.** Checks every image's rule and kind of screen, and exits 1
on any miss. It should end with `Deep scan: 40/40 expectations met
(screenshots 21/21, empty/unreadable 6/6, not flagged 13/13)`.

```bash
dart run deep_scans:screenshot_scan test_area/screenshot_detection --grant-access
```

Try `--ui-share 0.4`, `--blank-share 0.97` or `--recent-days 0` to see how
the thresholds move results.

## Large & old videos

Nine rules: four for videos that are broken in ways only their index shows
(V01 empty, V02 cut off, V03 damaged tables, V04 interrupted recording) and
five for videos worth reviewing to get space back (V10 old and large, V11
huge, V12 oversized for its length, with an estimated re-encode saving,
V13 large, V14 old). Only MP4/MOV, Matroska/WebM and AVI headers and
indexes are read, never the picture data. When a video was recorded comes
from its container, then its name (OBS, Game Bar, ShadowPlay, Fraps,
phone cameras, screen recorders, WhatsApp, Telegram…), then the file date.
Videos recorded in the last two weeks, used by an editing project changed
in the last 60 days, Live Photo movies and apps' own videos are held back.
The empty & unreadable checks run alongside, and video files they flag are
reported under their E/U rules. Findings are ranked largest first and
grouped into batches; only the ones that can't be played are pre-selected.
There is no mass-scan equivalent yet, so there's no `--compare`.

**1. Build the test area.** Writes `test_area/large_old_videos/`
(git-ignored): Timmy's game and desktop recordings, including the one that
ran out of storage, an editing project in progress and an abandoned one;
phone, chat and screen-recording videos from the other personas; broken
videos of every kind; and look-alikes that must not be flagged. Files are
built at 1/1024 of real size (1 MB on disk stands for 1 GB, ~41 MB in all),
and the scan scales its thresholds to match.

```bash
dart run tool/make_large_old_video_test_area.dart
```

**2. Scan it.** Checks every video's rule, source and notes, and exits 1 on
any miss or any finding the area doesn't list. It should end with
`Deep scan: 46/46 expectations met (broken 11/11, large & old 24/24, not
flagged 11/11); 0 unexpected`.

```bash
dart run deep_scans:large_old_video_scan test_area/large_old_videos --grant-access
```

Try `--old-days 180`, `--large-mb 250`, `--oversized-bpp 0.6` or
`--recent-days 0` to see how the thresholds move results, `--top 30` to
list more of the ranking, and `--size-scale 1` on real folders (the
default outside a test area).

## Experiment options (all scans)

| Option | Does |
|---|---|
| `--evidence` | Show what each rule saw (offsets and checksums; pHash distance and correlations; content keys, shingle similarity, worst page tile; edge widths by direction and retake detail agreement). |
| `--disable E03` / `--disable D06` / `--disable F04` / `--disable B04` / `--disable S04` / `--disable V12` | Switch a rule off (repeatable) to see its effect. |
| `--min-confidence certain` | Hide `likely` findings. |
| `--grace-minutes 0` | Empty & unreadable, duplicate documents, screenshots and large & old videos: don't hold back findings for just-modified files. |
| `--json` | Full result, including `stats` (bytes read, timing) and `countsByRule`. |

## Using them in code

```dart
final empties = await EmptyUnreadableScan(device: device).run();
final duplicates = await DuplicatePhotoScan(device: device).run();
final documents = await DuplicateDocumentScan(device: device).run();
final blurry = await BlurryPhotoScan(device: device).run();
// blurry.analysis.ranking: every measured photo, blurriest first.
final screenshots = await ScreenshotScan(device: device).run();
// screenshots.analysis.batches: groups for bulk review.
final videos = await LargeOldVideoScan(device: device).run();
// videos.analysis.ranking: flagged videos, largest first.

// Or drop them into the mass scan in place of the existing detectors:
final engine = ScanEngine(device: device, detectors: [
  ...EmptyUnreadableAnalyzer().detectors(),
  DuplicatePhotoAnalyzer().detector(),
  const BlankPhotoDetector(),
  const UnusedAppDetector(),
]);
```

## Layout

```
lib/src/shared/             Confidence, shared by every deep scan
lib/src/empty_unreadable/
  rules.dart                rule ids (DeepRule), tuning knobs
  analyzer.dart             the rule pipeline + WasteDetector adapters
  formats.dart              per-format signature and structure checks
  text_checks.dart          blank / garbled / structurally empty text
  file_probe.dart           cached head/tail/whole-file reads, read stats
  scan.dart                 runner, results, verification
lib/src/duplicate_photos/
  rules.dart                rule ids (DuplicateRule), tuning knobs
  fingerprint.dart          256 px decode → pHash (all rotations), borders, sharpness
  matcher.dart              pair comparison + banded pHash candidate index
  analyzer.dart             pipeline: identical files, decode, match, group, keeper
  model.dart                groups, members, observations
  scan.dart                 runner, results, verification
lib/src/duplicate_documents/
  rules.dart                rule ids (DocumentRule), tuning knobs
  content.dart              PDF / office / text reading → content key, words, scan pages
  similarity.dart           shingles, MinHash candidates, name stems, reference numbers
  page_match.dart           scanned-page alignment and tile detail test
  analyzer.dart             pipeline: exclusions, identical files, match, group, keeper, failed downloads
  model.dart                groups, members, observations
  scan.dart                 runner (with the empty & unreadable checks), results, verification
lib/src/blurry_photos/
  rules.dart                rule ids (BlurRule), tuning knobs
  measure.dart              edge widths per tile and direction → blur width, motion
  retake.dart               fine-detail check that a sharper shot is the same scene
  analyzer.dart             pipeline: E/U exclusions, decode, measure, retakes, rules, ranking
  model.dart                verdicts, retakes, ranking, observations
  scan.dart                 runner (with the empty & unreadable checks), results, verification
lib/src/screenshots/
  rules.dart                rule ids (ScreenshotRule), tuning knobs
  names.dart                capture tools' file-name patterns → tool, app, time taken
  metadata.dart             Exif / XMP / PNG text → camera data, tool marks; header image size
  measure.dart              sampled pixels → dominant colour, bar bands, status bar
  analyzer.dart             pipeline: E/U exclusions, path signals, header filter, decode, rules, batches
  model.dart                verdicts, batches, observations
  scan.dart                 runner (with the empty & unreadable checks), results, verification
lib/src/large_old_videos/
  rules.dart                rule ids (VideoRule), tuning knobs, scaledDown for test areas
  names.dart                recorders' and cameras' file-name patterns → source, tool, game, date recorded
  container.dart            MP4/MOV, Matroska/WebM and AVI headers and indexes → duration, size, codec, V01–V04
  analyzer.dart             pipeline: E/U exclusions, app folders, projects, containers, dates, rules, holds, ranking, batches
  model.dart                verdicts, batches, observations
  scan.dart                 runner (with the empty & unreadable checks), results, verification
lib/src/testing/            test-area builders + photo_factory, blur_factory, document_factory, screenshot_factory, video_factory (package:deep_scans/testing.dart)
bin/                        one CLI per deep scan
tool/                       one test-area generator per deep scan
docs/                       one ruleset per deep scan
```

To add another deep scan, add a sibling folder under `lib/src/`, a ruleset
in `docs/`, a test-area builder, a generator in `tool/` and a CLI in `bin/`,
following these six.
