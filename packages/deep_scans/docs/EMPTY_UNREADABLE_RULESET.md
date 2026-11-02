# Empty & Unreadable Files — Deep Scan Ruleset

| | |
|---|---|
| **Jira** | DAT-20 (PB-05 *Empty and unreadable file detection*), epic DAT-8 *Scanning & Detection* |
| **Depends on** | PB-03 classification ruleset (DAT-16) |
| **Ruleset version** | `1.0` (`emptyUnreadableRulesetVersion` in `lib/src/empty_unreadable/scan.dart`) |
| **Code** | `packages/deep_scans/lib/src/empty_unreadable/` |
| **Test area** | `dart run tool/make_empty_unreadable_test_area.dart` → `test_area/empty_unreadable/` |
| **Status** | Standalone. The mass scan (`scan_engine`) is unchanged. |

This document is the reference for every rule the empty & unreadable deep scan
applies. It's meant for the later pass where each scan feature is tuned for
performance and accuracy, so each rule lists its signals, its confidence, what
it can get wrong, what it costs and which knob controls it.

## 1. Where the requirements come from

- **Project description:** DataMuncher "will search users' storage for
  arbitrary data (empty files, unreadable files, …)". The Scanning engine in
  the layered architecture detects "empty/unreadable files".
- **Ethan scenario:** the scan finds "several empty files from failed
  downloads". Failed downloads are the main real-world source, so download
  failure modes (0-byte files, temp extensions, pre-allocated files that
  stopped filling, error pages saved under the file's name) get dedicated
  rules.
- **DAT-20:** "Detect empty files and files that cannot be read, and surface
  them as reclaimable."
- **Feature list:** results feed Garbage Collection, so a false positive
  means a user may bin a good file. Rules that can misfire are marked
  `likely`, not `certain` (see §3).

## 2. What counts

**Empty** — the file takes up an entry in storage but holds nothing the user
could want: no bytes, only blank space, or a valid container with nothing in
it (an archive with no files, a recording with no sound, a CSV with no rows).

**Unreadable** — the file holds data, but the app it belongs to can't open
it: it can't be read at all, the download never finished, the content isn't
what the name says, it's cut off, its internal structure is damaged, or it's
garbled.

**Out of scope** (see §9 for reasons):
empty folders; password-protected / encrypted files; iOS photo-library assets
(their raw bytes aren't readable); hidden files and folders (the device source
skips names starting with `.`); symbolic links.

## 3. How a file is judged

Each file gets **at most one finding**: the first rule that matches, in this
order. Checks are ordered cheapest-first, so most files are decided from the
listing or the first 4 KB.

```
listing (name, size, modified)
 ├─ E01  0 bytes?                                   no read
 ├─ U03  temporary download name?                   no read
read first 4 KB (whole file if ≤ 64 KB)
 ├─ U01  read failed?
 ├─ U02  fewer bytes than the listed size?
 ├─ E02  ≤ 4 KB and only blank space?
 ├─ U04  start blank → sample middle + end; all blank?
 ├─ text types ── U09 garbled? → E02 blank? → E03 no entries? (+ JSON U06/U07)
 ├─ unknown types ── stop (only U01–U04 apply)
 ├─ U05  signature doesn't match the extension?
 │        └─ really another known format → note "misnamed", check as that
 ├─ format structure ── E04 / E05 / U06 / U07
 └─ U08  photo fails a full decode?                 slowest, last
```

### Confidence

| Level | Meaning | Use |
|---|---|---|
| `certain` | Provably empty or unusable (0 bytes, checksum failure, signature mismatch, structure runs past the end of the file). | Safe to pre-select for the garbage bin. |
| `likely` | Strong signs, but a rare legitimate file could look the same (a CSV that is only headings, an Ogg without an end marker). | Show, but don't pre-select. Prime candidates for accuracy tuning. |

`EmptyUnreadableRules.minConfidence` drops findings below a level. Dropped
findings are kept as `suppressed` observations so tuning can see them.

### Files still being written (grace period)

A file being downloaded, recorded or saved right now starts at 0 bytes, is
then partly filled, and gets its end markers last — so for a few minutes it
looks exactly like a failed one. If a file was modified within
`recentlyModifiedGrace` (default **10 min**) and the matching rule is one
such a file could trigger, the finding is held back and recorded as a
`recentlyModified` observation saying what it *would* be.

Held back: **E01, E02, E05, U02, U03, U04, U06, U08** (`graceRules`).
Applied straight away: **E03, E04, U01, U05, U07, U09** — a web page saved as
a PDF, or a ZIP with a broken checksum, won't fix itself.

### Observations (not findings)

| Kind | When |
|---|---|
| `recentlyModified` | A grace rule matched a file modified within the grace period. |
| `misnamed` | Content is a different, valid format (a PNG named `.jpg`). Most apps sniff content and open these fine, so they're validated as their real format instead of being flagged. |
| `deepChecksSkipped` | File is over `fullReadMaxBytes`; only the cheap checks ran. |
| `suppressed` | A rule matched but was disabled or below `minConfidence`. |

## 4. Rules at a glance

| Code | Category | Rule | Confidence | Reads |
|---|---|---|---|---|
| E01 | Empty | Zero-byte file | certain | none |
| E02 | Empty | Only blank content | certain | ≤ 4 KB (text: ≤ 1 MB) |
| E03 | Empty | Document with no entries or text | likely (certain for all-empty CSV) | ≤ 1 MB |
| E04 | Empty | Archive with nothing in it | certain / likely | end of file + directory |
| E05 | Empty | Media with no content | certain (PDF: likely) | header, box/chunk headers |
| U01 | Unreadable | Cannot be opened | certain | first read |
| U02 | Unreadable | Data shorter than reported size | certain | any read |
| U03 | Unreadable | Unfinished download | certain | none |
| U04 | Unreadable | Zero-filled | certain (unknown types: likely) | 3 × 4 KB samples |
| U05 | Unreadable | Contents don't match the type | certain | first 4 KB |
| U06 | Unreadable | Cut off / unfinished | certain / likely by format | end of file, sometimes whole file |
| U07 | Unreadable | Internal structure damaged | certain / likely by format | whole file (PNG), directory (ZIP) |
| U08 | Unreadable | Image won't decode | certain | full decode |
| U09 | Unreadable | Garbled text | certain (binary) / likely | first 4 KB, whole text ≤ 1 MB |

## 5. Rules in detail

Each rule lists: **what it matches**, **exclusions**, **risks** (how it could
be wrong), **test area** examples, **knobs**, and how it differs from the
**mass scan** (`EmptyFileDetector` / `UnreadableFileDetector` in
`scan_engine`).

### E01 — Zero-byte file

- **Matches:** listed size is 0.
- **Exclusions:** names in `ignoredEmptyFileNames` (`.nomedia`, `.gitkeep`,
  `.keep`) and extensions in `ignoredEmptyExtensions` (`lock`): these exist
  on purpose.
- **Risks:** a 0-byte file some app uses as a flag that isn't on the
  exclusion lists. Grace period covers files being created right now.
- **Test area:** `empty/Invoice_0042.pdf`, `empty/podcast_episode_12.mp3`,
  `empty/New Text Document.txt`; must not flag `healthy/app.lock`.
- **Mass scan:** same, but flags `.lock` files.

### E02 — Only blank content

- **Matches:** file ≤ `blankContentMaxBytes` (4 KB) containing only spaces,
  tabs, newlines, zero bytes and byte-order marks. Text-type files up to
  `structuredTextMaxBytes` (1 MB) whose decoded text is all whitespace.
- **Understands:** UTF-8 BOM, UTF-16 LE/BE BOM with whitespace code units.
- **Risks:** low. A ≤ 4 KB all-zero file of a binary format is reported here
  rather than as U04; both are waste.
- **Test area:** `blank_note.txt`, `utf16_blank_note.txt`, `zero_padding.dat`,
  `long_blank_page.txt` (8 KB of spaces).
- **Mass scan:** misses UTF-16 blank text and blank text over 4 KB.

### E03 — Document with no entries or text

Only for structured text types, ≤ 1 MB.

| Type | Empty when | Confidence |
|---|---|---|
| JSON | value is `{}`, `[]`, `null` or `""` | likely |
| CSV / TSV | every row is delimiters, quotes, whitespace | certain |
| CSV / TSV | one row and it has no digits (column headings only) | likely |
| HTML | no visible text outside `<head>`/`<script>`/`<style>`, and no `img`/`video`/`iframe`/`svg`/`canvas`/form elements | likely |
| XML | at most one element and no text | likely |
| SVG | no shape/text/image elements | likely |
| vCard | no FN/N/TEL/EMAIL/ADR/ORG/NOTE/URL/PHOTO value | likely |
| iCalendar | no VEVENT/VTODO/VJOURNAL/VFREEBUSY | likely |
| SRT | no `-->` timing line | likely |

- **Risks:** app config files that are legitimately `{}`; CSV templates that
  are only headings; HTML pages built entirely by JavaScript. All `likely`.
- **Test area:** 9 files in `empty/`; look-alikes `healthy/readings.csv` (one
  row of numbers), `healthy/gallery.html` (only an image),
  `healthy/events.json` (line-delimited JSON).
- **Mass scan:** not covered.

### E04 — Archive with nothing in it

| Format | Empty when | Confidence |
|---|---|---|
| ZIP | central directory lists 0 entries | certain |
| ZIP | every entry is 0 bytes (only folders / empty files) | likely |
| 7-Zip | next-header offset and size are both 0 | certain |
| gzip | footer says 0 bytes and file < 1 KB (footer is size mod 2³²) | certain |

- **Exclusions:** ZIP-based *documents* (`docx`, `xlsx`, `pptx`, `odt`,
  `ods`, `odp`, `epub`, `apk`, `jar`) with 0 entries are U07 (broken
  document), not E04. A ZIP misnamed as something else is treated as an
  archive.
- **Test area:** `empty_archive.zip`, `folders_only.zip`, `logs.gz`,
  `empty.7z`.
- **Mass scan:** not covered (it accepts empty ZIPs as valid).

### E05 — Media with no content

| Format | Empty when | Confidence |
|---|---|---|
| WAV | `data` chunk is 0 bytes and nothing follows | certain |
| MP4 / MOV / M4A / 3GP | no `mdat` payload and no `moof` fragments | certain |
| MP3 | ID3 tag runs to the end of the file (tag only, no audio) | certain |
| PDF (≤ 1 MB) | page tree `/Count 0`, no `/Type /Page` objects, no compressed object streams | likely |

- **Risks:** PDFs whose page objects are in compressed object streams are
  skipped rather than misjudged.
- **Test area:** `silent_recording.wav`, `VID_20260921_090000.mp4`,
  `song_tag_only.mp3`, `scan_no_pages.pdf`.
- **Mass scan:** reports the MP4 as "missing its index" when `moov` is also
  absent; misses the rest.

### U01 — Cannot be opened

- **Matches:** the storage source throws when reading (permission denied,
  I/O error, file vanished).
- **Test area:** `locked_statement.pdf`, only created where `chmod` works and
  the user isn't root (not on Windows). Always covered by unit tests.
- **Mass scan:** same.

### U02 — Data shorter than reported size

- **Matches:** a read returns fewer bytes than the listed size promised: a
  file truncated after listing, or a cloud placeholder whose data isn't on the
  device.
- **Test area:** can't be planted on disk; covered by unit tests with a
  source that reports inflated sizes.
- **Mass scan:** not covered.

### U03 — Unfinished download

- **Matches:** extension in `partialDownloadExtensions`: `crdownload`
  (Chrome), `part` (Firefox), `partial`, `download` (Safari), `opdownload`
  (Opera), `!ut` (uTorrent), `!qb` (qBittorrent), `bc!` (BitComet); or an
  Android MediaStore `.pending-<timestamp>-` name (hidden, so only seen when
  hidden files are scanned).
- **Risks:** a download that's in progress — covered by the grace period.
- **Test area:** `Report.docx.crdownload`, `holiday_movie.mp4.part`,
  `episode_01.mkv.!ut`; `still_downloading.zip.crdownload` is modified at
  generation time and must be held back for 10 minutes, then flagged.
- **Mass scan:** misses torrent-client extensions and doesn't allow for
  in-progress downloads.

### U04 — Zero-filled

- **Matches:** the first 4 KB are zero, and 4 KB samples from the middle and
  end are also zero. Also: an MP3 whose tag is valid but whose audio samples
  are all zero.
- **Confidence:** `certain` for known types; `likely` for unknown types (a
  sparse data file could be legitimately zero, though not in phone storage).
- **Risks:** a file with real data only between the samples. Sampling 3
  points keeps big files cheap; widen with `sampleBytes`.
- **Test area:** `scan_copy.jpg`, `backup_data.bin`, `blank_audio.mp3`.
- **Mass scan:** only checks the first 4 KB, only for known types, and misses
  zeroed MP3 audio.

### U05 — Contents don't match the type

- **Matches:** the first bytes aren't the extension's signature and aren't
  any other known format's distinctive signature.
- **Messages** say what the file really is when it's text: "Named .pdf but
  contains a web page (often a saved error or sign-in page…)", "…contains
  JSON text…".
- **Also:** a known-type file whose first 4 KB are blank but which has data
  later (header wiped).
- **Not flagged:** content that is a *different valid format* (PNG named
  `.jpg`) — see `misnamed` above.
- **Test area:** `lease_agreement.pdf` (404 page), `contract.docx` (cloud
  error JSON), `garbage.png`, `header_wiped.jpg`; must not flag
  `healthy/sticker_saved_as.jpg`.
- **Mass scan:** flags misnamed-but-valid files (false positive) and gives a
  generic message.

### U06 — Cut off / unfinished

When the end of a file is a run of ≥ 1 KB of zero bytes, any U06 becomes
`certain` with the message "Download or copy stopped partway: the last N KB
were never filled in" — download managers reserve the full size first.

| Format | Cut off when | Confidence |
|---|---|---|
| PDF | no `%%EOF` in the last 1 KB | certain |
| PNG | a chunk runs past the end, or no `IEND` | certain |
| JPEG | no `FF D9` in the last 64 KB, then walking the markers finds no scan, or no `FF D9` after the first scan | likely (scan missing: certain) |
| GIF | no `0x3B` trailer in the last 16 bytes | likely |
| BMP | header size or pixel offset beyond the file | certain |
| TIFF | first directory offset beyond the file | certain |
| WAV / AVI / WebP | RIFF size beyond the file; WAV `data` chunk beyond the file | certain |
| WAV | `data` size 0 or 0xFFFFFFFF with audio following (recorder never finalised) | likely |
| MP4 family | a box runs past the end; video with no `moov` index | certain |
| Ogg / Opus | last page lacks the end-of-stream flag | likely |
| ZIP family | no end-of-central-directory record | certain |
| 7-Zip | index ends beyond the file | certain |
| gzip | shorter than 18 bytes | certain |
| OLE (`doc`/`xls`/`ppt`) | smaller than header + 1 sector | certain |
| OLE | not a whole number of sectors | likely |
| RTF (≤ 1 MB) | unclosed `{` groups | likely |
| JSON (≤ 1 MB) | doesn't parse and has unclosed brackets | likely |

- **Risks:** motion photos (JPEG + appended video) have no `FF D9` near the
  end; the marker walk handles them (`healthy/MVIMG_motion_photo.jpg`).
  Players tolerate some truncated media, which is why GIF/Ogg/JPEG are
  `likely`.
- **Test area:** 15 files in `unreadable/`.
- **Mass scan:** covers PDF/PNG/ZIP/MP4 only; misses JPEG, GIF, WAV, Ogg,
  7-Zip, RTF, JSON and gives no "download stopped" message.

### U07 — Internal structure damaged

| Format | Damaged when | Confidence |
|---|---|---|
| PNG (≤ 32 MB) | any chunk's CRC-32 fails; first chunk isn't a 13-byte IHDR; 0×0 size; no IDAT | certain |
| ZIP | directory overlaps the end record; no directory signature (also checked for self-extracting offset); first entry's local header missing | certain |
| ZIP documents | 0 entries | certain |
| ZIP documents | required part missing (`[Content_Types].xml` for Office, `mimetype` for ODF/EPUB, `AndroidManifest.xml` for APK) | likely |
| MP4 family | a box smaller than its own header | certain |
| JPEG | marker walk hits a non-marker byte | certain |
| OLE | bad byte-order mark or sector size | certain |
| JSON | doesn't parse (and isn't line-delimited JSON), brackets balanced | likely |

- **Test area:** `screenshot_damaged.png` (one flipped byte),
  `zero_size.png`, `broken_index.zip`, `not_really.docx`, `data_export.json`.
- **Mass scan:** only notices damaged PNGs if the decoder fails; misses the
  rest.

### U08 — Image won't decode

- **Matches:** a photo-type file (`jpg`, `jpeg`, `png`, `heic`, `heif`,
  `webp`, `bmp`) passes every structural check but the decoder can't produce
  an image. Uses `ScanContext.analyzeImage`, so when merged with the photo
  detectors each image is decoded once.
- **Cost:** the slowest check; switch off with `decodeImages: false`.
- **Test area:** `IMG_damaged.jpg` (markers intact, picture data scrambled).
- **Mass scan:** same check.

### U09 — Garbled text

| Signal | Confidence |
|---|---|
| zero bytes in a text file, unless they sit in every other position (UTF-16 without a byte-order mark) | certain |
| more than `garbledControlRatio` (10%) control characters (tab, newlines, form feed and ESC excluded) | likely |
| ≥ `replacementCharMin` (8) U+FFFD characters making up ≥ `replacementCharRatio` (2%) of the text | likely |

- **Risks:** text in a legacy encoding (Latin-1) is *not* flagged — invalid
  UTF-8 alone isn't damage (`healthy/old_windows_notes.txt`). Coloured logs
  use ESC and are fine (`healthy/build_output.log`).
- **Test area:** `notes_binary.txt`, `converted_notes.txt`,
  `terminal_dump.log`; must not flag `healthy/utf16_no_bom.txt`.
- **Mass scan:** flags UTF-16 without a BOM as binary (false positive);
  misses the other two signals.

## 6. Tuning knobs

All in `EmptyUnreadableRules` (`lib/src/empty_unreadable/rules.dart`).

| Knob | Default | Trade-off |
|---|---|---|
| `ignoredEmptyFileNames` | `.nomedia`, `.gitkeep`, `.keep` | Add markers seen in the wild. |
| `ignoredEmptyExtensions` | `lock` | Same. |
| `partialDownloadExtensions` | 8 extensions | Add more browsers/clients. |
| `recentlyModifiedGrace` | 10 min | Longer = fewer false alarms on slow downloads; shorter = faster feedback. |
| `graceRules` | E01 E02 E05 U02 U03 U04 U06 U08 | Which rules wait out the grace period. |
| `blankContentMaxBytes` | 4 KB | Boundary between E02 and U04 for zero-filled files. |
| `headBytes` | 4 KB | Size of the first read; must cover every signature. |
| `tailBytes` | 64 KB + 22 | End-of-file read; can't be smaller (ZIP end record). Files up to this size are read in one go. |
| `sampleBytes` | 4 KB | U04 middle/end samples. Bigger = fewer misses, more I/O. |
| `fullReadMaxBytes` | 32 MB | Above this, PNG checksums, JPEG marker walk, PDF page check and RTF braces are skipped. Main memory/speed lever. |
| `structuredTextMaxBytes` | 1 MB | Text parsed for E03/JSON/RTF/PDF-pages up to this size. |
| `garbledControlRatio` | 0.10 | U09 control-character threshold. |
| `replacementCharMin` / `Ratio` | 8 / 0.02 | U09 bad-conversion threshold. |
| `concurrency` | 4 | Files checked at once. |
| `minConfidence` | `likely` | `certain` hides every `likely` finding. |
| `disabledRules` | none | Switch rules off to measure their effect (CLI `--disable E03`). |
| `decodeImages` | true | U08 on/off. |

## 7. Performance

Per file, the deep scan reads:

- **0-byte and temp-download files:** nothing.
- **Files ≤ 64 KB:** one read of the whole file; every check works from it.
- **Larger files:** 4 KB from the start, plus, depending on format, the last
  64 KB (end markers), a few 16-byte box headers (MP4), the ZIP directory, or
  4 KB samples (U04, MP3). Whole-file reads only for PNG, JPEG without an
  end marker near the end, and PDF/RTF/text ≤ 1 MB.
- **Photos:** one decode for U08, shared with the photo detectors when merged.

Baseline on the test area (92 files, 560 KB, Windows 11, Dart 3.13,
`dart run`): **501 KB read in 86 reads, ~170 ms** for the whole deep scan
(excludes image-decode reads, which go through the decoder).

Where to look when optimising:

1. PNG CRC over the whole file is the most expensive structural check on
   large screenshots; consider checking only IHDR + IEND CRCs plus sampled
   IDATs.
2. The JPEG marker walk reads the whole file when `FF D9` isn't in the last
   64 KB (motion photos). Could stop reading once the first scan's `FF D9`
   is found.
3. `ReadStats` (bytes and reads) is in every result (`--json` →
   `stats`) — compare it before and after a change.

## 8. Accuracy baseline

| Run | Deep scan | Mass scan (current detectors) |
|---|---|---|
| Test area, 92 files (58 waste, 34 look-alikes) | **92 / 92** expectations met | 52 / 92 in the right category |
| `scan_engine` sample phone (`--grace-minutes 0`) | Agrees with all 10 mass-scan findings | — |

On the sample phone the deep scan adds one finding the mass scan doesn't
make: `Download/empty_archive.zip` (E04). The mass-scan README lists it as a
valid ZIP; under this ruleset an archive with nothing in it is empty.

Where the mass scan differs on the test area:

- **Misses (36):** structured empties (E03), empty archives (E04), empty
  media (E05), UTF-16/large blank text, torrent temp files, zero-filled
  unknown types and MP3 audio, JPEG/GIF/WAV/Ogg/7-Zip/RTF/JSON truncation,
  PNG checksum failures, damaged ZIP directories, Office files missing
  parts, malformed JSON, bad-conversion and control-character text.
- **False positives (4):** a PNG named `.jpg`; UTF-16 text without a BOM; a
  0-byte `.lock` file; a download still in progress.

## 9. Known gaps, and rules considered and rejected

| Idea | Decision |
|---|---|
| PDF cross-reference (`startxref`) validation | Rejected: readers rebuild broken xref tables, so a bad one doesn't make a PDF unreadable. |
| ZIP entry CRCs / gzip CRC | Not yet: needs decompression. Would catch bit rot inside archives. |
| MKV/WebM, FLAC, RAR, HEIC item structure | Signature check only. Candidates for later. |
| Ogg page CRCs | Not checked; only the end-of-stream flag. |
| Empty folders | Out of scope: the storage source lists files only, and empty folders use no space. |
| Encrypted / password-protected files | Not unreadable to their owner; not flagged. |
| Cloud placeholders | Only caught when a read comes back short (U02). Platform-specific detection is a device-adapter job. |
| Hidden files (`.pending-…`, `.thumbnails`) | The device source skips them; U03 recognises `.pending-` if hidden files are ever included. |
| Office lock files (`~$report.docx`) | Junk, but neither empty nor unreadable; belongs in a future temp-file scan. |

## 10. Merging into the mass scan

The deep scan already speaks the mass scan's language: `EmptyUnreadableScan`
runs through `ScanEngine` (same permission gate, progress and `ScanReport`),
and `EmptyUnreadableAnalyzer.detectors()` returns two `WasteDetector`s for
the existing `emptyFile` and `unreadableFile` categories. When it's time:

1. In `ScanEngine.defaultDetectors()`, replace `EmptyFileDetector()` and
   `UnreadableFileDetector()` with `...EmptyUnreadableAnalyzer().detectors()`.
2. Decide whether `ScanReport` should carry rule codes and confidence (the
   UI could pre-select only `certain` findings).
3. Fold the knobs into `ScanRules` (DAT-16 classification ruleset).
4. Re-run the test area with `--compare` and update §8.

## 11. Changelog

| Version | Change |
|---|---|
| 1.0 | First ruleset: E01–E05, U01–U09; test area of 92 files. |
