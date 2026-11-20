import '../duplicate_photos/rules.dart' show DuplicatePhotoRules;
import '../shared/confidence.dart';
import 'measure.dart';

export '../shared/confidence.dart';

/// Why a photo was flagged as blurry, in precedence order: a photo gets at
/// most one rule, the first that matches. Each is a rule in
/// `docs/BLURRY_PHOTO_RULESET.md`; keep the two in sync.
enum BlurRule {
  b01Severe('B01', Confidence.certain, 'severely blurry'),
  b04BlurryAttempt('B04', Confidence.certain, 'blurry attempt'),
  b03Motion('B03', Confidence.likely, 'motion blur'),
  b02Blurry('B02', Confidence.likely, 'blurry');

  const BlurRule(this.code, this.confidence, this.label);

  final String code;
  final Confidence confidence;

  /// Plain-language name, used in the reasons users see.
  final String label;

  static BlurRule? byCode(String code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// Thresholds and switches for the blurry photo deep scan. Widths are edge
/// widths in reference pixels (the photo shown with its long side
/// [analysisSize] pixels). Defaults come from the measurements in the
/// ruleset doc (§7); every one is a knob for the accuracy/performance pass.
final class BlurryPhotoRules {
  const BlurryPhotoRules({
    this.analysisSize = 512,
    this.minPhotoDimension = 200,
    this.maxPhotoBytes = 64 * 1024 * 1024,
    this.blankMaxStdDev = 5.0,
    this.minEdges = 200,
    this.minGradient = 3,
    this.minEdgeContrast = 24,
    this.walkTolerance = 3,
    this.walkPatience = 2,
    this.maxWalk = 24,
    this.tiles = 8,
    this.minTileEdges = 8,
    this.sharpRegionShare = 0.05,
    this.minRegionTiles = 2,
    this.pixelFloor = 1.0,
    this.sharpWidth = 1.0,
    this.blurryWidth = 2.4,
    this.severeWidth = 3.6,
    this.softWidth = 1.5,
    this.motionMinWidth = 2.2,
    this.motionRatio = 2.5,
    this.retakeSharpnessRatio = 0.6,
    this.retakeTimeWindow = const Duration(minutes: 30),
    this.retakeHashDistance = 8,
    this.retakeCorrelation = 0.93,
    this.retakeEdgeCorrelation = 0.75,
    this.retakeDetailAgreement = 0.92,
    this.retakeMaxShift = 0.05,
    this.nearMissShare = 0.85,
    this.screenshotFolders = const {'screenshots', 'screenshot'},
    this.concurrency = 4,
    this.minConfidence = Confidence.likely,
    this.disabledRules = const {},
  })  : assert(analysisSize >= 128),
        assert(concurrency >= 1),
        assert(sharpWidth < softWidth &&
            softWidth < blurryWidth &&
            blurryWidth < severeWidth);

  /// Photos are decoded to a square greyscale thumbnail this size (or
  /// their own shorter side, if smaller) and widths are measured there.
  /// Bigger catches subtler blur but costs memory and measuring time.
  final int analysisSize;

  /// Images narrower or shorter than this are icons, not photos (X02).
  final int minPhotoDimension;

  /// Larger files aren't decoded (X06), as in the mass scan.
  final int maxPhotoBytes;

  /// Photos with less brightness spread than this are blank (X01): left to
  /// the blank-photo scan.
  final double blankMaxStdDev;

  /// Photos with fewer measurable edges than this have too little detail to
  /// judge (X04: fog, sky, a plain wall, darkness).
  final int minEdges;

  /// Edge finding: minimum brightness change per pixel to start measuring.
  final double minGradient;

  /// Edge finding: minimum brightness difference across an edge (0–255).
  /// Lower lets noise in; higher loses soft, low-contrast edges.
  final int minEdgeContrast;

  /// Edge walking: how far brightness may wobble back (noise) and for how
  /// many pixels it may stall before the edge is taken to have ended.
  final int walkTolerance;
  final int walkPatience;

  /// Edge walking: farthest a walk goes each way (thumbnail pixels).
  final int maxWalk;

  /// The frame is cut into [tiles]² tiles to find the sharpest region.
  final int tiles;

  /// A tile direction needs this many edges to have a width.
  final int minTileEdges;

  /// The sharpest region is this share of the judged tiles (at least one).
  final double sharpRegionShare;

  /// Fewer judged tiles than this is too little detail (X04).
  final int minRegionTiles;

  /// Width a perfectly sharp edge measures because it falls between
  /// pixels (thumbnail pixels), taken off every width.
  final double pixelFloor;

  /// Width of an in-focus edge: blur score 0.
  final double sharpWidth;

  /// B02: the sharpest region is at least this soft.
  final double blurryWidth;

  /// B01: the sharpest region is at least this soft.
  final double severeWidth;

  /// B03 and B04: a photo must be at least this soft to be called blurry
  /// in comparison with something else.
  final double softWidth;

  /// B03: edges smeared at least this far along one direction...
  final double motionMinWidth;

  /// ...and at least this many times wider than across the crispest one.
  final double motionRatio;

  /// B04: the retake must be at most this share of the photo's blur width.
  final double retakeSharpnessRatio;

  /// B04: the retake must be taken (last modified) this close in time.
  final Duration retakeTimeWindow;

  /// B04: how alike the two shots must be (perceptual-hash bits of 63,
  /// brightness and edge-pattern correlation). Looser than the duplicate
  /// scan's near-identical-shot test (D06), because blur itself moves the
  /// hash and softens edges; the time window and sharpness gap make up
  /// for it.
  final int retakeHashDistance;
  final double retakeCorrelation;
  final double retakeEdgeCorrelation;

  /// B04: the fine-detail check. Once the sharper shot is blurred to match
  /// and the two are aligned (within [retakeMaxShift] of the frame), their
  /// detail must correlate at least this well. What tells a retake from a
  /// different receipt on the same table.
  final double retakeDetailAgreement;
  final double retakeMaxShift;

  /// Photos within this share of [blurryWidth] are noted as near misses.
  final double nearMissShare;

  /// Screenshots aren't camera photos and aren't judged (X03).
  final Set<String> screenshotFolders;

  /// Photos decoded at once.
  final int concurrency;

  /// Findings below this confidence are dropped.
  final Confidence minConfidence;

  /// Rules switched off for experiments. A photo a disabled rule would have
  /// matched falls through to the next rule.
  final Set<BlurRule> disabledRules;

  /// The duplicate photo comparison, set up to find retakes.
  DuplicatePhotoRules get retakeMatchRules => DuplicatePhotoRules(
        shotHashDistance: retakeHashDistance,
        shotCorrelation: retakeCorrelation,
        shotEdgeCorrelation: retakeEdgeCorrelation,
        shotTimeWindow: retakeTimeWindow,
      );

  MeasureSettings get measureSettings => MeasureSettings(
        referenceSize: analysisSize,
        minGradient: minGradient,
        minEdgeContrast: minEdgeContrast,
        walkTolerance: walkTolerance,
        walkPatience: walkPatience,
        maxWalk: maxWalk,
        tiles: tiles,
        minTileEdges: minTileEdges,
        sharpRegionShare: sharpRegionShare,
        minRegionTiles: minRegionTiles,
        pixelFloor: pixelFloor,
      );
}
