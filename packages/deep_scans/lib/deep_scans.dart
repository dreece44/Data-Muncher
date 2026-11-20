/// DataMuncher focused deep scans.
///
/// Each deep scan targets one kind of waste in more depth than the mass scan
/// in `scan_engine`, and can be run and tested on its own. Each one also
/// provides [WasteDetector]s, so it can later replace the matching mass-scan
/// detectors in a [ScanEngine] without other changes.
///
/// Available scans:
/// - Empty & unreadable files (Jira DAT-20): [EmptyUnreadableScan],
///   ruleset in `docs/EMPTY_UNREADABLE_RULESET.md`.
/// - Duplicate photos (Jira DAT-21): [DuplicatePhotoScan], ruleset in
///   `docs/DUPLICATE_PHOTO_RULESET.md`.
/// - Duplicate documents and other non-image files (Jira DAT-3):
///   [DuplicateDocumentScan], ruleset in `docs/DUPLICATE_DOCUMENT_RULESET.md`.
/// - Blurry photos (Jira DAT-22): [BlurryPhotoScan], ruleset in
///   `docs/BLURRY_PHOTO_RULESET.md`.
/// - Screenshots (Jira DAT-23): [ScreenshotScan], ruleset in
///   `docs/SCREENSHOT_RULESET.md`.
/// - Large and old videos (Jira DAT-24): [LargeOldVideoScan], ruleset in
///   `docs/LARGE_OLD_VIDEO_RULESET.md`.
library;

export 'src/blurry_photos/analyzer.dart';
export 'src/blurry_photos/measure.dart';
export 'src/blurry_photos/model.dart';
export 'src/blurry_photos/rules.dart';
export 'src/blurry_photos/scan.dart';
export 'src/duplicate_documents/analyzer.dart';
export 'src/duplicate_documents/content.dart'
    show
        DocumentContent,
        DocumentFormat,
        normalizeText,
        pdfContentText,
        readDocument,
        wordsOf;
export 'src/duplicate_documents/model.dart';
export 'src/duplicate_documents/page_match.dart';
export 'src/duplicate_documents/rules.dart';
export 'src/duplicate_documents/scan.dart';
export 'src/duplicate_documents/similarity.dart'
    show jaccard, namesRelated, nameStem, shingles;
export 'src/duplicate_photos/analyzer.dart';
export 'src/duplicate_photos/fingerprint.dart'
    show PhotoFingerprint, PhotoTransform, PhotoView;
export 'src/duplicate_photos/matcher.dart' show PairCheck, comparePhotos;
export 'src/duplicate_photos/model.dart';
export 'src/duplicate_photos/rules.dart';
export 'src/duplicate_photos/scan.dart';
export 'src/empty_unreadable/analyzer.dart';
export 'src/empty_unreadable/file_probe.dart' show ReadStats;
export 'src/empty_unreadable/rules.dart';
export 'src/empty_unreadable/scan.dart';
export 'src/empty_unreadable/verdict.dart';
export 'src/large_old_videos/analyzer.dart';
export 'src/large_old_videos/container.dart'
    show VideoInfo, VideoProblem, formatDuration, readVideoInfo;
export 'src/large_old_videos/model.dart';
export 'src/large_old_videos/names.dart';
export 'src/large_old_videos/rules.dart';
export 'src/large_old_videos/scan.dart';
export 'src/screenshots/analyzer.dart';
export 'src/screenshots/measure.dart';
export 'src/screenshots/metadata.dart';
export 'src/screenshots/model.dart';
export 'src/screenshots/names.dart';
export 'src/screenshots/rules.dart';
export 'src/screenshots/scan.dart';
