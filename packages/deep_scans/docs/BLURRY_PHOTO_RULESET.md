# Blurry Photos — Deep Scan Ruleset

| | |
|---|---|
| **Jira** | DAT-22 (PB-07 *Blurry photo detection*), epic DAT-8 *Scanning & Detection* |
| **Related** | DAT-21 (duplicate photos, whose comparison B04 reuses), DAT-20 (empty & unreadable, run alongside), DAT-34 (best-copy suggestion) |
| **Ruleset version** | `1.0` (`blurryPhotoRulesetVersion` in `lib/src/blurry_photos/scan.dart`) |
| **Code** | `packages/deep_scans/lib/src/blurry_photos/` |
| **Test area** | `dart run tool/make_blurry_photo_test_area.dart` → `test_area/blurry_photos/` |
| **Status** | Standalone. The mass scan (`scan_engine`) is unchanged and has no blurry-photo detector yet. |

This is the reference for every rule the blurry photo deep scan applies,
written for the later pass that tunes each scan for performance and
accuracy. Each rule lists its signals, thresholds and the measurements behind
them, what it can get wrong, and which knob controls it.

## 1. Where the requirements come from

- **DAT-22:** "Score each image for blurriness and report which photos are
  the most blurry." → every measured photo gets a blur score (0–100) and the
  result is a ranking, blurriest first, not just a yes/no list.
- **Feature list, Bad Photo Detection Scan:** "measures each one for
  blurriness, then ranks the results"; output "a list of duplicates and
  blurriest photos, each selectable for collection". → findings are
  `Finding`s the review UI already understands, ranked by blur.
- **Alexa:** the scan "finds identical hike shots and blurry photo
  attempts". → an *attempt* is a blurry shot that was retaken (B04). Her
  camera roll also holds food shots (portrait mode), screenshots and travel
  scenery (fog, sky), which must not be called blurry.
- **Gerald:** "the app found blurry photos" of his grandchildren: moving
  kids (motion blur, B03), indoor and evening shots (dark, noisy, but often
  sharp).
- **Ethan:** "pictures of receipts taken multiple times because of focus
  issues", and the app "suggests the clearest version". → B04 suggests
  keeping the sharp retake. Ethan also has many *different* receipts that
  look alike; one must never be mistaken for the retake of another. And
  "several empty files from failed downloads" → the empty & unreadable
  checks run alongside and their photo findings are part of this scan's
  result.
- **Jasmine:** wedding photos are often deliberately soft in places
  (portraits at wide aperture, panning shots) and delivered as small,
  compressed copies. None of that is blur.
- **Feature list, Garbage Collection:** results go to the bin, so a false
  positive costs a user a real photo. Precision is favoured over recall
  wherever a threshold has to choose.

## 2. What counts

A photo is **blurry** when *even its sharpest part* is soft, measured as
the width of its edges at a fixed viewing size. Two choices follow:

- **Sharpest part, not average.** A portrait with a sharp face and a
  blurred background is a good photo. The scan cuts the frame into tiles
  and judges the best tiles, so only photos with *nothing* in focus count.
- **Viewing size, not pixels.** Widths are in *reference pixels*: the photo
  shown with its long side `analysisSize` (512) pixels, about half a phone
  screen. A 3-pixel smear in a 12-megapixel photo is invisible on a phone;
  the same smear in an 800-pixel photo isn't. Photos smaller than the
  reference are judged at their own size, never upscaled (upscaling itself
  adds blur).

**Empty and unreadable photos** (0-byte, cut-off, damaged, still
downloading, wrong contents) can't be judged for blur. They come from the
empty & unreadable deep scan (DAT-20, `EMPTY_UNREADABLE_RULESET.md`), which
this scan runs alongside; their photo findings are reported here under that
scan's rule codes (E01, U03…).

## 3. How the scan works

```
storage items ──► empty & unreadable checks ──► photos they flag: reported as E/U
      │
      ▼ photo formats (jpg, jpeg, png, heic, heif, webp, bmp)
  X03 screenshot? X05 can't decode here? X06 too large?
      │
      ▼ decode to analysisSize² grey thumbnail (re-decode at the short side if smaller)
  X02 icon?  X01 blank?
      │
      ▼ BlurMeasurement (§6): edge widths per tile × direction
  X04 too few edges?
      │
      ▼ retake search for soft photos (§5, B04)
      │
      ▼ B01 → B04 → B03 → B02 (first match wins), score, rank blurriest first
```

Code: `analyzer.dart` (pipeline), `measure.dart` (edge widths),
`retake.dart` (fine-detail retake check), `rules.dart` (rule ids and knobs),
`model.dart` (verdicts, observations), `scan.dart` (runner, output,
verification).

The scan runs through `ScanEngine`, so the storage permission gate applies
exactly as in the mass scan: without access it throws
`PermissionDeniedException` and reads nothing (the CLI exits 2).

### Confidence

Shared with the other deep scans (`lib/src/shared/confidence.dart`):

- **certain**: unmistakable. Anyone looking at the photo would agree, or a
  sharper version of the same shot exists.
- **likely**: blurry by measurement, but a rare photo could be soft on
  purpose (a motion-blur effect, a dreamy portrait). Shown, worth a second
  look when tuning. `--min-confidence certain` hides these.

### Observations

Photos left out, or near-misses, are recorded with a reason so tuning can
see them (`BlurObservationKind`):

| Kind | Code | Meaning |
|---|---|---|
| `blank` | X01 | Flat colour; left to the blank-photo scan. |
| `tooSmall` | X02 | Under `minPhotoDimension` on a side: icon, sticker. |
| `screenshot` | X03 | Named `Screenshot…` or in a `Screenshots` folder. |
| `lowDetail` | X04 | Under `minEdges` edges or `minRegionTiles` judged tiles: fog, sky, a plain wall, darkness. |
| `cantDecode` | X05 | Format this device can't decode (HEIC on a computer). |
| `tooLarge` | X06 | Over `maxPhotoBytes`. |
| `undecodable` | | Format supported, file won't decode, yet the empty & unreadable checks passed it. Should not happen; worth a look. |
| `unreadable` | | Read failed (permissions, file vanished). |
| `sharpSubject` | P01 | Soft background, sharp subject: portrait mode, panning. Not flagged. |
| `retakeRejected` | | A sharper shot with the same layout but different fine detail (a different receipt). Not used as a retake. |
| `nearMiss` | | Blur width within `nearMissShare` of the B02 threshold. |
| `suppressed` | | A rule matched but was disabled or below `minConfidence`. |

## 4. Rules at a glance

Precedence is top to bottom; a photo gets at most one rule.

| Code | Name | Confidence | Fires when | Finding |
|---|---|---|---|---|
| B01 | Severely blurry | certain | blur width ≥ `severeWidth` (3.6) | photo |
| B04 | Blurry attempt | certain | blur width ≥ `softWidth` (1.5) and a sharper retake exists (§5) | photo + retake (kept) |
| B03 | Motion blur | likely | blur width ≥ `softWidth`, one direction ≥ `motionMinWidth` (2.2) and ≥ `motionRatio` (2.5)× the crispest | photo |
| B02 | Blurry | likely | blur width ≥ `blurryWidth` (2.4) | photo |
| E/U | Empty or unreadable photo | per DAT-20 | the empty & unreadable deep scan flags an image-named file | photo |

The **blur score** is `100 × (1 − sharpWidth / blurWidth)`, clamped to
0–100 (`sharpWidth` = 1.0): 0 for an in-focus edge, 50 at twice that
width, 72 at the B01 threshold. It's monotonic in blur width, so ranking by
either is the same.

## 5. Rules in detail

### B01 — Severely blurry

- **Signal:** the sharpest region's blur width (§6) ≥ `severeWidth`.
- **Catches:** missed focus (the bakery window), heavy camera shake (the
  mini-golf swing), receipts photographed far too close. The reason says
  which: "out of focus" or "smeared left–right by camera shake or
  movement" when the blur is directional (B03's test).
- **Can go wrong:** a deliberately abstract photo (light trails, intentional
  defocus). Rare enough for `certain`; revisit if user reports say
  otherwise.
- **Knob:** `severeWidth` (`--severe-width`).

### B04 — Blurry attempt (a sharper retake exists)

- **Signal:** the photo is at least `softWidth`, and another photo:
  1. was taken within `retakeTimeWindow` (30 min, by last-modified time);
  2. has a blur width ≤ `retakeSharpnessRatio` (0.6) × this photo's and is
     itself under `blurryWidth`;
  3. matches the same layout under the duplicate photo scan's comparison
     (`comparePhotos`, no rotation, no added borders) with the looser
     retake thresholds `retakeHashDistance` 8, `retakeCorrelation` 0.93,
     `retakeEdgeCorrelation` 0.75 (blur moves the hash; D06's 4 bits miss
     real blurry retakes, measured pHash 6);
  4. **passes the fine-detail check** (`retake.dart`): the sharper photo is
     blurred to match (`σ = √(w_blurry² − w_sharp²) / 2.56`), both are
     aligned within `retakeMaxShift` (5%) of the frame, the overall layout
     is subtracted (local mean over 1/40 of the frame), and the remaining
     detail must correlate ≥ `retakeDetailAgreement` (0.92).

  The sharpest qualifying retake is kept. The finding lists both photos
  with the retake as `keep`, so only the blurry one is reclaimable and the
  UI can show them side by side ("suggests the clearest version").
- **Why step 4 exists:** once a receipt is even slightly soft, *different*
  receipts in the same layout look identical at the 32×32 grid the
  duplicate comparison uses. Measured over 60 soft receipts × 59 different
  sharp ones: 244 of 3,540 pairs pass step 3, and some (e.g. receipts 155
  vs 117) pass even D06's strict 4-bit test. Their text doesn't line up,
  which step 4 sees (§7).
- **Catches what B02 can't:** a mildly soft shot (blur width 1.5–2.4,
  not flagged on its own) that has a sharp retake: Alexa's hike attempt.
  It also upgrades B02/B03 photos to `certain` when the retake exists.
- **Can go wrong:** two genuinely different photos of the same static scene
  taken minutes apart, one soft: B04 suggests removing the soft one, which
  is what the user would want anyway. A retake taken more than 30 minutes
  later isn't found (the photo still gets B02/B03 if blurry enough).
  In-memory and copied files can share one timestamp; that only makes more
  pairs candidates, and steps 2–4 still apply.
- **Knobs:** `softWidth`, `retakeSharpnessRatio`, `retakeTimeWindow`,
  `retakeHashDistance`, `retakeCorrelation`, `retakeEdgeCorrelation`,
  `retakeDetailAgreement`, `retakeMaxShift`.

### B03 — Motion blur

- **Signal:** blur width ≥ `softWidth`, the softest direction's
  sharpest-region width ≥ `motionMinWidth`, and that is ≥ `motionRatio` ×
  the crispest direction's width (floored at 0.25 px).
- **Catches:** camera shake and moving subjects (the food fight), which
  smear one direction and leave the other crisp. The softest direction is
  named in the reason.
- **Why it isn't just B02:** motion blur leaves crisp edges along the
  motion, so a tile with only those edges looks sharp and the plain blur
  width under-reads it (measured 1.6–3.2 for shakes that look clearly
  blurry). B03 reads each direction separately.
- **Can go wrong:** intentional motion (light trails, flowing water, a
  panning shot whose subject is small). Hence `likely`. A panning shot with
  a reasonable subject passes: its subject tiles are sharp, so blur width
  stays under `softWidth` (measured 1.0–1.3).
- **Knobs:** `motionMinWidth`, `motionRatio`, `softWidth`.

### B02 — Blurry

- **Signal:** blur width ≥ `blurryWidth`.
- **Catches:** noticeable missed focus with no retake (the trail sign, the
  out-of-focus night street, a blurry receipt).
- **Can go wrong:** soft-focus portraits and photos through fogged glass
  (`likely`). Very dark photos where every edge is low contrast: the
  contrast floor (`minEdgeContrast`) makes them `lowDetail` instead.
- **Knob:** `blurryWidth` (`--blurry-width`).

### Empty and unreadable photos (E/U rules)

The empty & unreadable deep scan runs in the same engine and shares its
analyzer, so each file is read once. Every verdict on an image-named file
(or a partial download of one, `IMG_1.jpg.crdownload`) is listed in this
scan's result under that rule and skipped by the blur check. Typical
photo cases from the test area: E01 0-byte, U03 unfinished download, U04
zero-filled, U05 a web page saved as `.jpg`, U06 download stopped partway,
U07 PNG checksum fails, U08 picture data scrambled. Their rules, precedence
and grace period (files modified in the last 10 minutes aren't judged) are
in `EMPTY_UNREADABLE_RULESET.md`.

### Exclusions and protections

- **X01 blank:** brightness spread ≤ `blankMaxStdDev` (5). Pocket and
  lens-cap shots belong to the blank-photo scan; with no edges they'd also
  be X04.
- **X02 too small:** under `minPhotoDimension` (200 px) on a side.
- **X03 screenshot:** not a camera photo; a blurred video frame grab or an
  iOS frosted-glass UI isn't a "blurry photo attempt". Screenshots are also
  never retake candidates.
- **X04 low detail:** fewer than `minEdges` (200) measurable edges, or
  fewer than `minRegionTiles` (2) tiles with edges in two directions. Fog,
  clear sky, plain walls, near-black frames: nothing to judge focus by, so
  nothing is claimed.
- **X05 / X06:** can't decode the format here (HEIC on a computer; phones
  decode it natively), or larger than `maxPhotoBytes` (64 MB).
- **P01 sharp subject:** median edge width of the whole frame ≥
  `blurryWidth` but the sharpest region < `softWidth`. Recorded so tuning
  can see how often the tile approach saves a photo.

## 6. The measurement

`BlurMeasurement.fromThumbnail` on the `analysisSize`² greyscale thumbnail:

1. **Find edge points.** Central-difference gradient ≥ `minGradient` (3
   levels/px). The crossing direction is the nearest of four (left–right,
   up–down, two diagonals) to the gradient. Only the steepest point of each
   crossing is kept (non-maximum suppression along the direction).
2. **Walk across the edge** both ways until brightness stops rising (or
   falling), tolerating wobbles up to `walkTolerance` (3 levels) for up to
   `walkPatience` (2 px), at most `maxWalk` (24 px). Edges whose total
   change is under `minEdgeContrast` (24 levels) are noise and dropped.
3. **Width** = distance from 10% to 90% of the change, interpolated between
   pixels, converted to reference pixels (the thumbnail is square, so the
   short side is stretched; each direction's step length undoes that).
4. **Pixel floor.** A perfectly sharp edge still measures about one pixel
   because it falls between pixels. `pixelFloor` (1.0 thumbnail px) is
   taken off in quadrature (`√(w² − floor²)`), the way blurs combine. This
   widened the gap between the softest sharp photo and the mildest flagged
   blur from 15% to over 40%.
5. **Tiles.** Widths are collected per tile of a `tiles`² (8×8) grid and
   per direction. A tile direction with ≥ `minTileEdges` (8) edges gets its
   median width. A tile with two or more such directions is *judged*, and
   counts as soft as its softest direction.
6. **Blur width** = mean of the best `sharpRegionShare` (5%, at least 1) of
   judged tiles. **Direction widths** (for B03) = the same, per direction
   on its own, over tiles with edges in that direction.

Brightness spread and mean are measured on the same thumbnail (X01).

## 7. Measurements behind the thresholds

All on synthetic 1600×1200 photo-like scenes and 900×1200 receipts
(`photo_factory.dart`, `blur_factory.dart`), JPEG q90, decoded through the
same pure-Dart path the scan uses, `analysisSize` 512. Two to three seeds
each; ranges shown. Blur radii are `img.gaussianBlur` radii in source
pixels; motion lengths are source pixels.

**Blur width (reference px) by kind of photo:**

| Photo | Blur width | Rule |
|---|---|---|
| Perfect synthetic edges | 0.0–0.7 | — |
| Camera-sharp (lens softness r1 + noise) | 0.3–1.0 | — |
| WhatsApp copy (800 px, q60) | 1.1–1.3 | — |
| Web copy (q25–30) | 0.2–1.0 | — |
| Old 640×480 photo (judged at 480) | 0.0–1.7 | — |
| Night street, sharp (dark, noise 6) | 0.1–0.6 | — |
| Portrait mode (subject 30–40% of frame, background r10–12) | 1.0–1.4 | P01 |
| Panning shot (subject sharp, background 30 px streak) | 1.0–1.3 | P01 |
| Out of focus r2 / r3 / r4 | 1.3 / 1.6 / 2.0 | — / — / — |
| Out of focus r6 / r7 | 2.8 / 3.3 | B02 |
| Out of focus r9 / r14 | 4.0 / 5.5–5.8 | B01 |
| Receipt r3 / r4 / r6 / r8 / r10 | 2.2–2.4 / 2.7–3.0 / 3.8 / 4.7 / 5.7 | near / B02 / B01 |
| Night street, out of focus r8 | 2.9–3.3 | B02 |
| Fog / clear sky | not judgeable (0 edges) | X04 |

Sharp photos top out at 1.7 (small photos, whose lens softness isn't
shrunk away), 1.4 for full-size ones. Hence `softWidth` 1.5 (only for
B03/B04, which need a second signal) and `blurryWidth` 2.4: everything a
person would call blurry at r6+ is caught, r4 ("slightly soft, fine")
isn't. `severeWidth` 3.6 separates r9+ and heavy shake.

**Motion blur (softest direction width / directionality / blur width):**

| Shake | Horizontal | 45° |
|---|---|---|
| 8 px | 2.3 / 9+ / 1.6 | 1.8 / 1.8–2.4 / 1.4 |
| 14 px | 3.6–3.8 / 14+ / 2.0–3.2 | 3.3–3.4 / 3.4–4.1 / 2.1–2.2 |
| 24 px | 5.5–5.6 / 20+ / 3.2–4.9 | 4.8–5.2 / 3.3–4.3 / 3.2–3.4 |
| 40 px | 6.1–6.9 / 24+ / 4.9–5.9 | 5.6–5.8 / 3.7–3.9 / 5.0–5.3 |

Focus blur's directionality is 1.0–1.4, so `motionRatio` 2.5 separates
them with room; 8 px at 45° (1.8) is mild and stays unflagged. Note how the
blur width alone under-reads shake (1.6–3.2 at 8–14 px), which is why B03
exists.

**B04 retake checks:**

| Pair | pHash | Correlation | Edges | Fine-detail agreement |
|---|---|---|---|---|
| Receipt retakes (0–2% moved), blurry one r3–r9 (n=60) | 2–6 | 0.97 | 0.87 | **0.953–0.998** (median 0.987) |
| Landscape retakes (2% moved), blurry one r3–r9 or 14 px shake (n=42) | 2 | 0.99+ | 0.98 | **0.946–0.985** |
| Different receipts, same layout (n=60) | 4–8 when confusable | 0.966–0.972 | 0.93–0.95 | **0.807–0.854** |
| Different scenes (n=21) | 26+ | — | — | 0.00–0.05 |

`retakeDetailAgreement` 0.92 sits in the gap (0.854 → 0.946). The test area
plants the worst case found (receipt 155 soft vs 117 sharp: pHash 4, passes
even D06; agreement 0.825).

## 8. Tuning knobs

All in `BlurryPhotoRules` (`rules.dart`). CLI flags in brackets.

| Knob | Default | Trade-off |
|---|---|---|
| `analysisSize` [`--analysis-size`] | 512 | Bigger catches subtler blur and makes widths finer, costs memory (n² bytes per photo in flight) and measuring time (~n²). All width thresholds are in reference px at this size, so changing it shifts what they mean; re-measure §7. |
| `blurryWidth` [`--blurry-width`] | 2.4 | B02. Lower = more recall, more soft-but-fine photos flagged. |
| `severeWidth` [`--severe-width`] | 3.6 | B01 (`certain`). |
| `softWidth` | 1.5 | Minimum for B03/B04. Must stay above the softest sharp photo. |
| `sharpWidth` | 1.0 | Score zero point. Ranking only. |
| `motionMinWidth`, `motionRatio` | 2.2, 2.5 | B03. |
| `retakeSharpnessRatio` | 0.6 | How much sharper a retake must be. |
| `retakeTimeWindow` | 30 min | Retake search window. |
| `retakeHashDistance`, `retakeCorrelation`, `retakeEdgeCorrelation` | 8, 0.93, 0.75 | B04 candidate filter (cheap). Looser = more pairs reach the detail check. |
| `retakeDetailAgreement`, `retakeMaxShift` | 0.92, 0.05 | B04 decision. The precision guard. |
| `minEdges`, `minRegionTiles` | 200, 2 | X04. Higher = more photos skipped as featureless. |
| `minGradient`, `minEdgeContrast` | 3, 24 | Edge finding. Lower contrast lets noise in (narrower widths on noisy photos); higher loses soft low-contrast edges. |
| `walkTolerance`, `walkPatience`, `maxWalk` | 3, 2, 24 | Edge walking. `maxWalk` caps measurable width (~24 px at 512). |
| `tiles`, `minTileEdges`, `sharpRegionShare` | 8, 8, 0.05 | Region size. Larger region = less sensitive to one sharp detail (a timestamp overlay), more likely to miss a small sharp subject. |
| `pixelFloor` | 1.0 | Sharp-edge floor removed in quadrature. |
| `nearMissShare` | 0.85 | Near-miss observations. |
| `blankMaxStdDev`, `minPhotoDimension`, `maxPhotoBytes` | 5, 200, 64 MB | X01, X02, X06. |
| `screenshotFolders` | screenshots | X03. |
| `concurrency` | 4 | Photos decoded at once. |
| `minConfidence` [`--min-confidence`] | likely | Drops B02/B03 when `certain`. |
| `disabledRules` [`--disable B04`] | none | A disabled rule falls through to the next. |

The empty & unreadable checks take their own `EmptyUnreadableRules`
(`BlurryPhotoScan.healthRules`).

## 9. Known gaps

- **Thresholds are calibrated on synthetic photos.** Real camera output is
  softer at baseline (demosaicing, sharpening halos, lens character), so
  real sharp photos may measure 1–2 px, closer to the thresholds. The first
  tuning step should be running the scan over a labelled set of real phone
  photos and re-deriving §7.
- **Text or timestamp overlays.** A burned-in date stamp on a blurry photo
  gives one or two sharp tiles; at 5% of ~50 tiles (3 tiles) one tile can
  pull the blur width down. Watermarks and stickers likewise.
- **Small sharp subjects.** A sharp subject under ~5% of the frame (a bird
  in the sky) may be outvoted; it would show as B02 with P01-like stats.
- **Square thumbnails.** The decoders don't keep aspect ratio. Widths are
  corrected per direction, but the diagonal directions are only
  approximately diagonal on non-square photos.
- **Night photos** are judged only on their bright edges. Fine in tests;
  heavy noise reduction on real phones may soften them.
- **Live Photos, bursts, HDR merges** are judged as single frames.
- **B04 uses last-modified time**, not EXIF capture time; copied photos
  lose it and won't be retake candidates beyond the time window.
- **Different-receipt confusion in DAT-21.** The receipt pairs that pass
  D06's strict test here (§5, B04) do so *sharp vs sharp* too, so the
  duplicate photo scan can group two different receipts taken within its
  30-minute shot window. Out of scope for this scan; the fix is to require
  `detailAgreement` (this scan's `retake.dart`) for D06 matches there.

## 10. Performance

From the test area on a development laptop (pure-Dart decoder, 4 decode
workers; phones use the native decoder and are much faster):

| Step | Cost |
|---|---|
| Decode 1600×1200 JPEG to 512² | ~100 ms per photo (dominant) |
| Measure (edge widths, tiles) | ~15–22 ms per photo at 512² |
| Retake candidates (`comparePhotos`) | < 1 ms per pair; only soft photos × photos within 30 min |
| Fine-detail check | ~19 ms per pair (plus re-decoding both photos); only pairs that pass the candidate filter (3 of 10 in the test area) |
| Test area total (37 files, 25 measured) | ~1.4 s wall time, plus the empty & unreadable checks |

Memory: one `analysisSize`² thumbnail (256 KB at 512) per decode worker,
plus a 32×32 fingerprint per measured photo. Thumbnails for the detail
check are re-decoded on demand and dropped after the retake step.

**Known waste, for the optimisation pass:**

- The empty & unreadable checks' U08 decode and this scan's decode both
  decode every photo in full. Sharing one decode (or letting U08 trust a
  successful blur decode) would roughly halve photo decoding.
- Small photos are decoded twice (once to learn the size, once at their
  short side). Reading the size from the header first would avoid it.
- The retake search is quadratic within the time window; sorting by time
  and sweeping (as the duplicate scan's `_closeInTime` does) would bound it
  on libraries with thousands of photos per day.

## 11. Accuracy baseline

Test area `test_area/blurry_photos` (ruleset 1.0): **37/37 expectations
met, ranking order right.**

| Group | Files | Result |
|---|---|---|
| Blurry (B01 ×3, B02 ×2, B03 ×2, B04 ×2, incl. retake targets) | 9 | 9/9 rules right, both retakes right |
| Empty & unreadable photos (E01, U03–U08) | 7 | 7/7 |
| Look-alikes that must not be flagged | 21 | 21/21 (incl. 4 P01, 1 rejected retake, 2 screenshots, fog, pocket shot, sticker) |
| Ranking (bakery r14 > trail sign r7 > touch soft r3 > sharp) | 4 | in order |

The automated tests (`test/blurry_photo_rules_test.dart`,
`test/blurry_test_area_test.dart`) pin the measurement properties (monotonic
in blur, motion directionality, portrait-mode protection, no upscaling,
compression isn't blur, featureless isn't judged), every rule, the
different-receipt case, rule switching, exclusions, E/U reporting and the
permission gate.

## 12. Merging into the mass scan

1. Add `WasteCategory.blurryPhoto('Blurry photos')` to `scan_engine` and
   replace `blurryCategoryStandIn` (currently `blankPhoto`, used only in
   this standalone run).
2. Add the detector to the engine:
   `BlurryPhotoAnalyzer(health: sharedEmptyUnreadable).detector(WasteCategory.blurryPhoto)`,
   sharing the same `EmptyUnreadableAnalyzer` as the empty & unreadable
   detectors so files are checked once.
3. Share photo decoding with the duplicate photo scan and U08: both need a
   grey thumbnail (256 for duplicates, 512 here); decode once at 512 and
   downsample.
4. Coordinate with duplicate groups: a photo that is a non-keeper in a
   duplicate group shouldn't be counted again here for reclaimable space.
   B04 and D06 usually agree (sharpest shot kept); when both fire, show the
   duplicate group and tag its blurry members.
5. Move the score into the review UI: sort the blurry list by `score`,
   show the B04 pair side by side, and offer "keep the sharp one".

## 13. Changelog

- **1.0** (2026-11-01): first version. B01–B04, X01–X06, P01; empty &
  unreadable photos via DAT-20; fine-detail retake check; test area with
  37 planted files.
