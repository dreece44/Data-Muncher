/// The kinds of wasted space the scan engine reports.
///
/// Each category is produced by one detector (see `lib/src/detectors`). New
/// categories from the Scanning & Detection epic (blurry photos, screenshots,
/// old videos, duplicate documents) are added here alongside their detector.
enum WasteCategory {
  emptyFile('Empty files'),
  unreadableFile('Unreadable files'),
  duplicatePhoto('Duplicate photos'),
  blankPhoto('Blank photos'),
  unusedApp('Unused apps');

  const WasteCategory(this.label);

  /// Human-readable name, suitable for summaries.
  final String label;
}
