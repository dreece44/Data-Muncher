# Large & Old Videos — Deep Scan Ruleset

| | |
|---|---|
| **Jira** | DAT-24 (PB-09 *Large and old video file detection*), epic DAT-8 *Scanning & Detection* |
| **Related** | DAT-20 (empty & unreadable, run alongside), DAT-23 (screenshots, which notes screen recordings as X04 and leaves them to this scan) |
| **Ruleset version** | `1.0` (`largeOldVideoRulesetVersion` in `lib/src/large_old_videos/scan.dart`) |
| **Code** | `packages/deep_scans/lib/src/large_old_videos/` |
| **Test area** | `dart run tool/make_large_old_video_test_area.dart` → `test_area/large_old_videos/` (§11) |
| **CLI** | `dart run deep_scans:large_old_video_scan <folder> --grant-access` |
| **Status** | Standalone. The mass scan (`scan_engine`) is unchanged and has no video category. |

This is the reference for every rule the large & old video deep scan
applies, written for the later pass that tunes each scan for performance
and accuracy.

## 1. Where the requirements come from

- **DAT-24:** "As a content creator, I want old and oversized video files
  surfaced so that I can reclaim large amounts of space quickly." → every
  finding carries its size; results are **ranked largest first** and
  grouped into **batches** for review (§4).
- **Timmy (scenario):** he "did not have enough storage to save the full
  recording", and the scan finds "older video files" he deletes. → old
  gameplay/desktop recordings (OBS, Game Bar, ShadowPlay, Fraps) are the
  main target; a recording that failed to save is reported (V02/V04 or the
  E/U rules); the video he *just* recorded is never suggested (X01); the
  footage of a montage he's editing is protected (X02).
- **Timmy (persona):** "very capable with technology", records daily,
  uses editing software. → V12 suggests *re-encoding* oversized capture
  files (ProRes, lossless, high-bitrate) instead of deleting them.
- **Gerald, Alexa, Jasmine, Ethan:** phone camera clips, chat videos and
  downloads count too; phone bitrates must never look "oversized".
- **Feature list, Garbage Collection:** findings go to the bin, so only
  provably broken videos are pre-selected; size/age findings are for
  review.

## 2. What counts

A **video** is a file with an extension in `videoExtensions` (mp4, m4v,
mov, 3gp, 3g2, mkv, webm, avi, wmv, flv, mts, m2ts, ts, mpg, mpeg, vob),
or a partial download of one (`clip.mp4.crdownload`). MP4/MOV/3GP,
Matroska/WebM and AVI are opened and checked; the rest are judged by size
and date only (X07).

**Broken videos:** files the empty & unreadable scan flags (E01 0-byte, U03
unfinished download, U04 zero-filled, U06 no index / cut off, E05 no
media…) are reported under those codes; this scan adds checks that scan
can't make, by reading the container's index (V01–V04).

**Large / old videos:** not waste by themselves — candidates for review.

## 3. How the scan works

```
storage items ──► empty & unreadable checks ──► video files they flag → reported under E/U codes
      ▼ video files (by extension, partial-download suffix removed)
  in Android/data or Android/obb? → X05, not judged
  readable? parsed container? → read header/index (§6); else X09 / X07
      ▼ recorded date: container creation time → name date → file date (X08, X10)
  container problem (V01–V04)? modified within E/U grace (10 min) → X03, not judged
      ▼ candidates in precedence order; first enabled, confident-enough one wins
  V10–V14 only: Live Photo movie (X04), active editing project (X02), recent (X01) → held back
      ▼ verdicts, ranking (largest first), batches
```

Code: `analyzer.dart` (pipeline, holds, batches), `container.dart` (MP4,
Matroska, AVI parsers → `VideoInfo` + `VideoProblem`), `names.dart`
(recorder/camera name patterns, source), `rules.dart` (rule ids, knobs),
`model.dart` (verdicts, batches, observations), `scan.dart` (runner,
output, test-area verification).

Runs through `ScanEngine`, so the storage permission gate applies exactly as
in the mass scan.

### Confidence

Per verdict, at most the rule's own level. Here it means **how sure the
scan is of the facts the rule rests on**, not whether the user wants the
video:

- **certain:** size is a fact; age from the container or the file name;
  frame rate read from the container; a structural break that players
  can't get past (V01, V02).
- **likely:** age from the file date only (copying resets it); frame rate
  assumed (V12); V03 damaged tables; V04 interrupted (still plays).

A candidate below `minConfidence` **falls through** to the next rule (an
"old & large" with an uncertain age can still be "large").

## 4. Rules at a glance

| Code | Name | Confidence | Fires when | Pre-selected |
|---|---|---|---|---|
| V01 | Empty video | certain | complete container, nothing to play: every MP4 track has 0 samples; Matroska with no Cluster; AVI with an empty `movi` | yes |
| V02 | Cut-off video | certain | index points past the data: MP4 chunk offset ≥ file size, or frames listed > `mdat` data by > `cutOffTolerance` (1%); Matroska Segment ends past EOF; AVI `movi` runs past EOF; MP4 with no `moov` (when E/U held it back) | yes |
| V03 | Damaged video | likely | MP4 `stsz` and `stts` sample counts differ, samples without a chunk table, broken box nesting; Matroska element overrunning its finished segment; AVI frames but no `movi` | no |
| V04 | Interrupted recording | likely | Matroska segment size unknown (recorder stopped before finalising); reason says whether the last cluster is cut off | no |
| V10 | Old and large | certain/likely | recorded ≥ `oldAge` (365 d) ago **and** ≥ `largeBytes` (500 MB) | no |
| V11 | Huge | certain | ≥ `hugeBytes` (2 GB), any age | no |
| V12 | Oversized for its length | certain/likely | ≥ `oversizedMinBytes` (200 MB), bits/pixel/frame ≥ `oversizedBitsPerPixel` (1.0) **or** an editing/capture codec, and re-encoding at `reencodeBitsPerPixel` (0.1) saves ≥ `minSavingShare` (50%) | no |
| V13 | Large | certain | ≥ `largeBytes` | no |
| V14 | Old | certain/likely | recorded ≥ `oldAge` ago and ≥ `oldMinBytes` (100 MB) | no |
| E/U | Empty or unreadable video | per DAT-20 | the empty & unreadable scan flags a video file | yes |

Every verdict records `alsoMatched` (lower rules that matched — an old &
large ProRes file shows V12 and its estimated saving) and its `source`.

**Batches** (`analysis.batches`), items largest first, with counts by
source: *Videos that can't be played* (E/U + V01/V02, pre-selected),
*Damaged & interrupted recordings* (V03/V04), *Old & large*, *Huge*,
*Recordings that could be compressed* (with the total estimated saving),
*Large*, *Old*. **Ranking** (`analysis.ranking`): V10–V14 by size.

## 5. Signals

### Recorded date

1. Container creation time (MP4 `mvhd`, seconds since 1904; Matroska
   `DateUTC`) if after 1995 and not in the future; otherwise ignored and
   noted (X10: a GoPro or camera whose clock was never set).
2. A date in the file name (patterns below).
3. The file's last-modified date (confidence drops to likely).

When 1 or 2 is used and the file date is more than `dateDisagreement`
(30 d) away, X08 is noted: a 2023 clip copied to a new PC yesterday is
still old.

### Source and name patterns (`names.dart`)

| Source | Tool | Example |
|---|---|---|
| camera | Android, Pixel, Samsung (Camera folder only), iPhone, GoPro, DJI, Sony/Canon/Nikon/Panasonic | `VID_20240706_181203.mp4`, `PXL_…`, `20260910_101500.mp4`, `IMG_0219.MOV`, `GX010042.MP4`, `DJI_0042.MP4`, `C0001.MP4` |
| screenRecording | Samsung, Pixel, Xiaomi, iPhone (Unix time), macOS, Windows | `Screen_Recording_20250412-201011_Instagram.mp4`, `RPReplay_Final1712345678.mp4`, `Screen Recording 2025-04-12 at 8.10.11 PM.mov` |
| gameplay | ShadowPlay, Fraps, AMD ReLive, Bandicam, OBS, Xbox Game Bar (Captures folder only) | `Game 2025.06.01 - 19.22.40.02.DVR.mp4`, `Minecraft 2025-02-10 20-15-33-12.avi`, `2024-03-14 16-02-11.mkv` |
| messaging | WhatsApp, Telegram | `VID-20240203-WA0007.mp4`, `video_2025-05-20_22-14-09.mp4` |
| download | (folder) | anything under Download/Downloads |

With no name match, the nearest telling folder decides (`videoSourceFolders`).

### Bitrate (V12)

`bpp = size × 8 / (width × height × fps × seconds)`. Reference points
(published bitrates for common settings, not measured on real files):

| Recording | Bitrate | bits/pixel/frame |
|---|---|---|
| iPhone 4K60 HEVC | ~53 Mbit/s | 0.11 |
| Android 4K30 H.264 | ~48 Mbit/s | 0.19 |
| Android 1080p30 H.264 | ~17 Mbit/s | 0.27 |
| Phone 720p30 | ~10 Mbit/s | 0.36 |
| NVIDIA ShadowPlay 1080p60 (high) | ~50 Mbit/s | 0.40 |
| GoPro 1080p30 (high bitrate) | ~40–60 Mbit/s | 0.65–0.96 |
| OBS CQP ≈ 16 at 1080p60 | 100+ Mbit/s | 0.8–1.2 |
| ProRes 422 LT 1080p30 | ~102 Mbit/s | 1.64 |
| Motion JPEG 1080p30 | ~100 Mbit/s | 1.6 |
| ProRes 422 1080p30 | ~147 Mbit/s | 2.4 |
| Lossless (Ut Video, FFV1, Fraps) | — | 5–20 |

**The threshold is 1.0, not the 0.6 first tried.** At 0.6 the test
area's GoPro 1080p30 clip (0.67) was flagged: action cameras record
1080p at high bitrates on purpose, and those are camera originals, not
bloated captures. 1.0 leaves every phone, ShadowPlay and GoPro setting in
the table alone and still catches lossless and very-high-quality OBS
recordings. Editing codecs are caught by name whatever the bitrate.
Intermediate
codecs (`intermediateCodecs`: ProRes, DNxHD, MJPEG, Ut Video, FFV1,
Lagarith, HuffYUV, Fraps, CineForm, uncompressed) qualify regardless of
bpp. Estimated saving = size − `reencodeBitsPerPixel` × pixels × fps ×
seconds / 8.

## 6. Exclusions, holds and observations

| Code | Kind | Effect |
|---|---|---|
| X01 | `recent` | recorded within `recentWindow` (14 d): V10–V14 held back |
| X02 | `activeProject` | an editing project (`projectExtensions`: prproj, veg, kdenlive, mlt, drp, aep, fcpxml, wfp, tscproj, osp…) changed within `activeProjectWindow` (60 d) uses it: V10–V14 held back. Projects ≤ `projectMaxBytes` are read (gzip unwrapped) and searched for the video's file name as UTF-8 and UTF-16; ZIP-based, larger or unreadable projects cover every video in their folder and below. Older projects don't protect; they're mentioned in the evidence |
| X03 | `stillWriting` | V01–V04 found, but modified within the E/U grace period (10 min): may still be recording |
| X04 | `livePhoto` | a `.mov` with a same-named HEIC/JPEG in its folder: V10–V14 held back (noted only when a rule would have fired) |
| X05 | `appData` | under `android/data` or `android/obb`: not judged at all |
| X06 | `indexNotRead` | MP4/MOV index over `maxIndexBytes` (64 MB) |
| X07 | `notParsed` | WMV, MTS, MPG… or not a known container inside: size/date only |
| X08 | `datesDisagree` | see §5 |
| X09 | `contentNotRead` | iOS photo library: size/date only |
| X10 | `badMetadataDate` | container date ignored |
| — | `unreadable`, `suppressed` | read failed; rule disabled or below `minConfidence` |

Health rules (V01–V04) are never held back by X01/X02/X04: a broken file
is waste even if new.

## 7. What is read (performance)

| Container | Reads |
|---|---|
| MP4/MOV/3GP | 16 bytes per top-level box (usually 3–5), then the whole `moov` (KB–few MB). Picture data is never read. |
| Matroska/WebM | `headBytes` (64 KB) head; then 12 bytes per segment child. Finished files stop at the first Cluster; unfinished ones (unknown size) are walked to the end (one small read per cluster, capped by `maxElements`). |
| AVI | head + `hdrl` list; 12 bytes per top-level chunk. |
| Projects | whole file, ≤ 32 MB, once per scan. |

**Measured** on the test area (development laptop, 4 workers, three runs):
46 videos (41.4 MB on disk, standing for ~41 GB), 39 containers opened,
3 projects read; **3.1 MB read in total (7.5% of the bytes, mostly MP4
indexes and the projects), 65–69 ms** for this scan, plus the empty &
unreadable checks. Read volume grows with index size (recording length),
not file size, so on real storage the share read is far smaller: a
1.5 GB, 25-minute recording costs the same few hundred KB as its
1.5 MB stand-in.

**For the optimisation pass:**

- Unfinished MKV walks are the worst case (~1 read per cluster, about
  one per 5 s of recording); a sequential buffered reader would cut this.
- `moov` parsing sums every `stsz` entry; only totals are needed, and
  `stsz` with a fixed sample size already skips that.
- Each element header outside the 64 KB head is a separate `readRange`
  call (file open per call on `LocalDirectorySource`).
- Projects are read whole even when inactive; reading only active ones
  would lose only the "used by an old project" evidence.

**Bug found by the test area:** headers read past the 64 KB head had their
data offset taken relative to the 12-byte read instead of the file, so
every unfinished MKV longer than 64 KB came out V03 instead of V04. Fixed
in `container.dart` and pinned by the V04 unit test and test area.

## 8. Tuning knobs

All in `LargeOldVideoRules` (`rules.dart`).

| Knob | Default | Trade-off |
|---|---|---|
| `largeBytes` / `hugeBytes` | 500 MB / 2 GB | V10/V13 and V11. Lower surfaces more phone clips. |
| `oldMinBytes` | 100 MB | V14 floor; lower floods the list with old phone clips. |
| `oldAge` | 365 d | V10/V14. |
| `recentWindow` | 14 d | X01. |
| `activeProjectWindow` | 60 d | X02. |
| `oversizedBitsPerPixel` [`--oversized-bpp`] / `reencodeBitsPerPixel` / `minSavingShare` / `oversizedMinBytes` | 1.0 / 0.1 / 0.5 / 200 MB | V12 (§5). Below ~0.9 flags action-camera originals. |
| `assumedFrameRate` | 30 | V12 when the container has no rate. |
| `intermediateCodecs`, `projectExtensions`, `appDataFolders`, `namePatterns`, `videoExtensions` | §5–6 | Lists. |
| `cutOffTolerance` | 1% | V02 slack for muxer padding. |
| `dateDisagreement` | 30 d | X08. |
| `headBytes`, `maxIndexBytes`, `maxElements`, `projectMaxBytes` | 64 KB, 64 MB, 100 000, 32 MB | Read limits. |
| `sizeScale` / `scaledDown(n)` | 1 | Divides every size threshold **and** bits-per-pixel limit by n. Test areas are built at 1/1024 of real size (1 MB on disk stands for 1 GB) and record `sizeScale` in `expected.json`. |
| `concurrency`, `minConfidence`, `disabledRules` | 4, likely, none | As in the other scans; a disabled rule falls through. |

The E/U grace period (`EmptyUnreadableRules.recentlyModifiedGrace`) also
sets X03.

## 9. Known gaps

- **"Old" means recorded long ago, not unwatched.** Last-opened time isn't
  available from `StorageItem`; a favourite old clip is still surfaced.
- **Mid-file damage** in finished MKVs isn't found (walk stops at the first
  cluster), and MP4 sample data isn't decoded.
- **OpenDML AVI (> 1 GB, `AVIX` chunks):** only the first RIFF is read, so
  duration may be short and V12 may over-estimate bitrate.
- **Fragmented MP4** (OBS ≥ 30 default) has no single index: no duration,
  so V12 can't fire; interrupted fragments are left to E/U U06.
- **Unparsed formats** (WMV, MTS, MPG, FLV) get no structure checks.
- **Thresholds are calibrated on published bitrates and synthetic files.**
  The test videos have real container structure but noise for picture
  data. Drones (DJI 1080p at 100 Mbit/s ≈ 1.6 bits/pixel) will trip V12
  even though they're camera originals; a camera-source exception may be
  worth adding once real footage is tried. The first tuning step is a
  labelled set of real recordings from each tool in §5.
- **Test area dates are relative to when it's built.** Four answers change
  with time (`changesAt` in `expected.json`), and the area stays valid
  for those; other cases sit well clear of the 14-day and 365-day lines.
- **Duplicate videos** (same export twice) aren't detected; candidate for a
  separate rule or the duplicate-document scan.

## 10. Merging into the mass scan

1. Add `WasteCategory.largeVideo` (or `oldVideo`) to `scan_engine` and
   replace `videoCategoryStandIn` (currently `unusedApp`, used only in this
   standalone run).
2. Add `LargeOldVideoAnalyzer(health: sharedEmptyUnreadable).detector(...)`
   to the engine, sharing the E/U analyzer so files are checked once; E/U
   findings on videos are reported by the E/U detectors, so don't count
   them twice.
3. Review UI: show `ranking` and `batches`; pre-tick only the
   *can't be played* batch; offer "compress" rather than "delete" for V12.
4. iOS: pass PhotoKit's creation date and Live Photo pairing through the
   adapter instead of relying on names.

## 11. Test area and accuracy baseline

`dart run tool/make_large_old_video_test_area.dart` writes
`test_area/large_old_videos/` (git-ignored): 46 videos plus 3 editing
projects and a Live Photo still, at **1/1024 of real size** (~41 MB on
disk). Writing multi-GB files to test with isn't practical, so
`expected.json` records `"sizeScale": 1024` and the CLI and tests scan it
with `LargeOldVideoRules().scaledDown(1024)`: large 500 KB, huge 2 MB, and
so on. Bitrate limits scale too, so durations, resolutions and frame
rates are real. Sizes in the output are the on-disk ones.

Ruleset 1.0: **46/46 expectations met, 0 unexpected findings.**

| Group | Videos | Result |
|---|---|---|
| Broken: V01 ×3 (empty OBS MKV, phone clip with no frames, webcam AVI), V02 ×2 (download stopped at 40%, GoPro card copy with `mdat` to EOF), V03 (recovered clip, tables disagree), V04 (Timmy's recording when storage ran out), E01, U03, U04, U06 (Game Bar clip saved with no index) | 11 | 11/11 |
| Large & old: V10 ×9 (OBS, ShadowPlay, Fraps, Gerald's 4K clip, iPhone re-downloaded from iCloud, an old Premiere project's clip, webinar, MTS, WMV), V11 ×3 (stream recording, film, Jasmine's 4K footage), V12 ×2 (ProRes LT, Ut Video), V13 ×4 (Game Bar clip, unused project footage, Alexa's clip, an 11-month clip), V14 ×6 (school clip copied later, unset-clock GoPro, WhatsApp, Telegram, Samsung and iPhone screen recordings) | 24 | 24/24, plus X07/X08/X10 notes where expected |
| Not flagged: yesterday's recording and the export being uploaded (X01), footage of an active Kdenlive project and next to an active Resolve project (X02), a recording still being written (X03), a game's cut-scene (X05), a Live Photo movie, small old clips, a one-minute and a short recent phone clip | 11 | 11/11 |

Four expectations change with time (`changesAt`): after 10 minutes the
still-recording MKV is judged V04; after 14 days the two recent videos
become V11 and V13; after 25 days the 11-month clip becomes V10.
`test/large_old_video_test_area_test.dart` checks the area now and at
+11 min, +15 d and +26 d.

`test/large_old_video_rules_test.dart` (30 tests) pins every name pattern
(Unix time, 12-hour clock, folder-only patterns), each container's facts
and V01–V04, rules and precedence with `alsoMatched`, V12 savings and the
phone/ProRes cases, the recorded-date order and confidence, X10, min
confidence and disabled-rule fall-through, every hold (recent, active
text/gzip/ZIP projects, inactive projects, Live Photo, app data, still
writing), size-only judging (MTS, iOS library), E/U reporting with source,
unreadable files, ranking and batches, `scaledDown`, the permission gate
and use as a `ScanEngine` detector.

## 12. Changelog

- **1.0** (2026-11-01): first version. V01–V04, V10–V14, X01–X10; empty &
  unreadable video files via DAT-20; ranking and batches; V12 threshold
  raised from 0.6 to 1.0 bits/pixel after the GoPro case (§5); test area
  with 46 planted videos.
