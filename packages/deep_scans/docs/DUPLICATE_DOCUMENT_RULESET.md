# Duplicate Documents — Deep Scan Ruleset

| | |
|---|---|
| **Jira** | DAT-3 *Duplicate document / file detection (non-image)*, epic DAT-11 *Review & Triage UX* |
| **Related** | DAT-20 (empty & unreadable deep scan, used to leave broken files out), DAT-21 (duplicate photos: images are left to it; its matcher is reused for scanned pages) |
| **Ruleset version** | `1.0` (`duplicateDocumentRulesetVersion` in `lib/src/duplicate_documents/scan.dart`) |
| **Code** | `packages/deep_scans/lib/src/duplicate_documents/` |
| **Test area** | `dart run tool/make_duplicate_document_test_area.dart` → `test_area/duplicate_documents/` |
| **Status** | Standalone. `scan_engine` is unchanged; nothing in the mass scan looks for duplicate documents yet. |

This is the reference for every rule the duplicate document deep scan
applies, written for the later pass that tunes each scan for performance and
accuracy. Each rule lists what it compares, its thresholds and the
measurements behind them, what it can get wrong, and the knob that controls
it.

## 1. Where the requirements come from

- **DAT-3:** "Detect duplicate and near-duplicate documents and files that
  are not images — repeated scans, re-downloaded copies, and redundant saves
  of the same document."
  - *re-downloaded copies* → identical files (F01) and copies that an app
    re-saved on the way (F02).
  - *redundant saves of the same document* → the same text saved in another
    file or format (F03) and drafts saved as new files after small edits
    (F04).
  - *repeated scans* → scanned PDFs of the same paper (F05).
- **Ethan's scenario:** "dozens of duplicated document scans, pictures of
  receipts taken multiple times because of focus issues, and several empty
  files from failed downloads. The app groups together the duplicates and
  suggests the clearest version." → F05 with the clearest scan kept (K02).
  Photos of receipts stay with the duplicate photo scan. Empty files and
  failed downloads are the empty & unreadable scan's findings, and this scan
  must not group them as duplicates. It notes which healthy document each
  failed download was a copy of.
- **Ethan's user story:** "automatically find and remove duplicate
  documents so that I don't have to manually search through everything."
  → groups ranked by reclaimable space, each with one copy to keep.
- **Ethan's persona:** "Saves multiple copies of documents", "many of his
  clients' documents are useless copies". He also keeps many *different*
  documents made from one template: invoices, delivery notes, monthly
  manifests. They must never be grouped (G2, G3, F05 detail test).
- **Feature list, Garbage Collection:** the user bins what the scan
  selects, so a false match costs a real document. Wherever a threshold has
  to choose, it favours precision over recall.

## 2. What counts

A **duplicate group** is a set of non-image files where every file is the
same document as every other, with one suggested to keep. "Same document"
means one of:

- the same bytes (F01);
- the same content in a different wrapper: re-saved with new metadata,
  recompressed, re-zipped, or with other line endings or encoding (F02);
- the same text in another file: exported to PDF, re-saved by Word with new
  internal XML, or copied to Markdown (F03);
- an earlier or later draft with a few words changed (F04);
- another scan of the same paper (F05).

**Not duplicates:** different records from one template (invoices, delivery
notes, leases, monthly manifests); a document and its corrected version
when a reference number changed; short notes that happen to say the same
few words.

**Out of scope:** images (the duplicate photo scan), empty and unreadable
files (the empty & unreadable scan), re-encoded audio and video (§10).

## 3. How the scan works

```
non-image files (MediaKind ≠ image) that can be read
 1. leave out                                                    (§6)
      ├─ X01 empty / X02 unreadable   ← empty & unreadable deep scan verdicts
      ├─ X03 modified < 10 min ago    ← same scan's grace period
      ├─ X04 smaller than 64 bytes
      └─ X05 app and system files (Android/data, hidden files, desktop.ini…)
 2. identical files ─ same size → same first 64 KB → same SHA-256   (F01)
 3. look inside one file per identical set (whole file, ≤ 32 MB)
      ├─ PDF: streams inflated → content key; Tj/TJ text; one JPEG per page = scan
      ├─ docx/xlsx/pptx/odt/epub: part checksums → content key; document text
      ├─ txt/csv/md/html/json/…/rtf: normalised text → content key; words
      └─ anything else: identical copies only
 4. match
      ├─ same content key                                           (F02)
      ├─ same words, ≥ 20 of them                                   (F03)
      ├─ MinHash candidates → shingle similarity + guards G2–G4     (F04)
      └─ scans with the same page count → layout + detail test, G5 (F05)
 5. complete-linkage grouping: every member must match every other
 6. keeper: K01–K07; every other member labelled by its rule vs the keeper
 7. failed downloads: is a cut-off (U02/U03/U06) file the start of a healthy one?
```

The scan runs through `ScanEngine` together with the empty & unreadable
detectors, sharing one `EmptyUnreadableAnalyzer`, so the storage permission
gate applies and each file gets one health check. A file is in at most one
group. Groups are sorted by reclaimable space.

### Confidence

A group's confidence is its weakest member's:

| Level | Rules | Meaning |
|---|---|---|
| `certain` | F01, F02 | The same content, byte for byte or part for part. Safe to pre-select. |
| `likely` | F03, F04, F05 | The same document by its words or by how its pages look. Formatting, embedded images or a few words may differ. Show without pre-selecting. |

`minConfidence` drops members below a level; dropped members are recorded as
`dropped` observations.

### Observations

Files the scan looked at but didn't group, and near misses, so tuning can
see what almost happened:

| Kind | When |
|---|---|
| `empty`, `unreadable` | X01/X02, with the empty & unreadable rule code (`E01`, `U06`…). |
| `partialCopy` | A cut-off or unfinished file whose bytes are the start of a healthy document of the same type: "failed download of Invoice_0042.pdf". |
| `beingWritten` | X03. |
| `tooSmall`, `systemFile` | X04, X05. One observation lists every file of that kind. |
| `identicalOnly` | Over the 32 MB content limit; only F01 applies. |
| `noText` | A PDF or office file whose text can't be used (glyph-coded fonts); only F01/F02 apply. |
| `scanUndecodable` | A scan page that won't decode; F05 doesn't apply. |
| `nearMiss` | A pair came close. The note says why it didn't match, e.g. "similar text, but different reference numbers (77410 vs 77209)". |
| `split` | A chain of matches (A~B~C, but not A~C) was split into groups. |
| `dropped` | A rule is disabled, or a member is below `minConfidence`. |

## 4. Rules at a glance

| Code | Rule | Confidence | Test (vs the document kept) |
|---|---|---|---|
| F01 | Identical copy | certain | byte-for-byte equal (SHA-256) |
| F02 | Re-saved copy | certain | same content key (format-specific, below) |
| F03 | Same text in another file | likely | same normalised word sequence, ≥ 20 words |
| F04 | Lightly edited version | likely | 5-word shingle similarity ≥ 0.85, lengths within 80%, ≥ 40 words, related names, same reference numbers |
| F05 | Repeated scan | likely | scanned PDFs with the same page count, made within 24 h of each other; every page passes the layout test and the detail test (worst tile Δ ≤ 0.16) |

When a pair matches under several rules, the first in this order is
reported. A member's rule always describes its relation to the **keeper**,
not to whichever member it was linked through.

## 5. Rules in detail

### F01 — Identical copy

- **Signal:** same size, then SHA-256 of the first 64 KB, then SHA-256 of
  the whole file. Only same-size files are ever read.
- **Applies to:** every non-image file that passed §6, documents or not
  (archives, audio, video, unknown types).
- **Scenarios:** a re-downloaded invoice, "Report - Copy.docx", a
  recording WhatsApp keeps a copy of.
- **Can go wrong:** never on content. Whether the copy is wanted is the
  keeper's job (K04/K05).
- **Knobs:** `prefixBytes`, `minBytes` (X04).

### F02 — Re-saved copy

The same content in a different wrapper. The **content key** depends on the
format:

| Format | Key built from | Ignored |
|---|---|---|
| PDF | every stream, Flate-inflated, in file order, plus the page count | the info dictionary (producer, dates), `/ID`, XMP `/Metadata` and `/XRef` streams, object numbers and offsets, compression |
| Office (docx, xlsx, pptx, odt/ods/odp, epub) | sorted list of `name | CRC-32 | size` from the ZIP directory | `docProps/*`, `meta.xml`, `settings.xml`, `word/settings.xml`, `xl/calcChain.xml`, thumbnails, ZIP timestamps and compression level |
| Text (txt, csv, tsv, json, xml, html, md, log, srt, vcf, ics, svg) | decoded text | UTF-8/UTF-16 byte-order marks, CRLF/CR line ends, trailing spaces, trailing blank lines |
| RTF | source text | line ends, trailing spaces |

- **Scenarios:** an invoice re-saved by WhatsApp with its own ids and
  producer; a contract re-saved by a viewer that stores pages
  uncompressed; a report re-zipped by an email app; notes received over
  Bluetooth from Windows (BOM, CRLF).
- **Can go wrong:** an office part that holds real content but changes on
  every save would make copies look different (a miss, not a false match).
  A PDF that keeps its info dictionary inside an object stream changes its
  key with the dates; F03 still catches it when it has text.
- **Cost:** office keys need only the ZIP directory, nothing is inflated.
  PDF keys inflate every Flate stream up to `partMaxBytes` (8 MB each).

### F03 — Same text in another file

- **Signal:** the documents' words are identical in order, after lower-casing
  and removing punctuation, symbols and layout (`wordsOf`).
- **Guard G1:** at least `minTextWords` (20) words. Two notes saying "ok,
  thanks" aren't the same document.
- **Text sources:** PDF `Tj`, `TJ`, `'`, `"` strings (TJ gaps ≤ −200 are word
  breaks); docx `<w:t>` runs per paragraph (Word splits words across runs);
  xlsx shared strings and cell values in sheet order; pptx `<a:t>` per slide
  in slide order; ODF `content.xml`; epub (X)HTML parts; HTML/XML visible
  text; RTF with control words removed.
- **Scenarios:** a report and its PDF export; the same report after Word
  rewrote its XML; meeting notes copied into Markdown.
- **Why `likely`:** formatting, embedded images and anything that isn't
  text are not compared. A signed contract and the unsigned one with the
  same text look the same.

### F04 — Lightly edited version

- **Signal:** Jaccard similarity of the sets of overlapping 5-word runs
  (shingles) ≥ `versionMinSimilarity` (0.85).
- **Candidates:** MinHash signatures (16 bands × 4 rows). A pair at 0.85
  becomes a candidate with probability 1 − (1 − 0.85⁴)¹⁶ ≈ 99.9999%. A pair
  at 0.3 does with about 12%. Only candidates get the exact comparison.
- **Guards:**
  - **G1** both have ≥ `minVersionWords` (40) words. One edit in a short
    text changes too large a share of its shingles to measure.
  - **G2 related names:** one file name's stem contains the other's, after
    removing the extension, copy and version words (final, draft, v3, copy,
    rev, updated…) and 1–2 digit numbers. "Shipping manifest" ~
    "Shipping manifest final v3"; "Lease - Smith" ≁ "Lease - Jones".
  - **G3 same reference numbers:** words with four or more digits (invoice,
    order, consignment and booking numbers, years). If each document has one
    the other lacks, they're different records from one template, not
    versions.
  - **G4 similar length:** the shorter has ≥ 80% of the longer's words.
- **Scenario:** a manifest saved as "…", "… final", "… final v3" after
  one-word edits. The newest version is kept (K01).
- **Can go wrong:** drafts that change a reference number or date are kept
  apart by G3 (a miss). A draft renamed to something unrelated is kept apart
  by G2 (a miss). Two different documents with related names, the same
  numbers and ≥ 85% the same wording would be grouped. This is why the rule
  is `likely`.

### F05 — Repeated scan

- **Which PDFs are scans:** every page is one JPEG (`/DCTDecode`) image of
  at least 300 × 300 px, and there are at most 50 pages. Pages are paired by
  image order in the file. Scanner apps write one image per page, in order.
- **Signal, page by page (same page count required):**
  1. **Layout test:** the duplicate photo scan's copy or shot test (D02–D06,
     `comparePhotos`) on the 32 × 32 fingerprint, with no time window. This
     cheaply rejects unrelated pages.
  2. **Detail test:** both pages are decoded at 512 px and contrast-stretched
     (2nd–98th percentile). They are aligned by whole pixels at 128 px
     (±5% of the page), refined to a quarter pixel there, and compared at
     256 px in tiles 1/24 of the page across. The most different tile may
     differ by at most `scanMaxTileDifference` (0.16 mean brightness, 0–1).
- **Guard G5, time window:** the scans must have been made (last modified)
  within `scanTimeWindow` (24 h) of each other, like the photo scan's
  30-minute window for near-identical shots. Rescans because of focus
  happen minutes apart. Next week's delivery note for the same goods
  differs only in its numbers, and the detail test can't see those (§8).
  Pairs that pass both tests but fail G5 are recorded as near misses ("pages
  match, but scanned 7 days apart").
- **Why two tests:** the layout test alone matched two *different* delivery
  notes in the same layout as re-saved copies (pHash 2, correlation 0.989,
  edges 0.971, §8). Text is too fine for a 32 × 32 grid.
- **Scenarios:** Ethan's delivery note scanned, rescanned out of focus, and
  scanned again at another desk that afternoon (kept: the clearest, K02); a
  two-page customs declaration rescanned and sent over Bluetooth.
- **Can go wrong:** see §10. Two different papers with the same wording and
  different numbers, scanned the same day, are grouped. Very blurry rescans
  are missed, and there's no deskew.

## 6. Exclusions (X rules)

| Code | Left out | From | Why |
|---|---|---|---|
| X01 | Empty files (E01–E05) | empty & unreadable deep scan | Two empty files are both waste, not one copy of the other. They're reported as empty. |
| X02 | Unreadable files (U01–U09) | same | A broken copy is never the one to keep, and it's waste whatever it duplicates. A cut-off copy is linked to its original by a `partialCopy` note (§3 step 7). |
| X03 | Modified within the grace period (10 min) | same scan's `recentlyModified` | It may still be downloading. It is judged once the grace period has passed. |
| X04 | Smaller than `minBytes` (64 bytes) | — | Markers and one-line settings; nothing to reclaim. |
| X05 | App and system files: paths containing `android/data/` or `android/obb/`, hidden files (name starts with `.`), `desktop.ini`, `thumbs.db`… | `ignoredFolders`, `ignoredNames` | Two apps' identical config files are not waste. Removing one breaks the app. |

Images (`MediaKind.image`) are not considered at all. They belong to the
duplicate photo scan, whose decoder, thresholds and keeper are built for
them.

**Failed-download link:** for a U02/U03/U06 file of at least 64 bytes, the
first min(size, 64 KB) bytes are compared with those of larger healthy files
of the same type. For `x.docx.crdownload` the type is `.docx`. At most 50
candidates are tried: related names first, then originals (not second-hand,
not named as a copy), then by path. The first match is reported.

## 7. The keeper (K rules)

| Code | Applies to | Prefers |
|---|---|---|
| K01 | version groups (any F04 link) | the newest (last modified): the latest edit |
| K02 | scan groups (any F05 link) | scans at least 80% as sharp as the sharpest (average Laplacian variance of the pages), then most pixels |
| K03 | all | only healthy files are candidates (X01–X03 already removed broken ones) |
| K04 | all | not in a second-hand folder (Download, WhatsApp, Telegram, Bluetooth, Sent, Backup…) |
| K05 | all | not named like a copy: `(1)`, `copy`, `duplicate` |
| K06 | all | oldest: the original |
| K07 | all | path, so results don't depend on listing order |

The keep reason shown to the user is built from the steps that decided it
("clearest scan, original location", "newest version", "not named as a
copy"), or "oldest copy" when nothing else differed.

## 8. Measurements behind the thresholds

From the test area (§12) and the pages in
`lib/src/testing/document_factory.dart`. F05 numbers are at the default
512 px analysis size.

**F04 (shingle similarity, 274-word manifest):**

| Pair | Similarity | Outcome |
|---|---|---|
| one word changed | 0.964 | F04 |
| two words changed | 0.929 | F04 |
| same wording, consignment and booking numbers changed (4 words) | 0.882–0.949 | blocked by G3 |
| lease template, other tenant (176 words) | 0.792 | below 0.85, and blocked by G2 |

With k = 5, each changed word removes up to 5 shingles, so an n-word text
with c scattered edits scores about (n − 5c) / (n + 5c). The 0.85 threshold
allows about 4 scattered edits in 274 words, and about 1 in 80 (the
40-word minimum keeps short texts out).

**F05 layout test alone (32 × 32 photo fingerprint, delivery-note page):**

| Pair | Photo rule | pHash / correlation / edges |
|---|---|---|
| rescan, shifted 1% | D02 | 0 / 0.992 / 0.981 |
| **different delivery note, same layout** | **D02 (wrong)** | 2 / 0.989 / 0.971 |
| another different note | D06 (wrong) | 4 / 0.982 / 0.959 |

**F05 detail test (worst tile Δ after alignment; 850 × 1100 page, JPEG
quality 82):**

| Pair | Worst tile | Outcome |
|---|---|---|
| rescans, shifted 0.4–2%, ±25 brightness, noise | 0.032–0.093 | match |
| rescan out of focus (Gaussian blur 2) | 0.097–0.103 | match |
| rescan out of focus (blur 3) | 0.157 | match (thin margin) |
| rescan very out of focus (blur 5) | 0.278 | **missed** |
| same note, last line corrected | 0.169–0.173 | kept apart (thin margin) |
| different goods, same layout | 0.204–0.292 | kept apart (most fail the layout test first) |
| same goods, every digit different | 0.126–0.150 | **passes**: kept apart only by G5 |
| reference number one digit different | 0.033 | **passes**: kept apart only by G5 |

Comparing at the full 512 px instead of 256 doesn't help: rescans rise to
0.099–0.122 from sub-pixel misalignment, while "every digit different"
only reaches 0.149. Other rejected alternatives, measured on the same
pages: ink-mask agreement (different notes 0.97–0.99, no separation);
unaligned tile difference at 96–192 px (sub-pixel misalignment alone
reached 0.59); blurring the sharper page to match the blurrier one (did not
lower the blurred rescans' scores).

## 9. Tuning knobs

All in `DuplicateDocumentRules` unless noted:

| Knob | Default | Trade-off |
|---|---|---|
| `minBytes` | 64 | X04. Lower finds more tiny copies, saves nothing. |
| `prefixBytes` | 64 KB | F01 first pass; also the failed-download comparison length. |
| `contentMaxBytes` | 32 MB | Larger files get F01 only. Memory per file in flight. |
| `partMaxBytes` | 8 MB | Largest PDF stream / ZIP part inflated (compression-bomb guard). |
| `minTextWords` | 20 | G1 for F03. |
| `minVersionWords` | 40 | G1 for F04. |
| `shingleWords` | 5 | Larger is stricter per edit. |
| `versionMinSimilarity` | 0.85 | F04 threshold (§8). |
| `versionMinLengthRatio` | 0.8 | G4. |
| `nearMissSimilarity` | 0.6 | Logs near misses only. |
| `minHashBands` × `minHashRows` | 16 × 4 | Candidate recall vs pairs compared. |
| `minLetterShare` | 0.75 | Below this, extracted text is glyph codes (`noText`). |
| `minScanPageSide` | 300 px | Images smaller than this aren't pages (logos, stamps). |
| `maxScanPages` | 50 | Longer scans skip F05. |
| `scanAnalysisSize` | 512 | Page decode size. 256 can't separate different notes. |
| `scanMaxTileDifference` | 0.16 | F05 detail threshold: the main precision/recall dial (§8). |
| `scanMaxShift` | 5% | Alignment search range. Cost grows with its square. |
| `scanTimeWindow` | 24 h | G5. Longer finds rescans made days later, but groups same-wording records with different numbers. |
| `keepSharpnessShare` | 0.8 | K02 cut-off. |
| `secondhandFolders` | see code | K04. |
| `ignoredFolders`, `ignoredNames` | see code | X05. |
| `maxClusterSize` | 200 | Larger connected sets skip complete linkage. |
| `partialCopyCandidates` | 50 | Failed-download check reads. |
| `minConfidence`, `disabledRules` | likely / none | CLI `--min-confidence`, `--disable F05`. |
| `DuplicateDocumentScan.scanPageRules` | `DuplicatePhotoRules()` | F05 layout test thresholds. |
| `DuplicateDocumentScan.healthRules` | `EmptyUnreadableRules()` | X01–X03, including the grace period (CLI `--grace-minutes`). |

## 10. Known gaps

| Gap | Notes |
|---|---|
| Scans differing only in numbers | Same wording with different quantities, prices or reference numbers measures 0.03–0.15, the same as a rescan. Only G5 keeps them apart, so two such papers scanned the same day are grouped. Rescans made more than 24 h apart are missed. Telling them apart properly needs OCR. F05 is `likely`, so these groups aren't pre-selected. |
| Thin F05 margins | Blur-3 rescan 0.157 vs corrected line 0.169 against a 0.16 limit. Re-measure on real phone scans first. |
| Very blurry, rotated or perspective-skewed rescans | No deskew or perspective correction; blur ≥ 5 is missed. |
| Scan page order | Pages are paired by image order in the file, not by walking the page tree. |
| A scan vs a photo of the same paper | Not compared: photos are left to the photo scan. |
| A scanned PDF vs the typed original | No OCR, so no text to compare. |
| PDF text | Only literal and hex strings in content streams. Glyph-coded (CID/Identity-H) fonts give `noText`. Encrypted PDFs give no text and a key over encrypted streams. Text inside form XObjects is read only when its stream is a plain content stream. |
| PDF incremental updates | An appended annotation adds a stream, so it's not F02. F03 still matches if the text is unchanged. |
| Legacy .doc/.xls/.ppt (OLE) | F01 only. |
| Embedded images in office files | Not compared; part of why F03 is `likely`. |
| xlsx | Text is shared strings plus cell values; formulas and formatting are ignored. |
| Re-zipped plain archives | A .zip rebuilt from the same files is a miss (F01 only). The office ZIP-directory key could extend to archives. |
| Re-encoded audio/video | F01 only. |
| F04 guards | Drafts that change a ≥4-digit number or are renamed to something unrelated are missed. |
| Legacy-codepage text | Decoded as UTF-8 with replacement characters, consistently across copies, so F02/F03 still work between copies. |

## 11. Performance

Baseline on the test area (59 non-image files, 35 distinct documents;
Windows 11, pure-Dart JPEG decoding):

| Stage | Cost |
|---|---|
| Empty & unreadable checks (shared with that scan) | ~160 ms |
| Identical-file hashing | 118 KB read, only for same-size files and failed-download checks |
| Looking inside documents | 1.2 MB read (whole files), 23 KB inflated |
| F04 | 22 MinHash candidate pairs compared exactly |
| F05 | 12 scan pages decoded at 512 px; 18 scan pairs with equal page counts compared |
| Wall time | ~1.8 s, of which ~1.7 s is F05. With `--disable F05`: ~110 ms |

Where to look when optimising:

1. **F05 decoding** dominates. Pages are decoded one at a time; decode them
   concurrently like the photo scan does. On phones, pass the platform's
   native decoder as `pageDecoder`.
2. **F05 alignment** is (2r+1)² coarse positions on a 128 px grid plus 49
   quarter-pixel refinements, each with a 4× downsample. Caching the
   downsampled copies per page and skipping the refine when the coarse
   difference is already high would cut most of it.
3. **Memory:** each scan page keeps a 512 × 512 byte image (256 KB) for the
   whole run. For hundreds of scanned pages, keep only candidate pages, or
   store 256 px copies and accept less detail.
4. **Whole-file reads** for documents up to 32 MB. PDFs could be streamed
   stream by stream; office files only need the directory plus the text
   part.
5. MinHash costs 64 hashes × shingles per document. It's negligible here
   and grows linearly.

## 12. Accuracy baseline

| Run | Deep scan | Mass scan |
|---|---|---|
| Test area: 11 groups, 31 files | **11/11** groups exactly right (members, keeper, every rule) | No duplicate-document detector: 0 groups |
| Test area: 19 look-alikes | **19/19** kept apart | — |
| Test area: 11 empty / unreadable / in-progress documents | **11/11** right rule, failed-download link and never grouped | `EmptyFileDetector` / `UnreadableFileDetector` find a subset (see the empty & unreadable ruleset) |
| Pair precision / recall | **100% / 100%** | — |

### What the test area holds

`dart run tool/make_duplicate_document_test_area.dart` writes
`test_area/duplicate_documents/files/` (a fake phone) and `expected.json`.

| Group | Members (rule vs keeper) | Tests |
|---|---|---|
| invoice 0042 (Ethan) | 2 re-downloads F01, WhatsApp re-save F02 | K04, F02 on PDF metadata |
| service agreement re-saved | uncompressed re-save F02 | F02 after inflating |
| Q3 logistics report | "- Copy" F01, re-zipped F02, Word rewrite F03, PDF export F03 | office key, F03 across formats, K05 |
| shipping manifest drafts | two earlier drafts F04 | F04, K01 newest |
| delivery note rescans (Ethan) | out-of-focus F05, rescan elsewhere F05 | F05, K02 clearest |
| customs declaration rescan | 2-page rescan F05 | multi-page F05 |
| meeting notes | BOM/CRLF copy F02, Markdown copy F03 | text key, F03 |
| customs form without readable text | F01, re-save F02 | `noText`, F02 still works |
| receipts archive, client call recording, rate sheet | F01 each | non-document files |

**Look-alikes (must stay apart):** invoices 0043/0044 from the same
template; the Q2 report; next month's manifest (G3); two leases (G2); a
different delivery note and a corrected one (F05 detail); next week's note
for the same goods with every number changed (G5); a two-page scan whose
second page differs; unrelated and short notes (G1); identical 9-byte
files (X04); identical app configs under `Android/data` (X05); identical
photos (left to the photo scan).

**Empty / unreadable / in progress (must be left out, with the right
rule):** two 0-byte "New Text Document" files (E01), whitespace-only notes
(E02), a header-only CSV (E03), a PDF with no pages (E05), a cut-off invoice
download (U06 + failed download of Invoice_0042.pdf), an unfinished
`.docx.crdownload` (U03 + failed download of the Q3 report), two identical
sign-in pages saved as .pdf (U05, not a group), a zero-filled PDF (U04),
and an invoice still downloading (`beingWritten` for 10 minutes, then U06 +
failed download). The CLI and tests check the last one on both sides of the
grace period.

## 13. Merging into the mass scan

`DuplicateDocumentScan` already runs through `ScanEngine` (same permission
gate, progress and `ScanReport`), and `DuplicateDocumentAnalyzer.detector()`
is a `WasteDetector`. When it's time:

1. **Add a category** to `scan_engine`:
   `duplicateDocument('Duplicate documents')` in `WasteCategory`. Until then
   the standalone scan files its groups under `documentCategoryStandIn`
   (`duplicatePhoto`, which nothing else in that engine run uses). Replace
   it with the new category.
2. In `ScanEngine.defaultDetectors()`, create one `EmptyUnreadableAnalyzer`
   and pass it both to its detectors and to
   `DuplicateDocumentAnalyzer(health: …).detector(WasteCategory.duplicateDocument)`,
   so each file gets one health check.
3. UI: pre-select only `certain` groups. Show `partialCopy` notes next to
   the matching unreadable-file finding ("failed download of …").
4. Phones: pass the platform decoder as `pageDecoder` (§11.1).
5. Re-run the test area and update §12.

## 14. Changelog

| Version | Change |
|---|---|
| 1.0 | First ruleset: F01–F05, X01–X05, G1–G5, K01–K07, failed-download links; test area of 61 files (11 groups, 19 look-alikes, 11 empty/unreadable/in-progress). |
