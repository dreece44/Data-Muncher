import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

import '../duplicate_photos/fingerprint.dart'
    show PhotoFingerprint, PhotoTransform;
import '../duplicate_photos/matcher.dart' show comparePhotos;
import '../empty_unreadable/analyzer.dart';
import '../empty_unreadable/verdict.dart';
import 'measure.dart';
import 'model.dart';
import 'retake.dart';
import 'rules.dart';

/// Everything one run of the blurry photo analysis produced.
final class BlurryAnalysis {
  const BlurryAnalysis({
    required this.verdicts,
    required this.ranking,
    required this.observations,
    required this.health,
    required this.photosConsidered,
    required this.photosMeasured,
    required this.retakePairs,
    required this.detailChecks,
    required this.decodeTime,
    required this.measureTime,
    required this.elapsed,
  });

  static const empty = BlurryAnalysis(
      verdicts: [],
      ranking: [],
      observations: [],
      health: [],
      photosConsidered: 0,
      photosMeasured: 0,
      retakePairs: 0,
      detailChecks: 0,
      decodeTime: Duration.zero,
      measureTime: Duration.zero,
      elapsed: Duration.zero);

  /// Blurriest first.
  final List<BlurVerdict> verdicts;

  /// Every measured photo, blurriest first (what DAT-22 asks to report).
  final List<RankedPhoto> ranking;
  final List<BlurObservation> observations;

  /// Photos the empty & unreadable checks flagged; left out of the blur
  /// check and reported under that scan's rules.
  final List<FileVerdict> health;

  /// Image files found in storage (photo formats, plus image-named files
  /// the empty & unreadable checks flagged).
  final int photosConsidered;

  /// Photos decoded and measured.
  final int photosMeasured;

  /// Pairs compared to look for sharper retakes.
  final int retakePairs;

  /// Of those, pairs alike enough to need the fine-detail check.
  final int detailChecks;

  /// Time spent decoding and measuring (summed across parallel work).
  final Duration decodeTime;
  final Duration measureTime;
  final Duration elapsed;

  Map<String, int> get countsByRule => {
        for (final rule in BlurRule.values)
          if (verdicts.any((v) => v.rule == rule))
            rule.code: verdicts.where((v) => v.rule == rule).length,
      };
}

/// The blurry photo deep scan's pipeline (ruleset in
/// `docs/BLURRY_PHOTO_RULESET.md`):
///
/// 1. leave out photos the empty & unreadable deep scan flags (reported
///    under its rules), screenshots, formats this device can't decode;
/// 2. decode each photo to a [BlurryPhotoRules.analysisSize] thumbnail
///    (never upscaled); drop icons, blank and featureless photos;
/// 3. measure edge widths per tile and direction ([BlurMeasurement]);
/// 4. look for sharper retakes of soft photos among shots taken close in
///    time (the duplicate photo scan's comparison);
/// 5. apply B01 → B04 → B03 → B02 and rank blurriest first.
final class BlurryPhotoAnalyzer {
  BlurryPhotoAnalyzer({
    this.rules = const BlurryPhotoRules(),
    EmptyUnreadableAnalyzer? health,
  }) : health = health ?? EmptyUnreadableAnalyzer();

  final BlurryPhotoRules rules;

  /// Says which photos are empty or unreadable. Share one analyzer with the
  /// empty & unreadable detectors in the same [ScanEngine] so each file is
  /// checked once.
  final EmptyUnreadableAnalyzer health;

  final _runs = Expando<Future<BlurryAnalysis>>();

  /// The most recent completed analysis.
  BlurryAnalysis? lastResult;

  /// A [WasteDetector] for this scan, filing findings under [category].
  WasteDetector detector(WasteCategory category) =>
      DeepBlurryPhotoDetector(this, category);

  Future<BlurryAnalysis> analyze(
          ScanContext context, WasteCategory progressCategory) =>
      _runs[context] ??= _run(context, progressCategory);

  Future<BlurryAnalysis> _run(
      ScanContext context, WasteCategory category) async {
    final clock = Stopwatch()..start();
    final source = context.source;
    final observations = <BlurObservation>[];

    // 1. Empty and unreadable photos, from that scan.
    final checked = await health.analyze(context, category);
    final healthPhotos = [
      for (final v in checked.verdicts)
        if (_imageNamed(v.item.displayName)) v
    ]..sort((a, b) => a.item.id.compareTo(b.item.id));
    final flagged = {for (final v in healthPhotos) v.item.id};
    final photos = [
      for (final item in context.items)
        if (item.isPhoto && !flagged.contains(item.id)) item
    ]..sort((a, b) => a.id.compareTo(b.id));

    // 2–3. Decode and measure.
    final measured = List<_Measured?>.filled(photos.length, null);
    var decodeMicros = 0, measureMicros = 0;
    var next = 0, done = 0;
    Future<void> worker() async {
      while (next < photos.length) {
        final i = next++;
        final item = photos[i];
        void note(BlurObservationKind kind, String detail) =>
            observations.add(BlurObservation(kind, [item.id], detail));
        if (_isScreenshot(item)) {
          note(BlurObservationKind.screenshot,
              'a screenshot, not a camera photo');
        } else if (!source.canDecodeThumbnail(item)) {
          note(BlurObservationKind.cantDecode,
              "can't decode .${item.extension} on this device");
        } else if (item.sizeBytes > rules.maxPhotoBytes) {
          note(BlurObservationKind.tooLarge,
              'larger than ${rules.maxPhotoBytes ~/ (1024 * 1024)} MB');
        } else {
          final watch = Stopwatch()..start();
          try {
            var thumb = await source.loadThumbnail(item, rules.analysisSize);
            if (thumb != null) {
              final shorter = math.min(thumb.sourceWidth, thumb.sourceHeight);
              // Never measure an upscaled photo: upscaling itself blurs.
              if (shorter >= rules.minPhotoDimension &&
                  shorter < rules.analysisSize) {
                thumb = await source.loadThumbnail(item, shorter);
              }
            }
            decodeMicros += watch.elapsedMicroseconds;
            watch.reset();
            if (thumb == null) {
              note(
                  BlurObservationKind.undecodable,
                  "image data won't decode, but the empty & unreadable "
                  'checks passed it');
            } else if (math.min(thumb.sourceWidth, thumb.sourceHeight) <
                rules.minPhotoDimension) {
              note(
                  BlurObservationKind.tooSmall,
                  '${thumb.sourceWidth}×${thumb.sourceHeight} is an icon, '
                  'not a photo');
            } else {
              final m =
                  BlurMeasurement.fromThumbnail(thumb, rules.measureSettings);
              if (m.spread <= rules.blankMaxStdDev) {
                note(
                    BlurObservationKind.blank,
                    'flat colour (spread ${m.spread.toStringAsFixed(1)}); '
                    'left to the blank-photo scan');
              } else if (m.edgeCount < rules.minEdges || !m.judgeable) {
                note(
                    BlurObservationKind.lowDetail,
                    'only ${m.edgeCount} edges in ${m.tilesJudged} tiles: too '
                    'little detail to judge focus (fog, sky, a plain '
                    'surface or darkness)');
              } else {
                measured[i] =
                    _Measured(item, m, PhotoFingerprint.fromThumbnail(thumb));
              }
              measureMicros += watch.elapsedMicroseconds;
            }
          } on StorageReadException catch (e) {
            note(BlurObservationKind.unreadable, e.message);
          }
        }
        context.tick(category, ++done, photos.length);
      }
    }

    final workers = math.min(rules.concurrency, photos.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    final judged = [
      for (final m in measured)
        if (m != null) m
    ];

    // 4. Sharper retakes of soft photos: same layout by perceptual hash,
    // then the same fine detail once the sharper one is blurred to match.
    final matchRules = rules.retakeMatchRules;
    var pairs = 0, detailChecks = 0;
    final retakes = <String, Retake>{};
    final thumbs = <(String, int), Future<Thumbnail?>>{};
    Future<Thumbnail?> thumb(StorageItem item, int size) =>
        thumbs[(item.id, size)] ??= source.loadThumbnail(item, size);
    for (final a in judged) {
      if (a.m.blurWidth < rules.softWidth || a.item.modified == null) continue;
      Retake? best;
      for (final b in judged) {
        if (identical(a, b) || b.item.modified == null) continue;
        final gap = b.item.modified!.difference(a.item.modified!);
        if (gap.abs() > rules.retakeTimeWindow ||
            b.m.blurWidth > a.m.blurWidth * rules.retakeSharpnessRatio ||
            b.m.blurWidth >= rules.blurryWidth ||
            (best != null && b.m.blurWidth >= best.measurement.blurWidth)) {
          continue;
        }
        context.throwIfCancelled();
        pairs++;
        final check = comparePhotos(a.fp, b.fp, matchRules, shotAllowed: true);
        if (check == null ||
            !check.matched ||
            check.transform != PhotoTransform.none ||
            check.bordered) {
          continue;
        }
        final size = math.min(a.m.analysisSize, b.m.analysisSize);
        final Thumbnail? ta, tb;
        try {
          ta = await thumb(a.item, size);
          tb = await thumb(b.item, size);
        } on StorageReadException {
          continue;
        }
        if (ta == null || tb == null) continue;
        detailChecks++;
        final extra = math.sqrt(math.max(
                0,
                a.m.blurWidth * a.m.blurWidth -
                    b.m.blurWidth * b.m.blurWidth)) /
            _widthPerSigma;
        final agreement =
            detailAgreement(ta, tb, extra, maxShift: rules.retakeMaxShift);
        if (agreement < rules.retakeDetailAgreement) {
          observations.add(BlurObservation(
              BlurObservationKind.retakeRejected,
              [a.item.id, b.item.id],
              'same layout (${check.evidence}) but the fine detail differs '
              '(agreement ${agreement.toStringAsFixed(3)} < '
              '${rules.retakeDetailAgreement}): a different subject'));
          continue;
        }
        best = Retake(b.item, b.m, gap, check, agreement);
      }
      if (best != null) retakes[a.item.id] = best;
    }
    thumbs.clear();

    // 5. Rules and ranking.
    final verdicts = <BlurVerdict>[];
    final ranking = <RankedPhoto>[];
    for (final photo in judged) {
      final m = photo.m;
      final score = m.score(rules.sharpWidth);
      final verdict = _classify(
          photo,
          retakes[photo.item.id],
          score,
          (detail) => observations.add(BlurObservation(
              BlurObservationKind.suppressed, [photo.item.id], detail)));
      if (verdict != null) {
        verdicts.add(verdict);
      } else if (m.blurWidth >= rules.blurryWidth * rules.nearMissShare &&
          m.blurWidth < rules.blurryWidth) {
        observations.add(BlurObservation(
            BlurObservationKind.nearMiss,
            [photo.item.id],
            'blur width ${m.blurWidth.toStringAsFixed(2)}, just under '
            '${rules.blurryWidth}'));
      } else if (m.medianWidth >= rules.blurryWidth &&
          m.blurWidth < rules.softWidth) {
        observations.add(BlurObservation(
            BlurObservationKind.sharpSubject,
            [photo.item.id],
            'background soft (median edge ${m.medianWidth.toStringAsFixed(2)}) '
            'but the sharpest region is in focus '
            '(${m.blurWidth.toStringAsFixed(2)}): portrait mode or a '
            'panning shot'));
      }
      ranking.add(RankedPhoto(photo.item, m, score, verdict?.rule));
    }
    int blurriest(double a, double b, String ia, String ib) {
      final c = b.compareTo(a);
      return c != 0 ? c : ia.compareTo(ib);
    }

    verdicts.sort((a, b) => blurriest(a.measurement.blurWidth,
        b.measurement.blurWidth, a.item.id, b.item.id));
    ranking.sort((a, b) => blurriest(a.measurement.blurWidth,
        b.measurement.blurWidth, a.item.id, b.item.id));

    return lastResult = BlurryAnalysis(
      verdicts: verdicts,
      ranking: ranking,
      observations: observations
        ..sort((a, b) => a.ids.first.compareTo(b.ids.first)),
      health: healthPhotos,
      photosConsidered: photos.length + healthPhotos.length,
      photosMeasured: judged.length,
      retakePairs: pairs,
      detailChecks: detailChecks,
      decodeTime: Duration(microseconds: decodeMicros),
      measureTime: Duration(microseconds: measureMicros),
      elapsed: clock.elapsed,
    );
  }

  /// The first rule in precedence order that matches and is switched on.
  BlurVerdict? _classify(_Measured photo, Retake? retake, double score,
      void Function(String) suppressed) {
    final m = photo.m;
    final motion = m.blurWidth >= rules.softWidth &&
        m.motionWidth >= rules.motionMinWidth &&
        m.directionality >= rules.motionRatio;
    final how = motion
        ? 'smeared ${m.softestDirection.label} by camera shake or movement'
        : 'out of focus';
    final candidates = <(BlurRule, String)>[
      if (m.blurWidth >= rules.severeWidth)
        (BlurRule.b01Severe, 'Severely blurry: $how, nothing in it is sharp'),
      if (retake != null)
        (
          BlurRule.b04BlurryAttempt,
          'Blurry attempt: ${p.basename(retake.item.displayName)}, taken '
              '${retake.when}, is a sharper shot of the same scene'
        ),
      if (motion)
        (
          BlurRule.b03Motion,
          'Motion blur: $how (blurred '
              '${m.motionWidth.toStringAsFixed(1)} px one way, '
              '${m.crispWidth.toStringAsFixed(1)} px the other)'
        ),
      if (m.blurWidth >= rules.blurryWidth)
        (BlurRule.b02Blurry, 'Blurry: even the sharpest part is $how'),
    ];
    for (final (rule, reason) in candidates) {
      if (rules.disabledRules.contains(rule)) {
        suppressed('${rule.code} is disabled');
        continue;
      }
      if (!rule.confidence.atLeast(rules.minConfidence)) {
        suppressed('${rule.code} is ${rule.confidence.name}');
        return null;
      }
      return BlurVerdict(
        item: photo.item,
        rule: rule,
        measurement: m,
        score: score,
        reason: '$reason (blur score ${score.round()})',
        retake: rule == BlurRule.b04BlurryAttempt ? retake : null,
      );
    }
    return null;
  }

  bool _isScreenshot(StorageItem item) {
    if (item.displayName.toLowerCase().startsWith('screenshot')) return true;
    final parts = (item.path ?? item.id).toLowerCase().split(RegExp(r'[/\\]'));
    return parts
        .sublist(0, parts.length - 1)
        .any(rules.screenshotFolders.contains);
  }

  /// An image, or a partial download of one (`IMG_1.jpg.crdownload`).
  bool _imageNamed(String name) {
    if (mediaKindFor(name) == MediaKind.image) return true;
    final ext = extensionOf(name);
    return health.rules.partialDownloadExtensions.contains(ext) &&
        mediaKindFor(name.substring(0, name.length - ext.length - 1)) ==
            MediaKind.image;
  }
}

/// A Gaussian blur of sigma s widens an edge's 10%–90% rise by about 2.56 s.
const _widthPerSigma = 2.56;

final class _Measured {
  _Measured(this.item, this.m, this.fp);
  final StorageItem item;
  final BlurMeasurement m;
  final PhotoFingerprint fp;
}

/// Blurry photos, as found by the deep scan. scan_engine has no blurry
/// photo category yet, so findings are filed under [category]; see the
/// ruleset's merge notes.
final class DeepBlurryPhotoDetector extends WasteDetector {
  const DeepBlurryPhotoDetector(this.analyzer, this.category);

  final BlurryPhotoAnalyzer analyzer;

  @override
  final WasteCategory category;

  @override
  Future<List<Finding>> detect(ScanContext context) async => [
        for (final v in (await analyzer.analyze(context, category)).verdicts)
          v.toFinding(category)
      ];
}
