import '../shared/confidence.dart';

export '../shared/confidence.dart';

/// How a document in a duplicate group relates to the copy being kept. Each
/// is a rule in `docs/DUPLICATE_DOCUMENT_RULESET.md`; keep the two in sync.
///
/// Listed strongest first: when two documents match under several rules,
/// the first one in this order is the one reported.
enum DocumentRule {
  f01Identical('F01', Confidence.certain, 'identical copy'),
  f02ReSaved('F02', Confidence.certain, 're-saved copy'),
  f03SameText('F03', Confidence.likely, 'same text in another file'),
  f04EditedVersion('F04', Confidence.likely, 'lightly edited version'),
  f05RepeatedScan('F05', Confidence.likely, 'repeated scan');

  const DocumentRule(this.code, this.confidence, this.label);

  final String code;
  final Confidence confidence;

  /// Plain-language name, used in the reasons users see.
  final String label;

  static DocumentRule? byCode(String code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// Thresholds and switches for the duplicate document deep scan. Defaults
/// come from the measurements in the ruleset doc (§7); every one is a knob
/// for the accuracy/performance pass.
final class DuplicateDocumentRules {
  const DuplicateDocumentRules({
    this.minBytes = 64,
    this.prefixBytes = 64 * 1024,
    this.contentMaxBytes = 32 * 1024 * 1024,
    this.partMaxBytes = 8 * 1024 * 1024,
    this.minTextWords = 20,
    this.minVersionWords = 40,
    this.shingleWords = 5,
    this.versionMinSimilarity = 0.85,
    this.versionMinLengthRatio = 0.8,
    this.nearMissSimilarity = 0.6,
    this.minHashBands = 16,
    this.minHashRows = 4,
    this.minLetterShare = 0.75,
    this.minScanPageSide = 300,
    this.maxScanPages = 50,
    this.scanAnalysisSize = 512,
    this.scanMaxTileDifference = 0.16,
    this.scanMaxShift = 0.05,
    this.scanTimeWindow = const Duration(hours: 24),
    this.keepSharpnessShare = 0.8,
    this.secondhandFolders = const {
      'download', 'downloads', 'whatsapp', 'whatsapp documents', //
      'telegram', 'telegram documents', 'messenger', 'signal', 'bluetooth',
      'sent', 'shared', 'received', 'copies', 'backup', 'backups', 'outlook',
      'gmail', 'attachments',
    },
    this.ignoredFolders = const {'android/data', 'android/obb'},
    this.ignoredNames = const {
      'desktop.ini',
      'thumbs.db',
      '.ds_store',
      '.nomedia',
      '.gitkeep',
    },
    this.maxClusterSize = 200,
    this.partialCopyCandidates = 50,
    this.minConfidence = Confidence.likely,
    this.disabledRules = const {},
  })  : assert(shingleWords >= 1),
        assert(minHashBands >= 1 && minHashRows >= 1),
        assert(scanAnalysisSize % 4 == 0);

  /// X04: files smaller than this aren't compared at all. Tiny identical
  /// files are markers and one-line settings, and save nothing.
  final int minBytes;

  /// F01: bytes hashed first to tell same-size files apart cheaply before
  /// hashing whole files.
  final int prefixBytes;

  /// Documents up to this size are read whole and their content compared
  /// (F02–F05). Larger ones only get the identical-copy check (F01).
  final int contentMaxBytes;

  /// Largest single PDF stream or ZIP part that is inflated. Guards against
  /// compression bombs; larger parts are hashed as stored.
  final int partMaxBytes;

  /// F03: documents need at least this many words for "same text" to mean
  /// "same document" (two one-line notes saying "OK, thanks" aren't).
  final int minTextWords;

  /// F04: documents need at least this many words to be versions of each
  /// other; short texts change too much with a single edit to measure.
  final int minVersionWords;

  /// F04: words per shingle (overlapping run of words compared as one unit).
  final int shingleWords;

  /// F04: minimum Jaccard similarity of the two shingle sets.
  final double versionMinSimilarity;

  /// F04: the shorter text must be at least this share of the longer.
  final double versionMinLengthRatio;

  /// Pairs at least this similar that didn't become F04 are recorded as
  /// near misses for tuning.
  final double nearMissSimilarity;

  /// F04 candidate index: MinHash signature of [minHashBands] ×
  /// [minHashRows] values; two documents become candidates when any band
  /// matches. 16 × 4 finds a pair at similarity 0.85 with probability
  /// 99.9999%, and one at 0.3 with 12%.
  final int minHashBands;
  final int minHashRows;

  /// Extracted text whose share of letters, digits and spaces is below this
  /// is garbage (fonts that store glyph numbers, not characters), and the
  /// document is treated as having no text.
  final double minLetterShare;

  /// F05: embedded JPEG images with both sides at least this many pixels
  /// count as scanned pages (smaller ones are logos and stamps).
  final int minScanPageSide;

  /// F05: scans with more pages than this aren't compared page by page.
  final int maxScanPages;

  /// F05: scanned pages are decoded to a square greyscale thumbnail this
  /// size. Text needs more detail than photos: at 256 px different
  /// delivery notes in one layout can't be told apart.
  final int scanAnalysisSize;

  /// F05 detail test: after aligning two pages, the most different tile
  /// (1/24 of the page across) may differ by at most this much mean
  /// brightness (0–1). Rescans of one paper measured up to 0.157 (out of
  /// focus); different documents in the same layout from 0.169.
  final double scanMaxTileDifference;

  /// F05: pages may be shifted against each other by up to this share of
  /// their size (where the paper sat on the scanner).
  final double scanMaxShift;

  /// F05 guard G5: scans must be made (last modified) within this time of
  /// each other. Rescans because of focus happen minutes apart; a new
  /// delivery note with the same goods and different numbers usually comes
  /// another day, and the pages alone can't tell the numbers apart.
  final Duration scanTimeWindow;

  /// Repeated-scan groups keep a scan at least this share as sharp as the
  /// sharpest (K02).
  final double keepSharpnessShare;

  /// Path folders (lower-case) that hold second-hand copies: downloads,
  /// messaging apps, Bluetooth transfers, backups. The keeper prefers
  /// documents outside them (K04).
  final Set<String> secondhandFolders;

  /// X05: folder paths (lower-case, `/`-separated, matched anywhere in the
  /// path) whose files belong to apps. Identical config files in two apps'
  /// folders are not waste.
  final Set<String> ignoredFolders;

  /// X05: file names (lower-case) that exist on purpose wherever they are.
  final Set<String> ignoredNames;

  /// Connected sets larger than this are kept as found rather than
  /// re-clustered (protects against pathological libraries).
  final int maxClusterSize;

  /// Unreadable documents are checked for being a failed download of at
  /// most this many same-type, larger documents.
  final int partialCopyCandidates;

  /// Members related to the keeper below this confidence are dropped.
  final Confidence minConfidence;

  /// Rules switched off for experiments: matches of these kinds aren't used
  /// to build groups at all.
  final Set<DocumentRule> disabledRules;
}
