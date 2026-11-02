# Duplicate Photos — Deep Scan Ruleset

| | |
|---|---|
| **Jira** | DAT-21 (PB-06 *Duplicate photo detection*), epic DAT-8 *Scanning & Detection* |
| **Related** | DAT-34 (best-copy suggestion, depends on this), DAT-22 (blur scoring), DAT-3 (non-image duplicates) |
| **Ruleset version** | `1.1` (`duplicatePhotoRulesetVersion` in `lib/src/duplicate_photos/scan.dart`) |
| **Code** | `packages/deep_scans/lib/src/duplicate_photos/` |
| **Test area** | `dart run tool/make_duplicate_photo_test_area.dart` → `test_area/duplicate_photos/` |
| **Status** | Standalone. The mass scan's `DuplicatePhotoDetector` (`scan_engine`) is unchanged. |

This is the reference for every rule the duplicate photo deep scan applies,
written for the later pass that tunes each scan for performance and
accuracy. Each rule lists its signals, thresholds and the measurements behind
them, what it can get wrong, and which knob controls it.

## 1. Where the requirements come from

- **DAT-21:** "find duplicate and near-identical photos so that I can remove
  redundant copies without sorting manually."
- **Feature list, Bad Photo Detection Scan:** compares images for
  duplicates, ranks the results, and outputs a list where each one is
  selectable for collection. Groups are ranked by space reclaimable.
- **Alexa:** "identical hike shots" from a trip, plus burst-style attempts.
  → copies of all kinds (D01–D05) and near-identical shots (D06).
- **Jasmine:** "duplicates and copies of photos from past shoots she had
  already prepared and sent". → client exports, album copies, backups.
- **Ethan:** "pictures of receipts taken multiple times because of focus
  issues"; the app "suggests the clearest version". → retakes are D06, and
  the keeper is the sharpest shot (feeds DAT-34). Ethan also has many
  *different* receipts that look alike, so these must never be grouped.
- **Gerald / Timmy:** duplicate photos and backed-up family photos.
  → identical copies across folders.
- **Feature list, Garbage Collection:** results are binned, so a false match
  costs a user a real photo. Precision is favoured over recall wherever a
  threshold has to choose.

## 2. What counts

A **duplicate group** is a set of photos where every photo is the same
picture as every other, and one is suggested to keep. "Same picture" means:

- a **copy**: the same image saved again, possibly resized, recompressed,
  converted, rotated, mirrored, given borders, or brightened (D01–D05); or
- a **near-identical shot**: another frame of the same moment, such as a
  burst frame or a retake seconds later (D06).

**Not duplicates:** the same place at another time; different content in the
same layout (receipts, chat screenshots); a reframed photo of the same scene.

**Out of scope** (§9): cropped copies, videos and Live Photo pairs, RAW+JPEG
pairs, collages, and screenshots *of* a photo with app UI around it.

## 3. How the scan works

```
all image files (by MediaKind)
 1. identical files ─ same size → same first 64 KB → same SHA-256   (D01)
 2. decode one photo per identical set at 256 px greyscale
      ├─ X01 blank (flat colour)          → left to the blank-photo scan
      ├─ X02 smaller than 200 px          → icon/sticker, not a photo
      ├─ X03 decodable format, damaged    → left to the unreadable scan
      └─ X04 format can't be decoded here → identical copies only
 3. candidate pairs
      ├─ banded pHash index, all 8 rotations/mirrors, with/without borders
      └─ photos taken within 30 min of each other (possible shots)
 4. compare each pair in depth → D02–D06, or a near-miss note
      └─ D06 only: decode both photos again, compare fine detail
         (agreement ≥ 0.90, else a detailDiffers note)
 5. complete-linkage grouping: every member must match every other
 6. keeper: K01–K07; every other member labelled by its rule vs the keeper
```

A photo is in at most one group. Groups are sorted by reclaimable space.

### Confidence

A group's confidence is its weakest member's:

| Level | Rules | Meaning |
|---|---|---|
| `certain` | D01, D02, D03 | The same image: byte-identical, re-saved, or turned. Safe to pre-select. |
| `likely` | D04, D05, D06 | Same picture, but the copy was changed on purpose (borders, edits), or it's a different frame. Show without pre-selecting. |

`minConfidence` drops members below a level; dropped members are recorded as
`dropped` observations.

### Observations

| Kind | When |
|---|---|
| `blank`, `tooSmall`, `undecodable`, `identicalOnly`, `unreadable` | Exclusions X01–X04 and read failures. |
| `nearMiss` | A pair came close to matching. The note says why it didn't, e.g. "similar, but taken 7 days apart". |
| `detailDiffers` | A pair passed D06 on the 32×32 layout but failed the fine-detail check (a different receipt on the same table). Not grouped. |
| `split` | A chain of matches (A~B~C, but not A~C) was split into groups. |
| `dropped` | A rule is disabled, or a member is below `minConfidence`. |

## 4. Rules at a glance

| Code | Rule | Confidence | Test (vs the photo kept) |
|---|---|---|---|
| D01 | Identical copy | certain | byte-for-byte equal (SHA-256) |
| D02 | Resized or re-saved copy | certain | copy test passes as-is, brightness Δ ≤ 8 |
| D03 | Rotated or mirrored copy | certain | copy test passes only after rotating/mirroring |
| D04 | Copy with borders added | likely | copy test passes only after trimming flat borders |
| D05 | Edited copy | likely | copy test passes, brightness Δ > 8 |
| D06 | Near-identical shot | likely | shot test passes, within 30 min, not screenshots, fine detail agrees |

**Copy test:** pHash distance ≤ 8 (of 63), brightness-pattern correlation
≥ 0.985, edge-pattern correlation ≥ 0.97, aspect ratio within 3% (5% with
borders).

**Shot test:** whole-frame comparison only (no rotation), pHash ≤ 4,
correlation ≥ 0.85, edge correlation ≥ 0.5, aspect within 3%.

A pair that passes the copy test is still D06 when it is a **blurry retake**
(less than 60% as sharp, same framing), or when **both files are first-hand
camera files of the same size** (not in a second-hand folder, not named like
a copy) taken within the shot window. Burst frames are separate shots even
when they're pixel-for-pixel alike.

**Fine-detail check (every D06 match, however it was reached):** both photos
are decoded again at 256 px and softened (σ 2.5 px); the sharper one is
blurred further to match the other's edge width; the two are aligned within
5% of the frame; and their detail (each minus its local average) must
correlate ≥ 0.90. Uses `detailAgreement` from the blurry photo scan
(`blurry_photos/retake.dart`).

| Code | Exclusion / guard |
|---|---|
| X01 | Brightness spread ≤ 5: blank photo. All black pocket shots look alike; the blank-photo scan reports them. |
| X02 | Narrower or shorter than 200 px: icon or sticker. |
| X03 | The decoder supports the format but can't decode this file: damaged; the unreadable-file scan reports it. |
| X04 | The device can't decode this format (RAW `.dng`, HEIC on desktop): only identical copies (D01) are checked. |
| G1 | Aspect ratio must match (after undoing rotation). Stops squashed look-alikes matching. |
| G2 | D06 needs both photos' times, within `shotTimeWindow`. A similar view on another day is a different moment. |
| G3 | Screenshots are never D06 shots of each other: same app layout, different content. |
| G4 | Complete linkage: a group only forms if every pair in it matches. |

## 5. Rules in detail

### D01 — Identical copy

- **How:** group image files by size. Same-size files are hashed on their
  first 64 KB, and if those match, on their full contents (SHA-256). Files
  of a unique size are never read for this.
- **Covers:** every image format, decodable or not; downloads saved twice
  (`(1)` names), backups.
- **Cost saver:** each identical set is decoded once, not once per copy.
- **Exclusions:** files under 4 KB (`exactMinBytes`); a set whose photo is
  blank, tiny or damaged is left out entirely.
- **Test area:** `Download/IMG_20260912_101500 (1).jpg`,
  `Backup/Weddings/DSC_0412.jpg`, `Backup/RAW/IMG_0001.dng`, two Timmy
  backups.
- **Mass scan:** only after a near-match and only for `jpg/png/heic/webp/bmp`;
  it misses identical RAW files entirely.

### D02 — Resized or re-saved copy

- **Signals:** copy test passes with no rotation and no border trimming;
  brightness changed by ≤ 8 on average.
- **Covers:** messaging-app copies (WhatsApp recompresses to ~1600 px or
  less), client/web exports, PNG↔JPEG conversions, re-saved screenshots,
  grayscale copies (the scan compares brightness only, §9).
- **Measured:** copies score pHash 0–2, correlation ≥ 0.996, edges ≥ 0.993,
  brightness Δ < 1.
- **Test area:** WhatsApp copy, PNG conversion, client web copy, JPEG copy
  of a screenshot.

### D03 — Rotated or mirrored copy

- **How:** turning a picture only swaps and sign-flips its DCT coefficients,
  so the hashes of all 8 orientations come from one DCT. The pair is then
  compared with one photo actually turned.
- **Covers:** copies rotated by an editor or by stripped EXIF orientation;
  mirrored selfies and album layouts.
- **Test area:** `Pictures/Edited/hike_rotated.jpg`,
  `Album/DSC_0412_mirror.jpg`.
- **Mass scan:** misses both.

### D04 — Copy with borders added

- **How:** rows and columns at each edge that are one flat colour matching
  the edge are trimmed, up to 35% per side. The picture inside is compared,
  with its own aspect ratio (5% tolerance).
- **Covers:** square posts with white/black bars (Instagram), letterboxed
  exports, framed prints.
- **Why likely:** borders are usually added on purpose for a post.
- **Test area:** `Pictures/Instagram/hike_square.jpg`.
- **Mass scan:** misses it (its square thumbnails squash the bars into the
  picture).

### D05 — Edited copy

- **Signals:** copy test passes (both correlations are immune to brightness
  and contrast) but average brightness differs by more than 8.
- **Measured:** +25 brightness / ×1.15 contrast gives correlation ≥ 0.996
  and brightness Δ ≈ 21.
- **Why likely:** the user made the edit on purpose; they may want the
  edited one.
- **Test area:** `Pictures/Edited/hike_brighter.jpg`.

### D06 — Near-identical shot

- **Signals:** shot test passes (§4), photos taken within 30 minutes, and
  neither is a screenshot. Also copy-level matches between first-hand
  same-size camera files or blurry retakes (§4). Then, for every D06
  match, the **fine-detail check** (§4) must pass.
- **Keeper:** the sharpest; among equally sharp shots, the first taken.
- **Measured (§7):** retakes and bursts up to ~1% movement are ≤ 4 pHash
  bits apart. Plain different receipts in the same layout are ≥ 6, but once
  camera softness and noise are added a few pairs come within 2–4 bits
  (13 of 1,770; e.g. receipts 155 vs 117: pHash 4, correlation 0.97, edges
  0.94) and pass the whole shot test. The fine-detail check separates
  them: different receipts agree 0.69–0.75, real retakes and bursts
  0.965–0.998.
- **Why the fine-detail check:** the 32×32 grid sees the paper, the table
  and the rows of text, not the words; two receipts taken within 30 minutes
  would otherwise be grouped and one suggested for deletion.
- **Why softened first:** two sharp shots are never aligned to a fraction
  of a pixel, and receipt text is only 2–3 thumbnail pixels tall. Without
  softening, a sharp retake moved 1.4% scored 0.879, too close to different
  receipts (up to 0.834); softening by σ 2.5 lifts retakes to ≥ 0.965 and
  drops different receipts to ≤ 0.752 (§7).
- **Why only D06:** D02–D05 already need edge correlation ≥ 0.97, which
  different receipts (≤ 0.96) don't reach, and small, recompressed copies
  score lower on fine detail (a 400 px copy: 0.925 unsoftened) so checking
  them would risk dropping real copies. Re-check if the copy thresholds are
  ever loosened.
- **Risks:** a user may want several burst frames; that's why this rule is
  `likely`. Bursts with more than ~1.5% camera movement often aren't
  matched (pHash 6–12). If the photos can't be decoded a second time the
  pair isn't grouped (`detailDiffers`).
- **Test area:** the food burst (three frames, two blurry) and the receipt
  retakes (one blurry, one moved); singles: two different receipts a minute
  later, the same view a week later, and two pairs of camera-sharp
  receipts that pass the shot test on layout alone (155/117, 152/156; noted
  as `detailDiffers`).
- **Mass scan:** it split the burst into two groups, put the week-later
  photo into one of them (and kept it), and missed the moved retake.

## 6. The keeper (K rules)

Applied in order; the first rule that separates the photos decides. This is
the DAT-34 "suggests the clearest version" behaviour, with DAT-22's blur
score represented by the sharpness measure.

| Code | Prefer | Why |
|---|---|---|
| K01 | Shot groups only: photos at least 80% as sharp as the sharpest | Ethan's "clearest version". Not used for copies: a small, heavily compressed copy *measures* sharper (JPEG block edges). |
| K02 | Most pixels | A copy can't hold more detail than its source. |
| K03 | Has EXIF camera details | Messaging apps and editors strip them. |
| K04 | Not in a second-hand folder (WhatsApp, Telegram, Download, Backup, Edited…) | Originals live in the camera folder. |
| K05 | Not named like a copy (`(1)`, `copy`, `-WA0001`, `_edited`) | Same. |
| K06 | Copies: largest file. Shots: earliest. | For copies, less compression. For equally sharp shots, file size mostly measures sensor noise, and the first frame is the one the user meant. |
| K07 | Earliest, then path | Deterministic. |

Every group says why its keeper was chosen, e.g. "highest resolution,
1600×1200, has camera details, original location".

## 7. Measurements behind the thresholds

All on synthetic photo-like scenes and receipts (`photo_factory.dart`),
decoded through the same pure-Dart path the scan uses.

| Change | pHash | Correlation | Edges | Brightness Δ |
|---|---|---|---|---|
| Resized 50%, JPEG q70 / PNG / q40 / grayscale | 0–2 | 1.000 | ≥ 0.997 | < 1 |
| Rotated 90° / mirrored | 0–2 | 1.000 | ≥ 0.999 | < 0.3 |
| White letterbox (trimmed) | 0–2 | 1.000 | 0.999 | 0.3 |
| +25 brightness, ×1.15 contrast | 2 | ≥ 0.996 | ≥ 0.993 | 21–22 |
| Gaussian blur r4 | 0–2 | ≥ 0.999 | ≥ 0.999 | < 1 (sharpness ÷2) |
| Burst, 1% movement + noise | 2 | 0.98 | 0.87–0.90 | 2–3 |
| Burst, 2% | 4–8 | 0.93–0.94 | 0.63–0.69 | 4–6 |
| Burst, 4% | 6–14 | 0.81–0.86 | 0.35–0.44 | 7–11 |
| Reframed 8% / 25% | 16–34 | 0.39–0.69 | ≤ 0.23 | 11–26 |
| Centre crop 80% | 18–20 | 0.62–0.69 | ≤ 0.16 | 12–17 |
| Different scene | 26–38 | ≤ 0.27 | ≤ 0.08 | 28–38 |

**Different receipts in the same layout** (the hard case): correlation
0.966–0.974 and edges 0.93–0.96, the same range as a moved retake, so
correlation can't separate them. pHash mostly does:

| Pairs | Best pHash distance |
|---|---|
| Receipt vs 100 different receipts | min 6 (3 of 100), then 8+, median 14 |
| Camera-sharp receipts (blur r1 + noise, `cameraSharp`), all 1,770 pairs of 60 | 13 pairs at 2–4: pass the whole shot test |
| Receipt vs 20 retakes (0–2% moved, some blurred) | 0–4 |
| Landscape bursts at 0.5 / 1 / 1.5 / 2 / 3% movement (6 scenes) | 0–2 / 2 / 2–6 / 4–8 / 4–12 |

Hence `shotHashDistance = 4`. Raising it to 6 catches more bursts, but
would have grouped 3 of the 100 different receipts. A unit test pins this
case.

The 13 camera-sharp pairs that slip through pHash are caught by the
**fine-detail check** (`detail.dart`, using the blurry scan's
`detailAgreement`). An earlier attempt (a shift search on the raw
thumbnails: different receipts 0.85, retakes 0.63) failed because it
neither removed the local average nor matched blur. Agreement of the pairs
that pass the shot test, at 256 px, by how much both photos are softened
first (σ, thumbnail pixels):

| Pairs (that pass the shot test) | σ 0 | σ 1 | σ 2 | **σ 2.5** | σ 3 |
|---|---|---|---|---|---|
| Different camera-sharp receipts (n=13) | 0.806–0.834 | 0.817–0.847 | 0.744–0.791 | **0.690–0.752** | 0.685–0.752 |
| Soft (r3) receipt vs different sharp one (n=13) | 0.809–0.837 | 0.818–0.848 | 0.743–0.791 | **0.689–0.752** | 0.686–0.753 |
| Receipt retakes, moved 0–2%, blur r0–4 (n=56 of 60) | 0.879–0.994 | 0.926–0.998 | 0.949–0.998 | **0.965–0.997** | 0.979–0.997 |
| Landscape bursts, 0.5–1.5% moved, blur r0–3 (n=45 of 54) | — | — | 0.984–0.996 | **0.985–0.997** | 0.984–0.997 |
| Test area D06 members (n=4) | 0.941–0.992 | | | **0.981–0.999** | |
| Test area look-alikes 155/117, 152/156 | 0.808–0.820 | | | **0.716–0.724** | |

Decoding at 512 px instead changes little (σ 0: retakes 0.879–0.995). The
lowest unsoftened retakes are sharp-vs-sharp, moved ~1.4%: misaligned by a
fraction of a pixel. σ 2.5 was chosen over 3 to keep some text detail in
the 6 px band the check compares; `shotDetailAgreement` 0.90 sits in the
gap (0.752 → 0.965), nearer the retakes since a missed shot only leaves a
photo in place.

## 8. Tuning knobs

All in `DuplicatePhotoRules` (`lib/src/duplicate_photos/rules.dart`).

| Knob | Default | Trade-off |
|---|---|---|
| `exactMinBytes` | 4 KB | Smaller files skip D01 (icons). |
| `exactPrefixBytes` | 64 KB | Prefix hashed before full hashing. |
| `analysisSize` | 256 | Decode size. Larger = better sharpness ranking, more memory in flight. |
| `minPhotoDimension` | 200 px | X02. |
| `blankMaxStdDev` | 5.0 | X01 (same as the mass scan's blank threshold). |
| `copyHashDistance` | 8 | Copy candidates. Higher = more pairs checked. |
| `copyCorrelation` / `copyEdgeCorrelation` | 0.985 / 0.97 | Copy test. Edges is what keeps different receipts apart. |
| `editedMinBrightnessDiff` | 8.0 | D02 vs D05. |
| `aspectTolerance` / `borderedAspectTolerance` | 3% / 5% | G1. |
| `shotHashDistance` | 4 | **Main precision/recall lever for D06** (§7). |
| `shotCorrelation` / `shotEdgeCorrelation` | 0.85 / 0.5 | Shot test. |
| `shotTimeWindow` | 30 min | G2. Longer groups slower retakes; risks grouping similar views. |
| `shotDetailAgreement` | 0.90 | **D06 precision guard** (§7). Lower = fewer missed shots, closer to different receipts (≤ 0.752). −1 switches the check off (no second decode). |
| `shotDetailBlur` | 2.5 | Softening before the detail check (σ, px of a 256 px thumbnail). Less = sharp retakes moved ~1.5% drop toward 0.88; more = only coarse layout left. |
| `shotDetailMaxShift` | 0.05 | How far (share of the frame) the detail check searches to align two shots. |
| `blurryRetakeSharpness` | 0.6 | Copy-level match below this sharpness ratio → D06. |
| `keepSharpnessShare` | 0.8 | K01 cut-off. |
| `borderMaxStdDev` / `borderMaxShare` | 6 / 35% | D04 border detection. |
| `secondhandFolders`, `screenshotFolders` | see code | K04, G3. |
| `maxClusterSize` | 200 | Bigger connected sets skip complete linkage. |
| `concurrency` | 4 | Photos decoded at once. |
| `minConfidence`, `disabledRules` | likely / none | CLI `--min-confidence`, `--disable D06`. |

## 9. Known gaps

| Gap | Notes |
|---|---|
| Cropped copies | A centre crop scores correlation 0.62–0.69: not matched. Needs a crop-search step. |
| Colour-only differences | Brightness only: a grayscale or recoloured copy is treated as a copy (D02). The keeper still prefers the original via K02–K05. |
| Heavy filters, stickers or text added | Fail the copy test; not matched. |
| Screenshot of a photo with UI around it | Not matched (borders aren't flat). |
| Bursts with > ~1.5% movement | Often missed (§7). Seen as `nearMiss` when close. |
| D06 relies on file times | Photos copied without keeping times lose their burst link. Copies are still found. |
| Fine-detail check is D06 only | D02–D05 rely on the copy thresholds to keep different receipts apart (§5 D06). Different documents in the same layout *copied* (e.g. resized) would need the check too, with a copy-aware threshold. |
| HEIC on desktop | Identical copies only (X04). Phones decode HEIC natively. |
| Videos, Live Photos, RAW+JPEG pairs | Not compared. |

## 10. Performance

Baseline on the test area (40 images, 30 distinct photos; Windows 11,
pure-Dart decoder, 4 decode threads):

| Stage | Cost |
|---|---|
| Identical-file hashing | 2.6 MB read, only for same-size files |
| Decoding | ~2.5 s summed across threads (about 720 ms per 12 MP JPEG in pure Dart; phones use native decoders) |
| Fingerprint | ~2.5 ms per photo (DCT, borders, sharpness) |
| Pair checks | 344 candidate pairs (of 435 possible) checked, 25 matched |
| Fine-detail check (D06) | 8 pairs; each photo decoded again (one at a time), then ~15 ms per pair (softening, edge width, alignment) |
| Wall time | ~1.5 s (~0.8 s with the detail check off) |

Decoding dominates; everything after it is small. Where to look when
optimising:

1. **Share decodes with the photo detectors.** The mass scan decodes every
   photo at 64 px for blank/duplicate checks. Decoding once at 256 px and
   deriving the 64 px features would remove a full decode per photo.
2. **Memory per photo.** Each view keeps a 32×32 `Float64` grid (8 KB) plus
   a DCT block. The normalised and edge grids are computed only for photos
   in a candidate pair. Storing grids as bytes would cut this to about
   1 KB.
3. **Time-window pairs** grow with photos per 30 minutes (a long burst is
   n²). Cap or band them if real libraries show it.
4. The candidate index is exact (pigeonhole on 9 bands of 7 bits): it finds
   every pair within 8 bits, so speeding it up must not drop pairs.
5. **Second decodes for the detail check** are sequential and almost all of
   its cost. Run them on the decode workers, or keep the 256 px thumbnail
   (64 KB) of photos in a time-window pair from step 2. Recently decoded
   photos are cached (up to 64).

## 11. Accuracy baseline

| Run | Deep scan | Mass scan (`DuplicatePhotoDetector`) |
|---|---|---|
| Test area: 8 groups, 25 photos | **8/8** groups exactly right (members, keeper, every rule) | 3/8 right members, 5/8 right keeper |
| Test area: 15 look-alikes | **15/15** kept apart (13/15 with the detail check off) | 14/15 |
| Pair precision / recall | **100% / 100%** | 95% / 49% |
| `scan_engine` sample phone | Same 2 groups as the mass scan | Keeps the brightened burst frame instead of the original |

Where the mass scan goes wrong on the test area: misses rotated, mirrored
and letterboxed copies and identical RAW files; splits the food burst and
groups the week-later photo with it (keeping that one); misses the moved
receipt retake; keeps the JPEG copy of a screenshot over the original PNG.

## 12. Merging into the mass scan

`DuplicatePhotoScan` runs through `ScanEngine` (same permission gate,
progress and `ScanReport`), and `DuplicatePhotoAnalyzer().detector()` is a
`WasteDetector` for the existing `duplicatePhoto` category, with `keep` set
on every finding. When it's time:

1. In `ScanEngine.defaultDetectors()`, replace `DuplicatePhotoDetector()`
   with `DuplicatePhotoAnalyzer().detector()`.
2. Share one decode per photo with `BlankPhotoDetector` (§10.1), and use the
   same blank threshold in both so X01 and the blank scan agree.
3. Let the UI show rule labels and pre-select only `certain` groups.
4. DAT-22: expose `sharpness` as the blur score. DAT-34: K01–K07 are the
   starting point.
5. Re-run the test area with `--compare` and update §11.

## 13. Changelog

| Version | Change |
|---|---|
| 1.0 | First ruleset: D01–D06, X01–X04, G1–G4, K01–K07; test area of 36 photos. |
| 1.1 | D06 fine-detail check (`detail.dart`; knobs `shotDetailAgreement`, `shotDetailBlur`, `shotDetailMaxShift`): different receipts in the same layout could pass D06 (e.g. 155 vs 117). New `detailDiffers` observation; `detailChecks` stat; test area gains four camera-sharp receipt look-alikes (40 photos). |
