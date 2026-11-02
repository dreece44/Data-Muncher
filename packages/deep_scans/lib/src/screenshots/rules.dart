import '../shared/confidence.dart';
import 'measure.dart';
import 'names.dart';

export '../shared/confidence.dart';

/// Why an image was flagged as a screenshot, in precedence order: an image
/// gets at most one rule, the first that matches. S05 and S06 say the
/// screenshot is also blank; S01–S04 say how it was recognised. Each is a
/// rule in `docs/SCREENSHOT_RULESET.md`; keep the two in sync.
enum ScreenshotRule {
  s05Blank('S05', Confidence.certain, 'blank screenshot', empty: true),
  s06EmptyScreen('S06', Confidence.certain, 'empty screen', empty: true),
  s01SystemName('S01', Confidence.certain, 'screenshot'),
  s02Marker('S02', Confidence.certain, 'screenshot (marked by the tool)'),
  s03Filed('S03', Confidence.likely, 'filed as a screenshot'),
  s04LooksLike('S04', Confidence.likely, 'looks like a screenshot');

  const ScreenshotRule(this.code, this.confidence, this.label,
      {this.empty = false});

  final String code;
  final Confidence confidence;

  /// Plain-language name, used in the reasons users see.
  final String label;

  /// Nothing on it worth keeping: the review UI can pre-select these.
  final bool empty;

  static ScreenshotRule? byCode(String code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// Thresholds and switches for the screenshot deep scan. Defaults come from
/// the measurements in the ruleset doc (§7); every one is a knob for the
/// accuracy/performance pass.
final class ScreenshotRules {
  const ScreenshotRules({
    this.namePatterns = defaultScreenshotNamePatterns,
    this.screenshotFolders = const {
      'screenshots', 'screenshot', 'screen shots', 'screen captures', //
      'screencaps', 'screencapture',
    },
    this.toolWords = const {
      'screenshot', 'screencapture', 'screen capture', 'spectacle', //
      'greenshot', 'sharex', 'snipping tool', 'snip & sketch', 'flameshot',
      'lightshot', 'shottr', 'cleanshot', 'snagit', 'skitch',
    },
    this.screenRecordingWords = const {
      'screen_recording', 'screen recording', 'screenrecord', //
      'screen-recording', 'screenrecorder',
    },
    this.headBytes = 256 * 1024,
    this.maxImageBytes = 64 * 1024 * 1024,
    this.maxSamples = 300000,
    this.flatTolerance = 1,
    this.colorTolerance = 6,
    this.topBarShare = 0.045,
    this.bottomBarShare = 0.05,
    this.markContrast = 48,
    this.uiDominantShare = 0.25,
    this.graphicFlatShare = 0.5,
    this.minPortraitAspect = 1.3,
    this.phoneAspect = 1.7,
    this.blankShare = 0.997,
    this.recentWindow = const Duration(days: 2),
    this.oldAge = const Duration(days: 30),
    this.concurrency = 4,
    this.useIsolates = true,
    this.minConfidence = Confidence.likely,
    this.disabledRules = const {},
  })  : assert(concurrency >= 1),
        assert(blankShare > 0.9 && blankShare <= 1),
        assert(minPortraitAspect >= 1);

  /// S01: how screenshot tools name files.
  final List<ScreenshotNamePattern> namePatterns;

  /// S03: folders screenshots are saved to (lower case, matched against
  /// every folder above the file).
  final Set<String> screenshotFolders;

  /// S02: capture tools named in a file's Software / CreatorTool /
  /// description metadata (lower case, substring match).
  final Set<String> toolWords;

  /// Videos named like screen recordings are noted, not flagged: they
  /// belong to the old-video scan.
  final Set<String> screenRecordingWords;

  /// Bytes read first, for metadata and the image size. Enough for phone
  /// and camera metadata, which come before the picture data.
  final int headBytes;

  /// Larger images aren't decoded; name, folder and metadata still apply.
  final int maxImageBytes;

  /// Pixels sampled per image (on a grid, without resizing).
  final int maxSamples;

  /// Neighbouring pixels this close (per channel) count as flat. Reported
  /// as evidence and used only for the X03 note; no rule depends on it
  /// (JPEG makes camera pictures look flat too, §7).
  final int flatTolerance;

  /// Pixels this close (per channel) to the dominant colour count as that
  /// colour. Covers JPEG wobble in flat areas.
  final int colorTolerance;

  /// Top and bottom bands left out of the "content" area: phone status and
  /// gesture bars, the macOS menu bar, the Windows taskbar.
  final double topBarShare;
  final double bottomBarShare;

  /// Status-bar marks (clock, icons) differ from the bar by at least this.
  final int markContrast;

  /// S04: an app screen's background covers at least this share of it.
  final double uiDominantShare;

  /// X03: an unsignalled image this flat (see [flatTolerance]) with an
  /// app-like background but no status bar is noted as a possible
  /// screenshot. Keeps noisy scans and photos out of the note.
  final double graphicFlatShare;

  /// S04: only portrait images at least this tall for their width.
  final double minPortraitAspect;

  /// Portrait screenshots at least this tall for their width are phone
  /// screens; shorter ones are tablet screens. Landscape: computer.
  final double phoneAspect;

  /// S05 / S06: the whole frame (S05) or everything but the system bars
  /// (S06) is at least this share one colour.
  final double blankShare;

  /// Screenshots newer than this aren't flagged: the ticket or code you
  /// just captured is probably still needed. Blank ones still are.
  final Duration recentWindow;

  /// Screenshots older than this are counted as old in the bulk-review
  /// batches.
  final Duration oldAge;

  /// Images read and measured at once.
  final int concurrency;

  /// Decode on background isolates. Off in tests that count reads.
  final bool useIsolates;

  /// Findings below this confidence are dropped.
  final Confidence minConfidence;

  /// Rules switched off for experiments. An image a disabled rule would
  /// have matched falls through to the next rule.
  final Set<ScreenshotRule> disabledRules;

  ScreenMeasureSettings get measureSettings => ScreenMeasureSettings(
        maxSamples: maxSamples,
        flatTolerance: flatTolerance,
        colorTolerance: colorTolerance,
        topBarShare: topBarShare,
        bottomBarShare: bottomBarShare,
        markContrast: markContrast,
      );
}
