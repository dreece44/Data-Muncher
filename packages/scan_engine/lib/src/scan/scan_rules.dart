/// Thresholds that decide what counts as waste. Defaults are starting
/// points; the classification ruleset story (DAT-16) is expected to tune
/// them.
final class ScanRules {
  const ScanRules({
    this.nearDuplicateCoarseDistance = 6,
    this.nearDuplicateFineDistance = 16,
    this.blankMaxStdDev = 5.0,
    this.minPhotoDimension = 200,
    this.maxPhotoBytes = 64 * 1024 * 1024,
    this.thumbnailSize = 64,
    this.imageConcurrency = 4,
    this.blankContentMaxBytes = 4096,
    this.unusedAppAfter = const Duration(days: 90),
    this.ignoredEmptyFileNames = const {'.nomedia', '.gitkeep', '.keep'},
  })  : assert(thumbnailSize >= 17),
        assert(imageConcurrency >= 1);

  /// Max differing bits (of 64) in the coarse hash for two photos to be
  /// duplicate candidates.
  final int nearDuplicateCoarseDistance;

  /// Max differing bits (of 256) in the fine hash to confirm a duplicate.
  /// In testing, copies (resized, recompressed, noisy) scored ≤ 3 and two
  /// different receipts in the same layout scored 29.
  final int nearDuplicateFineDistance;

  /// Photos whose brightness spread is at or below this are blank (pocket
  /// shots, lens-cap photos, all-white screenshots). Scale is 0–255.
  final double blankMaxStdDev;

  /// Images narrower or shorter than this (in pixels) are icons or stickers,
  /// not photos, and are ignored by the photo detectors.
  final int minPhotoDimension;

  /// Photos larger than this aren't decoded (protects memory on phones).
  final int maxPhotoBytes;

  /// Side length of the greyscale thumbnails images are analysed at.
  final int thumbnailSize;

  /// How many images are decoded at once.
  final int imageConcurrency;

  /// Files up to this size that contain only whitespace or zero bytes count
  /// as empty.
  final int blankContentMaxBytes;

  /// Apps not opened for this long are reported as unused.
  final Duration unusedAppAfter;

  /// Zero-byte files that exist on purpose and are never reported as empty.
  /// `.nomedia` is on every Android phone: it hides a folder from the gallery.
  final Set<String> ignoredEmptyFileNames;
}
