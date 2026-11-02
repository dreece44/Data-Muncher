# Screenshots — Deep Scan Ruleset

| | |
|---|---|
| **Jira** | DAT-23 (PB-08 *Screenshot detection*), epic DAT-8 *Scanning & Detection* |
| **Related** | DAT-20 (empty & unreadable, run alongside), DAT-21 (duplicate photos, which already never pairs screenshots as "shots"), DAT-22 (blurry photos, which leaves screenshots out) |
| **Ruleset version** | `1.0` (`screenshotRulesetVersion` in `lib/src/screenshots/scan.dart`) |
| **Code** | `packages/deep_scans/lib/src/screenshots/` |
| **Test area** | `dart run tool/make_screenshot_test_area.dart` → `test_area/screenshot_detection/` |
| **Status** | Standalone. The mass scan (`scan_engine`) is unchanged and has no screenshot detector or category yet. |

This is the reference for every rule the screenshot deep scan applies,
written for the later pass that tunes each scan for performance and
accuracy. Each rule lists its signals, thresholds and the measurements
behind them, what it can get wrong, and which knob controls it.

## 1. Where the requirements come from

- **DAT-23:** "Identify screenshots as a distinct waste category so they
  can be reviewed and cleared in bulk." → every screenshot is its own
  finding with a rule and confidence, and the result also groups them into
  **batches** (§4) the review UI can show and clear at once.
- **Alexa:** the scan finds "screenshots she never got around to
  deleting". → a phone camera roll mixing screenshots (Instagram posts,
  recipes, chats, maps) with camera photos that must not be touched. She is
  "not the most tech-savvy", so findings must be safe to clear in bulk:
  precision over recall.
- **Timmy:** "most of his storage is taken up by screenshots of his
  computer he used for school projects" and he "decides to delete all the
  screenshots". → computer screenshots (Windows, macOS, Linux, Game Bar,
  Steam) count, and the scan must tell them from computer files that only
  look like screens (exported slides, diagrams). He records gameplay, so
  game captures are screenshots and game *clips* are screen recordings,
  which belong to the old-video scan.
- **Ethan:** "several empty files from failed downloads" and a phone that
  is always full. → the empty & unreadable checks run alongside: a
  screenshot that saved as 0 bytes because storage was full, or a shared
  screenshot that never finished downloading, is reported under that
  scan's rules (§5, E/U).
- **Feature list, Garbage Collection:** results go to the bin, so a false
  positive costs a user a real photo. Wherever a threshold has to choose,
  this scan leaves a camera photo alone.

## 2. What counts

A **screenshot** is an image the device's screen-capture tool produced: a
picture of a screen, not of the world. Two extra kinds are called out
because nothing on them is worth keeping, so the UI can pre-select them:

- **Blank** (S05): the whole capture is one colour. Phones save a black
  frame when the app on screen blocks capture (Netflix, banking apps); a
  capture during a redraw comes out white.
- **Empty screen** (S06): only the system bars (status bar, taskbar) have
  anything on them; the app area is one colour. A page that hadn't loaded,
  a full-screen video that blocks capture on a computer.

Mostly-blank screenshots that hold one line (a Wi-Fi password, a booking
code) are *not* empty: the line is the point (§7).

**Empty and unreadable screenshot files** (0-byte, cut off, damaged,
zero-filled, still downloading) can't be opened at all. They come from the
empty & unreadable deep scan (DAT-20, `EMPTY_UNREADABLE_RULESET.md`), which
runs in the same engine; when the file's **name or folder** says
screenshot, the finding is listed here under that scan's rule code. Broken
images that aren't screenshots are left to that scan's own report.

**Not screenshots:** camera photos (even of a screen, even moved into the
Screenshots folder), wallpapers and other pictures at screen size,
exported slides, diagrams and story graphics, scanned documents. Screen
*recordings* are videos: noted (X04), not flagged.

## 3. How the scan works

```
storage items ──► empty & unreadable checks ──► image files they flag:
      │                                          name/folder says screenshot? → reported as E/U
      │                                          otherwise left to that scan
      ▼ image files (png, jpg, jpeg, webp, heic, heif, bmp); videos → X04 if a screen recording
  path signals: S01 tool name pattern, S03 screenshots folder / loose name
      │  contents not readable (iOS photo library) → judged by path only (X05)
      ▼ read headBytes (256 KB): metadata + image size
  S02 tool mark?   camera exposure data? → X01 if any signal, else skip
  no signal and not a portrait screen shape? → skip (never decoded)
      │  HEIC / too large → judged without pixels (X06)
      ▼ decode on a background isolate, sample ≤ maxSamples pixels without resizing (§6)
  no signal: S04 if status bar + app background; X03 if flat and phone-shaped without a bar
      │
      ▼ S05 → S06 → S01 → S02 → S03 → S04 (first enabled match wins)
  X02 recent? (not for S05/S06) → held back
      │
      ▼ verdicts + batches for bulk review
```

Code: `analyzer.dart` (pipeline), `names.dart` (tool name patterns),
`metadata.dart` (Exif / XMP / PNG text / header size), `measure.dart`
(pixel measurement), `rules.dart` (rule ids and knobs), `model.dart`
(verdicts, batches, observations), `scan.dart` (runner, output,
verification).

The scan runs through `ScanEngine`, so the storage permission gate applies
exactly as in the mass scan: without access it throws
`PermissionDeniedException` and reads nothing (the CLI exits 2).

### Confidence

Shared with the other deep scans (`lib/src/shared/confidence.dart`). Here
it is **how sure the scan is that the image is a screenshot** (or, for
S05/S06, a blank one), not whether the user wants it:

- **certain**: the capture tool said so (its file name, its metadata mark)
  and no camera data contradicts it; or the screenshot is blank.
- **likely**: the folder, a loose name, or the pixels alone say so. Shown,
  worth a second look when tuning. `--min-confidence certain` hides these.

### Observations

Images left out, or near-misses, are recorded with a reason so tuning can
see them (`ScreenshotObservationKind`):

| Kind | Code | Meaning |
|---|---|---|
| `cameraPhoto` | X01 | Named or filed as a screenshot, but has camera exposure data: a photo. |
| `recent` | X02 | Taken within `recentWindow` (2 days); probably still in use. |
| `possibleScreenshot` | X03 | No signal; phone-shaped, flat (≥ `graphicFlatShare`) with an app-like background, but no status bar: an exported graphic, or a screenshot without one. |
| `screenRecording` | X04 | A video named like a screen recording or Game Bar clip. |
| `contentNotRead` | X05 | Contents can't be read on this device (iOS photo library); judged by name and folder only. |
| `notDecoded` | X06 | HEIC (no pure-Dart decoder) or over `maxImageBytes`; flagged by its signals, not checked for blank content. |
| `undecodable` | | Format supported, file won't decode, yet the empty & unreadable checks passed it. Should not happen; worth a look. |
| `unreadable` | | Read failed (permissions, file vanished). |
| `suppressed` | | A rule matched but was disabled or below `minConfidence`. |

## 4. Rules at a glance

Precedence is top to bottom; an image gets at most one rule. Every
verdict also records `identifiedBy` (the strongest of S01–S04 that
applies) and all `signals` found, so S05/S06 still say how the image was
recognised.

| Code | Name | Confidence | Fires when | Finding |
|---|---|---|---|---|
| S05 | Blank screenshot | certain | identified by S01–S03, and ≥ `blankShare` (99.7%) of the frame is one colour | image (pre-selected) |
| S06 | Empty screen | certain | identified by S01–S03, and ≥ `blankShare` of the frame *minus the bar bands* is one colour | image (pre-selected) |
| S01 | System screenshot | certain | name matches a capture tool's pattern (§5) | image |
| S02 | Marked by the tool | certain | metadata mark: XMP/Exif UserComment "Screenshot", or Software / CreatorTool / PNG text naming a capture tool | image |
| S03 | Filed as a screenshot | likely | in a screenshots folder (nearest 3 folders), or the name loosely says screenshot | image |
| S04 | Looks like a screenshot | likely | no other signal; portrait ≥ 1.3:1, status bar found, one background colour covers ≥ `uiDominantShare` (25%), no camera data | image |
| E/U | Empty or unreadable screenshot | per DAT-20 | the empty & unreadable deep scan flags an image file whose name or folder gives S01/S03 | image (pre-selected) |

**Over every rule:** camera exposure data (ExposureTime, FNumber, ISO or
FocalLength in Exif) means it isn't a screenshot (X01). S01–S04 findings
taken within `recentWindow` are held back (X02); S05/S06 aren't, since a
blank capture is never needed.

**Batches** (`ScreenshotAnalysis.batches`), in order: *Blank & empty
screenshots* (S05/S06, pre-selected), *Screenshots that can't be opened*
(E/U, pre-selected), then one per kind of screen (*Phone*, *Tablet*,
*Computer*, *Other* for crops). Each carries its count, bytes, how many
are older than `oldAge` (30 days) and a count by app where the file name
names one (`Screenshot_…_Instagram.jpg`, Game Bar's game name).

**Kind of screen:** from the tool when the name says (Android → phone;
macOS, Windows, GNOME, Game Bar → computer), else the shape: landscape →
computer; portrait ≥ `phoneAspect` (1.7) → phone, shorter → tablet;
under 1.2:1 → *unknown* (a crop).

## 5. Rules in detail

### S05 — Blank screenshot

- **Signal:** the image is a screenshot by S01, S02 or S03, and its
  dominant colour (§6) covers ≥ `blankShare` of the sampled frame.
- **Catches:** black frames from apps that block capture
  (`Screenshot_…_Netflix.jpg`), white captures during a redraw. The reason
  names the colour and the likely cause.
- **Why it needs another signal:** a plain image with no screenshot name,
  mark or folder is a blank *photo* (lens cap, pocket shot) or a solid
  wallpaper, and belongs to the blank-photo scan. S04 can't identify a
  blank frame either (it needs a status bar and `dominantShare <
  blankShare`).
- **Can go wrong:** a deliberate capture of a plain colour (a colour
  swatch). Rare enough for `certain`.
- **Knob:** `blankShare` (`--blank-share`), `colorTolerance`.

### S06 — Empty screen

- **Signal:** identified by S01–S03, and the dominant colour covers ≥
  `blankShare` of the *content area*: the frame minus the top
  `topBarShare` (4.5%) and bottom `bottomBarShare` (5%). Those bands hold
  the phone status and gesture bars, the macOS menu bar and the Windows
  taskbar.
- **Catches:** a white page with only the status bar; a black full-screen
  video with only the taskbar (`Screenshot (13).png`).
- **Doesn't catch (on purpose):** one line of text on an empty note
  (content 98.1% one colour, §7). That screenshot is the user's Wi-Fi
  password; it stays S01.
- **Can go wrong:** a loading spinner under ~60×60 px on a 1080×2340
  screen (0.3% of the content) is under the threshold, so that capture
  counts as empty. That is the intent. A screen whose only content sits in
  the bar bands (a full-width toolbar at the very bottom) would also count.
- **Knobs:** `blankShare`, `topBarShare`, `bottomBarShare`.

### S01 — System screenshot (named by the capture tool)

- **Signal:** the file name, minus its extension (and any partial-download
  extension), matches one of `namePatterns` (`names.dart`), ignoring case:

  | Tool | Example |
  |---|---|
  | Android (AOSP, Samsung with app, Xiaomi with package, KDE) | `Screenshot_20260913-201500_Instagram.jpg`, `Screenshot_2026-09-13-20-15-00-123_com.whatsapp.jpg`, `Screenshot_20260913_201500.png` |
  | macOS (old and new, AM/PM with a normal or narrow no-break space, "(2)") | `Screen Shot 2019-03-04 at 4.15.10 PM.png`, `Screenshot 2026-09-29 at 10.02.11 AM.png` |
  | Windows Snipping Tool | `Screenshot 2026-10-06 154500.png` |
  | Windows Win+PrtScn | `Screenshot (12).png` |
  | GNOME | `Screenshot from 2026-10-10 09-30-00.png` |
  | Xbox Game Bar, **only in a `Captures` folder** | `Starfall Odyssey 2026-10-08 21-14-03.png` |
  | Localised (es, pt, fr, de, nl, it, pl, cs, ja, zh, ko) | `Bildschirmfoto 2026-10-10 um 09.30.00.png` |

  The match also gives the **app** (Samsung/Xiaomi suffix, Game Bar game
  name) and the **time taken** (used for X02 and the age counts instead of
  last-modified, which copies change).
- **Can go wrong:** a camera photo renamed to a screenshot name. Camera
  exposure data overrides it (X01). A downloaded image someone named
  `Screenshot_2026…` is still a screenshot as far as anyone can tell.
- **Knob:** `namePatterns`.

### S02 — Marked by the capture tool

- **Signal:** the file's own metadata (`metadata.dart`), read from the
  first `headBytes`:
  - XMP `exif:UserComment` "Screenshot" (iOS and macOS write it into every
    screenshot), or Exif UserComment (tag 0x9286) containing "Screenshot";
  - XMP `xmp:CreatorTool`, Exif Software (0x0131), or a PNG `tEXt`/`zTXt`/
    `iTXt` Software / Description / Comment / Title / Source entry
    containing one of `toolWords` (gnome-screenshot, Spectacle, ShareX,
    Greenshot, Snipping Tool, Flameshot, Lightshot, CleanShot, Snagit…).
- **Catches:** iPhone screenshots exported or AirDropped as `IMG_4821.PNG`
  (iOS gives them photo names); renamed captures from desktop tools
  (`history_notes.png`, Software "ShareX").
- **Can go wrong:** an editor that copies a screenshot's metadata into an
  edited image, which is then still mostly a screenshot. A tool word inside
  an unrelated Description (a photo captioned "screenshot of the view").
  Neither seen in testing.
- **Knob:** `toolWords`, `headBytes`.

### S03 — Filed as a screenshot

- **Signal:** one of the nearest three folders above the file is in
  `screenshotFolders` (screenshots, screenshot, screen shots, screen
  captures, screencaps, screencapture), or the name loosely says
  screenshot (`looseScreenshotWords`: "screen shot", "screencap",
  "scrnshot", "capture 3"…) without matching a tool pattern.
- **Catches:** crops and edits saved back to the Screenshots folder
  (`crop_bakery_hours.png`), Steam's `…/screenshots/20261009213000_1.jpg`,
  Lightshot's `Screenshot_1.png`.
- **Why only the nearest three folders:** item paths are absolute, so a
  folder named "Screenshots" far above the storage root would otherwise
  make everything a screenshot. (For the same reason the test area lives in
  `test_area/screenshot_detection`, not `…/screenshots`.)
- **Can go wrong:** a user who keeps other pictures in a folder they named
  Screenshots. Camera photos there are protected by X01; downloaded
  pictures without camera data aren't. Hence `likely`.
- **Knobs:** `screenshotFolders`.

### S04 — Looks like a screenshot

- **Signal (all of):** no S01–S03 signal; no camera data; portrait with
  height ≥ `minPortraitAspect` (1.3) × width; a phone **status bar** found
  (§6); and one background colour covering ≥ `uiDominantShare` (25%) but
  less than `blankShare` of the frame.
- **Catches:** screenshots that lost everything but their pixels: received
  over WhatsApp (renamed `IMG-20261003-WA0011.jpg`, shrunk to 720 px,
  re-compressed at q70, metadata stripped).
- **Why both tests:** each alone is fooled. The status-bar test fires on
  ~5% of portrait camera pictures (a dark object at one top corner, sky at
  the other) and the background test on flat designed graphics. Together:
  0 of 80 camera pictures (§7).
- **Doesn't catch (on purpose):** landscape images with no other signal.
  A 1920×1080 exported slide or diagram has flat colours at a screen size
  and no status bar to tell it apart, so landscape images without a
  signal aren't even decoded. Computer screenshots nearly always keep
  their tool name or folder (S01/S03). See §9.
- **Can go wrong:** a designed graphic with a fake status bar (a phone
  mock-up in a marketing image); a chat app's "photo" that is mostly one
  colour and has two small dark marks top-left and top-right.
- **Knobs:** `uiDominantShare` (`--ui-share`), `minPortraitAspect`,
  `markContrast`, `topBarShare`.

### Empty and unreadable screenshots (E/U rules)

The empty & unreadable deep scan runs in the same engine and shares its
analyzer, so each file is read once for those checks. Every verdict on an
image file (or a partial download of one, `Screenshot_1.png.part`) whose
name matches S01 or whose folder/name matches S03 is listed under that
rule, with the screenshot signal as evidence. Typical cases from the test
area: E01 0-byte (storage full while saving), U03 unfinished download, U04
zero-filled (a cloud placeholder that never synced), U06 cut off, U07 PNG
checksum fails, U08 picture data scrambled. Their rules, precedence and
grace period (files modified in the last 10 minutes aren't judged) are in
`EMPTY_UNREADABLE_RULESET.md`. Metadata (S02) can't be trusted in a broken
file, so it isn't used to claim these.

### Exclusions and protections

- **X01 camera photo:** Exif exposure tags present. Make/Model alone don't
  count (some apps copy them into saved images); only a camera records an
  exposure. Applies to every rule: a photo is never a screenshot.
- **X02 recent:** time taken (name, else last modified) within
  `recentWindow` (2 days) of the scan. The boarding pass captured this
  morning is still needed. `--recent-days 0` turns it off.
- **X03 possible screenshot:** recorded only; see the table in §3.
- **X04 screen recording:** a video whose name contains one of
  `screenRecordingWords` (Screen_Recording, Screen Recording,
  screenrecord…) or matches the Game Bar pattern in a Captures folder.
- **X05 / X06:** judged without pixels. S05/S06 can't fire; S01–S03 still
  do.

## 6. The measurement

`measureScreen` (`measure.dart`), on a background isolate:

1. **Decode** with the pure-Dart `image` package (JPEG, PNG, WebP, BMP,
   GIF, TIFF), converted to 8-bit RGB.
2. **Sample** every `step`-th pixel in both directions, `step =
   ⌊√(w·h / maxSamples)⌋` (3 for 1080×2340 at 300k samples). No resizing:
   averaging pixels together creates in-between colours and hides the
   exact flat areas that identify rendered UI.
3. **Dominant colour:** a 15-bit colour histogram (5 bits per channel);
   the fullest bin's mean colour is the dominant colour. A sample counts
   as that colour if every channel is within `colorTolerance` (6). Using
   the bin's *mean* plus a tolerance keeps a JPEG flat area whose values
   straddle a bin edge counted as one colour.
   - `dominantShare`: over the whole frame (S04, S05).
   - `contentDominantShare`: over the rows between the top `topBarShare`
     and bottom `bottomBarShare` bands (S06).
4. **Status bar** (portrait only), in the top `topBarShare` rows sampled at
   half the step: the band's own dominant colour is the bar's background;
   a *mark* is a sample ≥ `markContrast` (48) from it in any channel.
   Found when marks are 0.3–30% of the band, the left 35% and right 35%
   each hold ≥ 15% of the marks, the middle 30% holds ≤ 10%, and the top
   tenth of the band holds ≤ 10% (glyphs sit mid-bar; photo objects run
   off the edge). The background is *not* required to be plain: maps and
   photo viewers draw under a transparent status bar.
5. **Flatness** (evidence and X03 only): share of samples equal within
   `flatTolerance` (1) to their right and lower neighbours.

Metadata is read from the first `headBytes` (256 KB) without decoding:
JPEG APP1 Exif and XMP segments (until the picture data starts), PNG
chunks before the first IDAT (`eXIf`, `tEXt`, `zTXt`, `iTXt`), WebP
`EXIF`/`XMP ` chunks. The image size comes from PNG IHDR, JPEG SOF or the
WebP VP8/VP8L/VP8X header. Malformed metadata reads as missing; it never
throws.

## 7. Measurements behind the thresholds

All on synthetic screens from `screenshot_factory.dart` (status bar,
gesture bar, flat app layouts, text as solid bars; feed and article screens
embed noisy camera-like photos) and camera-like pictures (scenes with lens
softness r1 and noise ±3), decoded through the same path the scan uses.

**Per kind of image** (whole-frame dominant share / content dominant share
/ status bar / flatness):

| Image | Dominant | Content | Status bar | Flat |
|---|---|---|---|---|
| Phone screenshots, 6 apps, PNG / JPEG q90, 1080×2400 | 33–87% | 27–86% | found | 37–99% |
| Same, shared: 720 px wide, JPEG q70 | 33–86% | 27–85% | found | 78–90% |
| Computer screenshots, 4 apps, 1920×1080 | 30–61% | 33–63% | (landscape) | 71–98% |
| Game frame with HUD | 18% | 20% | (landscape) | 91–99% |
| Note with one line of text | 97.9% | **98.1%** | found | 99.7% |
| Black frame (secure content) | **100%** | 100% | none | 100% |
| White screen + status/gesture bars | 99.6% | **100%** | found | 99.9% |
| Black desktop + taskbar | 95.6% | **100%** | (landscape) | 99.7% |
| Camera photo 1600×1200, q92 | 11% | 12% | (landscape) | 48% |
| Camera photo 900×1600, shared q60, no Exif | 9% | 10% | none | **94%** |
| Wallpaper 1080×2400, q88 | 8% | 9% | none | 76% |
| Story graphic 1080×1920 (flat design) | 52% | 56% | none (marks in the middle) | 99.5% |
| Slide/diagram export 1920×1080 | 48% | 53% | (landscape) | 99.5% |
| Photo of a laptop screen | 13% | 15% | (landscape) | 32% |
| Scanned receipt (noise ±2) | 57% | 53% | none | 2% |

**Sweeps** (random seeds):

| Set | Status bar found | Dominant share | S04 would fire |
|---|---|---|---|
| 80 portrait camera pictures (540×1170, q90 and q60) | 4 (5%) | max 14.6% | **0** |
| 120 shared phone screenshots (6 apps × 20 seeds, 720 px, q70) | 117 (97.5%) | min 32.8% | 117 |

Readings:

- **Flatness is not a usable rule.** JPEG compression wipes out sensor
  noise, so a camera photo re-compressed at q60 measures 94% flat, more
  than many real screenshots. It's kept as evidence and for the X03 note.
- **Dominant share separates** camera pictures (≤ 14.6%) from app screens
  (≥ 32.8% over 120 shared screenshots; 27% *content* share for a photo
  feed). `uiDominantShare` 25% sits in the gap. Game frames (18%) are
  below it, so a game capture with no name or folder isn't S04; Game Bar
  and Steam captures carry both.
- **Blank shares:** blank frames 99.6–100%, the one-line note 98.1%.
  `blankShare` 99.7% leaves 1.6 points of margin for the note and admits
  the white screen with bars only through S06's content area (its whole
  frame is 99.6%).
- The 3 missed status bars in the sweep were screens whose top band is
  busy (map features right under the bar). They stay unflagged (missed
  recall, not a false positive).

## 8. Tuning knobs

All in `ScreenshotRules` (`rules.dart`). CLI flags in brackets.

| Knob | Default | Trade-off |
|---|---|---|
| `namePatterns` | §5 table | S01. Adding a pattern is the cheapest recall gain; keep each one anchored and tool-specific. |
| `toolWords` | §5 | S02. Substring match on metadata; words must be specific to capture tools. |
| `screenshotFolders` | screenshots, screen captures… | S03. Checked against the nearest 3 folders. |
| `uiDominantShare` [`--ui-share`] | 0.25 | S04. Lower catches feed screenshots dominated by photos; camera pictures reach 0.146. |
| `minPortraitAspect` | 1.3 | S04 shape, and the header pre-filter for unsignalled images. Lower decodes more images. |
| `markContrast` | 48 | Status-bar marks. Lower finds faint icons, and finds more marks in photos. |
| `topBarShare`, `bottomBarShare` | 0.045, 0.05 | Bar bands for S06 and the status-bar search. Status bars are 2.5–4% of a phone screen; taskbars 4–5% at 1080p. |
| `blankShare` [`--blank-share`] | 0.997 | S05/S06. Lower risks calling a one-line note empty (98.1%). |
| `colorTolerance` | 6 | Per-channel tolerance around the dominant colour; covers JPEG wobble. |
| `graphicFlatShare`, `flatTolerance` | 0.5, 1 | X03 note only. |
| `phoneAspect` | 1.7 | Phone vs tablet batch. |
| `recentWindow` [`--recent-days`] | 2 days | X02. |
| `oldAge` | 30 days | "Older than a month" counts in batches. |
| `headBytes` | 256 KB | Header read for metadata and size. Phone and camera metadata fit in a few KB; large XMP or embedded previews need more. |
| `maxSamples` | 300 000 | Pixels sampled per image. Lower is faster, coarser shares. |
| `maxImageBytes` | 64 MB | Larger images aren't decoded (X06). |
| `concurrency`, `useIsolates` | 4, true | Images in flight; decode off the main isolate. |
| `minConfidence` [`--min-confidence`] | likely | Drops S03/S04 when `certain`. |
| `disabledRules` [`--disable S04`] | none | A disabled rule falls through to the next. |

The empty & unreadable checks take their own `EmptyUnreadableRules`
(`ScreenshotScan.healthRules`; the CLI's `--grace-minutes` sets its grace
period).

## 9. Known gaps

- **Thresholds are calibrated on synthetic screens.** Real apps have
  gradients, translucent bars, wallpapers behind widgets and photos
  filling the screen (gallery, camera viewfinder, Instagram stories), so
  their dominant share can be lower than 25% and S04 will miss them. Real
  camera photos are noisier than the synthetic ones, which helps. The
  first tuning step is a labelled set of real screenshots and photos.
- **Landscape images without a signal aren't judged.** A renamed computer
  screenshot with no tool mark is missed. A taskbar/menu-bar detector
  (the landscape equivalent of the status bar) would allow a landscape
  S04; it must still tell a desktop capture from an exported slide.
- **iOS photo library.** Assets have photo names (`IMG_1234.PNG`) and their
  bytes can't be read (X05), so on iOS the scan sees nothing. PhotoKit
  marks screenshots directly (`PHAssetMediaSubtype.photoScreenshot`); the
  Flutter adapter should pass that through as a signal (merge step 3).
- **HEIC** isn't decoded in pure Dart (X06): S05/S06 can't fire and S04
  can't identify it. Phones decode it natively.
- **Long (scrolling) screenshots** are very tall; the status bar is only
  at the top and the shares are diluted by content. They're usually named
  by the tool, so S01 covers them.
- **Status bars that aren't at the top** (landscape phone captures put the
  bar on the side or hide it) aren't found; those need S01–S03.
- **Edited copies** (a screenshot cropped and saved elsewhere) keep no
  signal and aren't phone-shaped; they're missed unless filed under a
  screenshots folder. Copies saved next to the original are the duplicate
  photo scan's job.
- **Time taken** comes from the name or last-modified. Copying a
  screenshot without a dated name resets its age, so an old one can look
  recent (X02) for two days.

## 10. Performance

From the test area on a development laptop (pure-Dart decoder, 4 workers
on background isolates):

| Step | Cost |
|---|---|
| Path signals (regexes, folder lookup) | microseconds per file |
| Header read (≤ 256 KB) + metadata + size | not measured separately; negligible next to decoding |
| Decode + measure 1080×2340 JPEG/PNG | ~40–155 ms per image (calibration run, single thread) |
| Test area total (40 files, 39 images: 31 headers read, 4 ruled out by header, 26 decoded, 7.4 MB read) | ~0.5 s wall time (~2 s of decoding across isolates), plus the empty & unreadable checks |

The header pre-filter is what keeps this scan cheap on a real camera roll:
camera photos (Exif exposure data) and landscape images with no signal are
never decoded, so on a typical phone only screenshots and portrait images
without camera data reach the decoder.

**Known waste, for the optimisation pass:**

- Screenshots identified by name are decoded only to check for blankness
  (S05/S06). Decoding a small thumbnail, or sampling only the dominant
  colour from a few rows first, would answer "not blank" for most of them
  without a full decode.
- The empty & unreadable checks' U08 decode and this scan's decode both
  decode every screenshot in full. Letting U08 trust a successful decode
  here would halve it.
- The full file is read again after the 256 KB header for images larger
  than that; reading the remainder only would save one header's worth.
- Each image is copied into the isolate. `TransferableTypedData` would
  avoid the copy.

## 11. Accuracy baseline

Test area `test_area/screenshot_detection` (ruleset 1.0): **40/40
expectations met.**

| Group | Files | Result |
|---|---|---|
| Screenshots: S01 ×12, S02 ×2, S03 ×2, S04 ×1, S05 ×2, S06 ×2, incl. kind (phone/computer/unknown) | 21 | 21/21 rules and kinds right |
| Empty & unreadable screenshot files (E01, U03, U04, U06, U07, U08) | 6 | 6/6 |
| Not flagged: camera photos (incl. one in the Screenshots folder, X01, and a photo of a screen), wallpaper, shared portrait photo, story graphic (X03), slide export, scanned invoice, Game Bar clip (X04), a recent boarding pass (X02), two broken images that aren't screenshots | 13 | 13/13 |

The recent boarding pass is planted an hour before the area is built and
`expected.json` records when it stops being recent (two days later); after
that the expectation becomes S01, so the area stays valid.

The automated tests (`test/screenshot_rules_test.dart`,
`test/screenshot_test_area_test.dart`) pin every name pattern (including
the macOS narrow space and 12 AM), metadata marks and camera evidence,
damaged metadata, header sizes, the measurement on every synthetic app and
look-alike, every rule and its precedence, the camera override, the header
pre-filter, recency (and that it doesn't hold back blank captures), rule
switching and confidence filtering, E/U reporting for screenshots only,
unreadable contents, screen recordings, batches and the permission gate.

## 12. Merging into the mass scan

1. Add `WasteCategory.screenshot('Screenshots')` to `scan_engine` and
   replace `screenshotCategoryStandIn` (currently `blankPhoto`, used only
   in this standalone run).
2. Add the detector to the engine:
   `ScreenshotAnalyzer(health: sharedEmptyUnreadable).detector(WasteCategory.screenshot)`,
   sharing the same `EmptyUnreadableAnalyzer` as the empty & unreadable
   detectors so files are checked once. Decide whether broken screenshot
   files are shown under *Screenshots* or *Unreadable files*; this scan
   lists them but the E/U detectors also report them, so the review UI must
   not count them twice (`ScanReport` already de-duplicates bytes).
3. iOS: have the Flutter adapter expose PhotoKit's screenshot subtype on
   `StorageItem` (or a side table) and treat it as an S02-strength signal.
4. Coordinate with the other photo scans: the blank-photo detector should
   skip S05/S06 screenshots (reported here with a better reason), and the
   blurry scan already leaves screenshots out.
5. Review UI: show `batches` as the bulk-clear groups, with the
   pre-selected ones ticked and per-app counts as filters.

## 13. Changelog

- **1.0** (2026-11-01): first version. S01–S06, X01–X06; empty & unreadable
  screenshot files via DAT-20; batches for bulk review; test area with 40
  planted files.
