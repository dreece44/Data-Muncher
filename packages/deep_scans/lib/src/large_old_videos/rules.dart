import '../shared/confidence.dart';
import 'names.dart';

export '../shared/confidence.dart';

const _mb = 1024 * 1024;
const _gb = 1024 * _mb;

/// Why a video was flagged, in precedence order: a video gets at most one
/// rule, the first that matches. V01–V04 say the video itself is broken
/// (found by reading its container); V10–V14 say it's worth reviewing to
/// get space back. Each is a rule in `docs/LARGE_OLD_VIDEO_RULESET.md`;
/// keep the two in sync.
enum VideoRule {
  v01Empty('V01', Confidence.certain, 'empty video',
      health: true, preselect: true),
  v02CutOff('V02', Confidence.certain, 'cut-off video',
      health: true, preselect: true),
  v03Damaged('V03', Confidence.likely, 'damaged video', health: true),
  v04Interrupted('V04', Confidence.likely, 'interrupted recording',
      health: true),
  v10OldLarge('V10', Confidence.certain, 'old and large'),
  v11Huge('V11', Confidence.certain, 'huge'),
  v12Oversized('V12', Confidence.certain, 'oversized for its length'),
  v13Large('V13', Confidence.certain, 'large'),
  v14Old('V14', Confidence.certain, 'old');

  const VideoRule(this.code, this.confidence, this.label,
      {this.health = false, this.preselect = false});

  final String code;

  /// The most a verdict under this rule can be. A verdict can be less sure
  /// (V10/V14 when the age comes only from the file date, V12 when the frame
  /// rate is assumed); see `VideoVerdict.confidence`.
  final Confidence confidence;

  /// Plain-language name, used in summaries.
  final String label;

  /// The video is broken (V01–V04), not just big or old. Not held back
  /// for recent videos or editing projects.
  final bool health;

  /// Nothing in it can be played: the review UI can pre-select these.
  final bool preselect;

  static VideoRule? byCode(String code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// Thresholds and switches for the large & old video deep scan. Defaults
/// come from the bitrates in the ruleset doc (§7); every one is a knob for
/// the accuracy/performance pass.
final class LargeOldVideoRules {
  const LargeOldVideoRules({
    this.videoExtensions = const {
      'mp4', 'm4v', 'mov', '3gp', '3g2', 'mkv', 'webm', 'avi', //
      'wmv', 'flv', 'mts', 'm2ts', 'ts', 'mpg', 'mpeg', 'vob',
    },
    this.largeBytes = 500 * _mb,
    this.hugeBytes = 2 * _gb,
    this.oldMinBytes = 100 * _mb,
    this.oversizedMinBytes = 200 * _mb,
    this.oversizedBitsPerPixel = 1.0,
    this.reencodeBitsPerPixel = 0.1,
    this.minSavingShare = 0.5,
    this.assumedFrameRate = 30,
    this.oldAge = const Duration(days: 365),
    this.recentWindow = const Duration(days: 14),
    this.activeProjectWindow = const Duration(days: 60),
    this.dateDisagreement = const Duration(days: 30),
    this.intermediateCodecs = const {
      // ProRes, DNxHD/HR, Motion JPEG, lossless and uncompressed: editing
      // and capture formats, many times larger than a delivery codec.
      'apco', 'apcs', 'apcn', 'apch', 'ap4h', 'ap4x', 'avdn', 'avdh', //
      'mjpa', 'mjpb', 'mjpg', 'jpeg', 'ulrg', 'ulra', 'uly0', 'uly2',
      'uly4', 'ulh0', 'ulh2', 'ffv1', 'lags', 'hfyu', 'fps1', 'cfhd',
      'raw ', 'v210', '2vuy', 'yuv2', 'v_uncompressed', 'v_prores',
      'v_ffv1', 'v_mjpeg',
    },
    this.projectExtensions = const {
      'prproj', 'veg', 'vf', 'kdenlive', 'mlt', 'drp', 'aep', 'fcpxml', //
      'wfp', 'tscproj', 'camproj', 'osp', 'pds', 'wlmp', 'imovieproj',
    },
    this.appDataFolders = const [
      ['android', 'data'],
      ['android', 'obb'],
    ],
    this.livePhotoImageExtensions = const {'heic', 'heif', 'jpg', 'jpeg'},
    this.namePatterns = defaultVideoNamePatterns,
    this.headBytes = 64 * 1024,
    this.maxIndexBytes = 64 * _mb,
    this.maxElements = 100000,
    this.projectMaxBytes = 32 * _mb,
    this.cutOffTolerance = 0.01,
    this.sizeScale = 1,
    this.concurrency = 4,
    this.minConfidence = Confidence.likely,
    this.disabledRules = const {},
  })  : assert(concurrency >= 1),
        assert(sizeScale >= 1),
        assert(largeBytes <= hugeBytes),
        assert(minSavingShare > 0 && minSavingShare < 1);

  /// Extensions treated as video (lower case). MP4/MOV/3GP, Matroska/WebM
  /// and AVI are opened and checked; the rest are judged by size and date
  /// only (X07).
  final Set<String> videoExtensions;

  /// V10/V13: a video at least this big is large.
  final int largeBytes;

  /// V11: a video at least this big is flagged whatever its age.
  final int hugeBytes;

  /// V14: an old video smaller than this isn't worth surfacing.
  final int oldMinBytes;

  /// V12: smaller videos aren't worth re-encoding.
  final int oversizedMinBytes;

  /// V12: bits per pixel per frame above which a video is oversized for its
  /// length and resolution. Phones record at 0.1–0.36, game-capture tools
  /// at up to 0.4, action cameras at 1080p up to ~0.9; editing and lossless
  /// formats at 1.5–20 (§5).
  final double oversizedBitsPerPixel;

  /// V12: the bits per pixel a re-encode would need, for the estimated
  /// saving.
  final double reencodeBitsPerPixel;

  /// V12: only flagged when re-encoding would save at least this share.
  final double minSavingShare;

  /// V12: used when the container doesn't say (confidence drops to likely).
  final double assumedFrameRate;

  /// V10/V14: recorded at least this long ago.
  final Duration oldAge;

  /// V10–V14 aren't applied to videos recorded this recently (X01): the
  /// recording you just finished is the one you're about to upload.
  final Duration recentWindow;

  /// An editing project changed this recently protects the videos it uses
  /// (X02). Older projects don't.
  final Duration activeProjectWindow;

  /// X08: a recorded date (metadata or name) this far from the file's date
  /// is noted, since the two lead to different answers.
  final Duration dateDisagreement;

  /// V12: codecs (MP4/MOV/AVI four-character codes, Matroska codec ids; lower
  /// case) that are editing or capture formats. Flagged as oversized
  /// whatever the measured bitrate.
  final Set<String> intermediateCodecs;

  /// Editing-project files whose videos are protected while the project is
  /// active (X02).
  final Set<String> projectExtensions;

  /// Folder sequences (lower case) whose videos belong to an app, not the
  /// user (X05): a game's cut-scenes, an app's cached clips.
  final List<List<String>> appDataFolders;

  /// A `.mov` with the same name as one of these images in the same folder
  /// is the movie half of an iPhone Live Photo (X04).
  final Set<String> livePhotoImageExtensions;

  /// How recording apps and cameras name their videos: the source and the
  /// date recorded.
  final List<VideoNamePattern> namePatterns;

  /// Bytes read from the start of Matroska and AVI files for their headers.
  final int headBytes;

  /// MP4/MOV indexes (`moov`) larger than this aren't read (X06). A
  /// three-hour recording's index is a few MB.
  final int maxIndexBytes;

  /// Most container elements walked in one file. Stops pathological files.
  final int maxElements;

  /// Larger editing projects aren't searched for video names; they protect
  /// videos in their folder instead (as for projects that can't be read).
  final int projectMaxBytes;

  /// V02: an MP4 whose frames add up to more than its data by at least this
  /// share is cut off. Covers padding some muxers add.
  final double cutOffTolerance;

  /// Size thresholds and bits-per-pixel limits are divided by this. Test
  /// areas are built at 1/1024 of real sizes (1 MB on disk stands for 1 GB)
  /// and say so in `expected.json`; see [scaledDown].
  final int sizeScale;

  /// Videos opened at once.
  final int concurrency;

  /// Findings below this confidence are dropped.
  final Confidence minConfidence;

  /// Rules switched off for experiments. A video a disabled rule would have
  /// matched falls through to the next rule.
  final Set<VideoRule> disabledRules;

  /// These rules with every size threshold and bits-per-pixel limit divided
  /// by [factor]: for storage whose files are [factor] times smaller than
  /// the real thing (a test area).
  LargeOldVideoRules scaledDown(int factor) => copyWith(
        largeBytes: largeBytes ~/ factor,
        hugeBytes: hugeBytes ~/ factor,
        oldMinBytes: oldMinBytes ~/ factor,
        oversizedMinBytes: oversizedMinBytes ~/ factor,
        oversizedBitsPerPixel: oversizedBitsPerPixel / factor,
        reencodeBitsPerPixel: reencodeBitsPerPixel / factor,
        sizeScale: sizeScale * factor,
      );

  LargeOldVideoRules copyWith({
    int? largeBytes,
    int? hugeBytes,
    int? oldMinBytes,
    int? oversizedMinBytes,
    double? oversizedBitsPerPixel,
    double? reencodeBitsPerPixel,
    double? minSavingShare,
    Duration? oldAge,
    Duration? recentWindow,
    Duration? activeProjectWindow,
    int? sizeScale,
    int? concurrency,
    Confidence? minConfidence,
    Set<VideoRule>? disabledRules,
  }) =>
      LargeOldVideoRules(
        videoExtensions: videoExtensions,
        largeBytes: largeBytes ?? this.largeBytes,
        hugeBytes: hugeBytes ?? this.hugeBytes,
        oldMinBytes: oldMinBytes ?? this.oldMinBytes,
        oversizedMinBytes: oversizedMinBytes ?? this.oversizedMinBytes,
        oversizedBitsPerPixel:
            oversizedBitsPerPixel ?? this.oversizedBitsPerPixel,
        reencodeBitsPerPixel: reencodeBitsPerPixel ?? this.reencodeBitsPerPixel,
        minSavingShare: minSavingShare ?? this.minSavingShare,
        assumedFrameRate: assumedFrameRate,
        oldAge: oldAge ?? this.oldAge,
        recentWindow: recentWindow ?? this.recentWindow,
        activeProjectWindow: activeProjectWindow ?? this.activeProjectWindow,
        dateDisagreement: dateDisagreement,
        intermediateCodecs: intermediateCodecs,
        projectExtensions: projectExtensions,
        appDataFolders: appDataFolders,
        livePhotoImageExtensions: livePhotoImageExtensions,
        namePatterns: namePatterns,
        headBytes: headBytes,
        maxIndexBytes: maxIndexBytes,
        maxElements: maxElements,
        projectMaxBytes: projectMaxBytes,
        cutOffTolerance: cutOffTolerance,
        sizeScale: sizeScale ?? this.sizeScale,
        concurrency: concurrency ?? this.concurrency,
        minConfidence: minConfidence ?? this.minConfidence,
        disabledRules: disabledRules ?? this.disabledRules,
      );
}
