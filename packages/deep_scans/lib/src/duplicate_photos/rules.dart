import '../shared/confidence.dart';

export '../shared/confidence.dart';

/// How a photo in a duplicate group relates to the copy being kept. Each is
/// a rule in `docs/DUPLICATE_PHOTO_RULESET.md`; keep the two in sync.
enum DuplicateRule {
  d01Exact('D01', Confidence.certain, 'identical copy'),
  d02ReEncoded('D02', Confidence.certain, 'resized or re-saved copy'),
  d03Turned('D03', Confidence.certain, 'rotated or mirrored copy'),
  d04Bordered('D04', Confidence.likely, 'copy with borders added'),
  d05Edited('D05', Confidence.likely, 'edited copy (brightness/contrast)'),
  d06SimilarShot('D06', Confidence.likely, 'near-identical shot');

  const DuplicateRule(this.code, this.confidence, this.label);

  final String code;
  final Confidence confidence;

  /// Plain-language name, used in the reasons users see.
  final String label;

  static DuplicateRule? byCode(String code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// Thresholds and switches for the duplicate photo deep scan. Defaults come
/// from measurements recorded in the ruleset doc (§7); every one is a knob
/// for the accuracy/performance pass.
final class DuplicatePhotoRules {
  const DuplicatePhotoRules({
    this.exactMinBytes = 4096,
    this.exactPrefixBytes = 64 * 1024,
    this.analysisSize = 256,
    this.minPhotoDimension = 200,
    this.blankMaxStdDev = 5.0,
    this.copyHashDistance = 8,
    this.copyCorrelation = 0.985,
    this.copyEdgeCorrelation = 0.97,
    this.editedMinBrightnessDiff = 8.0,
    this.aspectTolerance = 0.03,
    this.borderedAspectTolerance = 0.05,
    this.shotHashDistance = 4,
    this.shotCorrelation = 0.85,
    this.shotEdgeCorrelation = 0.5,
    this.shotTimeWindow = const Duration(minutes: 30),
    this.shotDetailAgreement = 0.90,
    this.shotDetailMaxShift = 0.05,
    this.shotDetailBlur = 2.5,
    this.blurryRetakeSharpness = 0.6,
    this.keepSharpnessShare = 0.8,
    this.borderMaxStdDev = 6.0,
    this.borderMaxShare = 0.35,
    this.secondhandFolders = const {
      'whatsapp', 'telegram', 'messenger', 'signal', 'snapchat', //
      'instagram', 'facebook', 'twitter', 'download', 'downloads', 'sent',
      'shared', 'edited', 'copies', 'backup', 'backups',
    },
    this.screenshotFolders = const {'screenshots', 'screenshot'},
    this.maxClusterSize = 200,
    this.concurrency = 4,
    this.minConfidence = Confidence.likely,
    this.disabledRules = const {},
  })  : assert(analysisSize >= 64),
        assert(concurrency >= 1);

  /// D01: smaller image files aren't hashed (icons, stickers).
  final int exactMinBytes;

  /// D01: bytes hashed first to rule out same-size files cheaply before
  /// hashing whole files.
  final int exactPrefixBytes;

  /// Photos are decoded to a square greyscale thumbnail this size. Bigger
  /// makes sharpness more accurate and decoding no slower (the full decode
  /// dominates), but uses more memory per photo in flight.
  final int analysisSize;

  /// Images narrower or shorter than this are icons, not photos (X02).
  final int minPhotoDimension;

  /// Photos with less brightness spread than this are blank (X01): left to
  /// the blank-photo scan, since every black pocket shot looks alike.
  final double blankMaxStdDev;

  /// D02–D05: candidate copies must be within this many bits (of 63) in
  /// perceptual hash under some rotation/mirror.
  final int copyHashDistance;

  /// D02–D05: minimum brightness-pattern correlation (−1…1).
  final double copyCorrelation;

  /// D02–D05: minimum edge-pattern correlation. What separates copies from
  /// different receipts photographed in the same layout.
  final double copyEdgeCorrelation;

  /// A copy whose average brightness differs by more than this (0–255) is
  /// an edited copy (D05) rather than a re-saved one (D02).
  final double editedMinBrightnessDiff;

  /// Copies keep their shape: width/height may differ by at most this
  /// share once rotation is undone.
  final double aspectTolerance;

  /// Same, for the picture inside added borders (D04).
  final double borderedAspectTolerance;

  /// D06 thresholds: hash distance, correlation, edge correlation.
  final int shotHashDistance;
  final double shotCorrelation;
  final double shotEdgeCorrelation;

  /// D06: shots must be taken (last modified) within this time of each
  /// other. A photo of the same view on another day is a different moment.
  final Duration shotTimeWindow;

  /// D06 fine-detail check: the photos are decoded again, the sharper one
  /// is blurred to match, the two are aligned (within [shotDetailMaxShift]
  /// of the frame), and their detail must correlate at least this well.
  /// What tells shots of one receipt from different receipts photographed
  /// in the same layout. −1 switches the check off.
  final double shotDetailAgreement;
  final double shotDetailMaxShift;

  /// D06 fine-detail check: both photos are softened by this much first
  /// (Gaussian sigma, pixels of a 256-px thumbnail), since two sharp shots
  /// are never aligned to a fraction of a pixel. More = more forgiving of
  /// small movement, until only the coarse layout is left to compare.
  final double shotDetailBlur;

  /// A copy-level match that is less than this share as sharp as the other
  /// photo is a blurry retake (D06), not a copy.
  final double blurryRetakeSharpness;

  /// K01: photos at least this share as sharp as the sharpest in the group
  /// count as "sharp enough" to keep.
  final double keepSharpnessShare;

  /// Border trimming (D04): edge rows/columns flatter than this are border.
  final double borderMaxStdDev;

  /// Border trimming: at most this share of each side is trimmed.
  final double borderMaxShare;

  /// Path folders (lower-case) that hold second-hand copies: messaging
  /// apps, downloads, backups. The keeper prefers photos outside them.
  final Set<String> secondhandFolders;

  /// Screenshots are never "shots" of each other (D06 doesn't apply).
  final Set<String> screenshotFolders;

  /// Groups larger than this are left as found rather than re-clustered
  /// (protects against pathological libraries).
  final int maxClusterSize;

  /// Photos decoded at once.
  final int concurrency;

  /// Members related to the keeper below this confidence are dropped.
  final Confidence minConfidence;

  /// Rules switched off for experiments: matches of these kinds aren't used
  /// to build groups at all.
  final Set<DuplicateRule> disabledRules;
}
