import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:scan_engine/scan_engine.dart';

import '../empty_unreadable/analyzer.dart';
import '../empty_unreadable/bytes.dart' show bytesAt;
import 'container.dart';
import 'model.dart';
import 'names.dart';
import 'rules.dart';

/// Everything one run of the large & old video analysis produced.
final class LargeOldVideoAnalysis {
  const LargeOldVideoAnalysis({
    required this.verdicts,
    required this.health,
    required this.batches,
    required this.ranking,
    required this.observations,
    required this.videosConsidered,
    required this.videoBytes,
    required this.containersRead,
    required this.projectsFound,
    required this.bytesRead,
    required this.elapsed,
  });

  static const empty = LargeOldVideoAnalysis(
      verdicts: [],
      health: [],
      batches: [],
      ranking: [],
      observations: [],
      videosConsidered: 0,
      videoBytes: 0,
      containersRead: 0,
      projectsFound: 0,
      bytesRead: 0,
      elapsed: Duration.zero);

  /// Videos flagged by V01–V14, by path.
  final List<VideoVerdict> verdicts;

  /// Video files the empty & unreadable checks flagged; reported under
  /// that scan's rules.
  final List<VideoHealth> health;

  /// The findings grouped for review: unplayable ones first, then by rule.
  final List<VideoBatch> batches;

  /// V10–V14 verdicts, largest first: where the space is.
  final List<VideoVerdict> ranking;
  final List<VideoObservation> observations;

  /// Video files found in storage (plus partial downloads of them).
  final int videosConsidered;

  /// Their total size.
  final int videoBytes;

  /// Videos whose container was opened and read.
  final int containersRead;

  /// Editing-project files found (X02).
  final int projectsFound;

  /// Bytes this scan read (headers, indexes, projects). The empty &
  /// unreadable checks' reads are counted in their own result.
  final int bytesRead;
  final Duration elapsed;

  /// Space freed by clearing every finding, broken files included.
  int get flaggedBytes =>
      verdicts.fold(0, (s, v) => s + v.item.sizeBytes) +
      health.fold(0, (s, h) => s + h.item.sizeBytes);

  Map<String, int> get countsByRule => {
        for (final rule in VideoRule.values)
          if (verdicts.any((v) => v.rule == rule))
            rule.code: verdicts.where((v) => v.rule == rule).length,
        for (final h in health)
          h.verdict.rule.code:
              health.where((x) => x.verdict.rule == h.verdict.rule).length,
      };
}

/// The large & old video deep scan's pipeline (ruleset in
/// `docs/LARGE_OLD_VIDEO_RULESET.md`):
///
/// 1. run the empty & unreadable checks; video files they flag are reported
///    under their rules;
/// 2. leave out videos in apps' own folders; find editing projects and
///    Live Photo stills;
/// 3. open each MP4/MOV/3GP, Matroska/WebM and AVI container: duration,
///    resolution, frame rate, codec, creation time, and the structure
///    checks behind V01–V04;
/// 4. decide when it was recorded (container, then name, then file date);
/// 5. apply V01 → V02 → V03 → V04 → V10 → V11 → V12 → V13 → V14, holding
///    V10–V14 back for recent videos, active editing projects and Live
///    Photos; rank by size and group into batches.
final class LargeOldVideoAnalyzer {
  LargeOldVideoAnalyzer({
    this.rules = const LargeOldVideoRules(),
    EmptyUnreadableAnalyzer? health,
  }) : health = health ?? EmptyUnreadableAnalyzer();

  final LargeOldVideoRules rules;

  /// Says which videos are empty or unreadable. Share one analyzer with the
  /// empty & unreadable detectors in the same [ScanEngine] so each file is
  /// checked once.
  final EmptyUnreadableAnalyzer health;

  final _runs = Expando<Future<LargeOldVideoAnalysis>>();

  /// The most recent completed analysis.
  LargeOldVideoAnalysis? lastResult;

  /// Containers this scan opens; other video extensions are judged by size
  /// and date (X07).
  static const parsedExtensions = {
    'mp4', 'm4v', 'mov', '3gp', '3g2', 'mkv', 'webm', 'avi', //
  };

  /// A [WasteDetector] for this scan, filing findings under [category].
  WasteDetector detector(WasteCategory category) =>
      DeepLargeOldVideoDetector(this, category);

  Future<LargeOldVideoAnalysis> analyze(
          ScanContext context, WasteCategory progressCategory) =>
      _runs[context] ??= _run(context, progressCategory);

  Future<LargeOldVideoAnalysis> _run(
      ScanContext context, WasteCategory category) async {
    final clock = Stopwatch()..start();
    final source = context.source;
    final observations = <VideoObservation>[];
    void note(VideoObservationKind kind, StorageItem item, String detail) =>
        observations.add(VideoObservation(kind, item.id, detail));

    // 1. Empty and unreadable files, from that scan.
    final checked = await health.analyze(context, category);
    final broken = {for (final v in checked.verdicts) v.item.id: v};

    // 2. Videos, Live Photo stills, editing projects.
    final videos = <StorageItem>[];
    final stills = <String>{};
    final projectItems = <StorageItem>[];
    for (final item in context.items) {
      final name = _withoutPartialExtension(item.displayName);
      final ext = extensionOf(name);
      if (rules.videoExtensions.contains(ext)) {
        videos.add(item);
      } else if (rules.livePhotoImageExtensions.contains(ext)) {
        stills.add(_stemKey(item, name));
      } else if (rules.projectExtensions.contains(ext)) {
        projectItems.add(item);
      }
    }
    videos.sort((a, b) => a.id.compareTo(b.id));
    var bytes = 0;
    final projects = <_Project>[
      for (final item in projectItems)
        await _readProject(context, item, (n) => bytes += n),
    ];

    final verdicts = List<VideoVerdict?>.filled(videos.length, null);
    final healthHits = <VideoHealth>[];
    var containers = 0, next = 0, done = 0;

    Future<void> check(int i) async {
      final item = videos[i];
      final name = _withoutPartialExtension(item.displayName);
      final folders = _folders(item);
      final named = matchVideoName(name, folders, rules.namePatterns);
      final videoSource = named?.source ?? sourceFromFolders(folders);

      final hit = broken[item.id];
      if (hit != null) {
        healthHits.add(VideoHealth(hit, videoSource));
        return;
      }
      final appFolder = _appFolder(folders);
      if (appFolder != null) {
        note(VideoObservationKind.appData, item,
            "in $appFolder: belongs to an app, not judged");
        return;
      }

      // 3. The container.
      VideoInfo? info;
      final ext = extensionOf(name);
      if (item.origin != ItemOrigin.fileSystem ||
          !source.canReadContent(item)) {
        note(VideoObservationKind.contentNotRead, item,
            "contents can't be read here; judged by size and date only");
      } else if (!parsedExtensions.contains(ext)) {
        note(VideoObservationKind.notParsed, item,
            '.$ext isn\'t opened by this scan; judged by size and date only');
      } else {
        try {
          info = await readVideoInfo(source, item, rules, (n) => bytes += n);
        } on StorageReadException catch (e) {
          note(VideoObservationKind.unreadable, item, e.message);
          return;
        }
        if (info == null) {
          note(
              VideoObservationKind.notParsed,
              item,
              'not an MP4, Matroska or AVI file inside; judged by size and '
              'date only');
        } else {
          containers++;
          if (info.indexSkipped) {
            note(
                VideoObservationKind.indexNotRead,
                item,
                'index is over ${formatBytes(rules.maxIndexBytes)}; judged '
                'by size and date only');
          }
        }
      }

      // 4. When it was recorded.
      final (recorded, from) =
          _recorded(item, info, named, context.now, observations);

      // 5. Rules.
      final candidates = <_Candidate>[];
      final problem = info?.problem;
      if (problem != null) {
        final modified = item.modified;
        if (modified != null &&
            context.now.difference(modified) <
                health.rules.recentlyModifiedGrace) {
          note(
              VideoObservationKind.stillWriting,
              item,
              'would be ${problem.rule.code} (${problem.evidence}), but it '
              'was modified ${_ago(context.now.difference(modified))} and '
              'may still be recording; judged once '
              '${health.rules.recentlyModifiedGrace.inMinutes} min have '
              'passed');
          return;
        }
        candidates.add(_Candidate(problem.rule, problem.reason,
            problem.rule.confidence, problem.evidence));
      }
      candidates.addAll(_reclaimCandidates(
          item, info, named, videoSource, recorded, from, context.now));
      verdicts[i] = _classify(item, candidates, info, named, videoSource,
          recorded, from, folders, stills, projects, context.now, observations);
    }

    Future<void> worker() async {
      while (next < videos.length) {
        final i = next++;
        await check(i);
        context.tick(category, ++done, videos.length);
      }
    }

    final workers = math.min(rules.concurrency, videos.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);

    final found = [
      for (final v in verdicts)
        if (v != null) v
    ];
    healthHits.sort((a, b) => a.item.id.compareTo(b.item.id));
    final ranking = [
      for (final v in found)
        if (!v.rule.health) v
    ]..sort((a, b) => b.item.sizeBytes.compareTo(a.item.sizeBytes));
    return lastResult = LargeOldVideoAnalysis(
      verdicts: found,
      health: healthHits,
      batches: _batches(found, healthHits),
      ranking: ranking,
      observations: observations..sort((a, b) => a.id.compareTo(b.id)),
      videosConsidered: videos.length,
      videoBytes: videos.fold(0, (s, v) => s + v.sizeBytes),
      containersRead: containers,
      projectsFound: projects.length,
      bytesRead: bytes,
      elapsed: clock.elapsed,
    );
  }

  /// The recorded date and where it came from: the container's creation
  /// time if it makes sense, else a date in the name, else the file date.
  (DateTime?, RecordedFrom) _recorded(StorageItem item, VideoInfo? info,
      VideoName? named, DateTime now, List<VideoObservation> observations) {
    bool sane(DateTime t) =>
        t.isAfter(DateTime.utc(1995)) &&
        t.isBefore(now.add(const Duration(days: 1)));
    var (recorded, from) = (item.modified, RecordedFrom.modified);
    final created = info?.created;
    if (created != null && sane(created)) {
      (recorded, from) = (created.toLocal(), RecordedFrom.metadata);
    } else {
      if (created != null) {
        observations.add(VideoObservation(
            VideoObservationKind.badMetadataDate,
            item.id,
            'container says it was made ${created.toIso8601String()}; '
            'ignored (camera clock not set?)'));
      }
      final fromName = named?.recorded;
      if (fromName != null && sane(fromName)) {
        (recorded, from) = (fromName, RecordedFrom.name);
      }
    }
    if (recorded == null) return (null, RecordedFrom.unknown);
    final modified = item.modified;
    if (from != RecordedFrom.modified &&
        modified != null &&
        item.sizeBytes >= rules.oldMinBytes &&
        modified.difference(recorded).abs() > rules.dateDisagreement) {
      observations.add(VideoObservation(
          VideoObservationKind.datesDisagree,
          item.id,
          'recorded ${_date(recorded)} (from its ${from.name}), but the file '
          'is dated ${_date(modified)} (copied or downloaded later?); the '
          'recorded date is used'));
    }
    return (recorded, from);
  }

  /// V10–V14, in precedence order, for every one that matches.
  List<_Candidate> _reclaimCandidates(
      StorageItem item,
      VideoInfo? info,
      VideoName? named,
      VideoSource source,
      DateTime? recorded,
      RecordedFrom from,
      DateTime now) {
    final r = rules;
    final size = item.sizeBytes;
    final age = recorded == null ? null : now.difference(recorded);
    final old = age != null && age >= r.oldAge;
    final ageConfidence =
        from == RecordedFrom.metadata || from == RecordedFrom.name
            ? Confidence.certain
            : Confidence.likely;
    final what = _describe(size, source, named, info);
    final when = recorded == null ? '' : ' from ${_date(recorded)}';
    final ageEvidence = recorded == null
        ? 'age unknown'
        : 'recorded ${_ago(age!)} (${from.name})';
    return [
      if (old && size >= r.largeBytes)
        _Candidate(VideoRule.v10OldLarge, 'Old and large: $what$when',
            ageConfidence, '$ageEvidence; ${formatBytes(size)}'),
      if (size >= r.hugeBytes)
        _Candidate(VideoRule.v11Huge, 'Huge video: $what$when',
            Confidence.certain, formatBytes(size)),
      if (_oversized(item, info) case final oversized?) oversized,
      if (size >= r.largeBytes)
        _Candidate(VideoRule.v13Large, 'Large video: $what$when',
            Confidence.certain, formatBytes(size)),
      if (old && size >= r.oldMinBytes)
        _Candidate(VideoRule.v14Old, 'Old video: $what$when', ageConfidence,
            ageEvidence),
    ];
  }

  /// V12: far more data per pixel than a delivery codec needs.
  _Candidate? _oversized(StorageItem item, VideoInfo? info) {
    final r = rules;
    final size = item.sizeBytes;
    final secs = (info?.duration?.inMicroseconds ?? 0) / 1e6;
    if (info == null || !info.hasPicture || secs <= 0) return null;
    if (size < r.oversizedMinBytes) return null;
    final fps = info.frameRate ?? r.assumedFrameRate;
    final pixels = info.width! * info.height! * fps * secs;
    final bpp = size * 8 / pixels;
    final codecName = _codecName(info.codec);
    final intermediate =
        info.codec != null && r.intermediateCodecs.contains(info.codec);
    final target = (r.reencodeBitsPerPixel * pixels / 8).round();
    final saving = size - target;
    if (!(bpp >= r.oversizedBitsPerPixel || intermediate) ||
        saving < r.minSavingShare * size) {
      return null;
    }
    final mbps = size * 8 / secs / 1e6;
    final times = bpp / r.reencodeBitsPerPixel;
    return _Candidate(
        VideoRule.v12Oversized,
        'Recorded at ${_rate(mbps)}'
            '${codecName == null ? '' : ' in $codecName'}: about '
            '${times >= 10 ? times.round() : times.toStringAsFixed(1)}× what '
            '${_resolution(info)} needs; re-encoding would save about '
            '${formatBytes(saving)}',
        info.frameRate == null ? Confidence.likely : Confidence.certain,
        '${bpp.toStringAsFixed(bpp < 0.01 ? 5 : 3)} bits/pixel/frame at '
            '${fps.toStringAsFixed(2)} fps'
            '${info.frameRate == null ? ' (assumed)' : ''}'
            '${intermediate ? ', ${info.codec} is an editing/capture codec' : ''}'
            '; target ${formatBytes(target)}',
        saving: saving);
  }

  /// The first candidate in precedence order that is switched on, sure
  /// enough, and not held back; or null (with the reason noted).
  VideoVerdict? _classify(
      StorageItem item,
      List<_Candidate> candidates,
      VideoInfo? info,
      VideoName? named,
      VideoSource source,
      DateTime? recorded,
      RecordedFrom from,
      List<String> folders,
      Set<String> stills,
      List<_Project> projects,
      DateTime now,
      List<VideoObservation> observations) {
    void note(VideoObservationKind kind, String detail) =>
        observations.add(VideoObservation(kind, item.id, detail));
    candidates.sort((a, b) => a.rule.index.compareTo(b.rule.index));
    for (var i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      if (rules.disabledRules.contains(c.rule)) {
        note(VideoObservationKind.suppressed, '${c.rule.code} is disabled');
        continue;
      }
      if (!c.confidence.atLeast(rules.minConfidence)) {
        note(VideoObservationKind.suppressed,
            '${c.rule.code} is ${c.confidence.name} (${c.evidence})');
        continue;
      }
      if (!c.rule.health) {
        final would =
            '(would be ${c.rule.code}, ${formatBytes(item.sizeBytes)})';
        if (extensionOf(item.displayName) == 'mov' &&
            stills.contains(_stemKey(item, item.displayName))) {
          note(VideoObservationKind.livePhoto,
              'the movie half of a Live Photo; deleting it leaves a still $would');
          return null;
        }
        final project = _activeProject(item, folders, projects, now);
        if (project != null) {
          note(VideoObservationKind.activeProject, '$project $would');
          return null;
        }
        final age = recorded == null ? null : now.difference(recorded);
        if (age != null && age < rules.recentWindow) {
          note(
              VideoObservationKind.recent,
              'recorded ${_ago(age)}; videos newer than '
              '${rules.recentWindow.inDays} days are kept $would');
          return null;
        }
      }
      final also = [
        for (final o in candidates.skip(i + 1))
          if (!o.rule.health && o.rule != c.rule)
            VideoSignal(o.rule, o.evidence)
      ];
      final saving = c.saving ??
          candidates
              .skip(i + 1)
              .where((o) => o.saving != null)
              .firstOrNull
              ?.saving;
      final projectNote =
          c.rule.health ? null : _inactiveProject(item, folders, projects, now);
      return VideoVerdict(
        item: item,
        rule: c.rule,
        confidence: c.confidence,
        reason: c.reason,
        source: source,
        tool: named?.tool,
        app: named?.app,
        recorded: recorded,
        recordedFrom: from,
        info: info,
        evidence:
            projectNote == null ? c.evidence : '${c.evidence}; $projectNote',
        alsoMatched: also,
        estimatedSavingBytes: saving,
      );
    }
    return null;
  }

  /// "used by …, changed 2 days ago" for the first active project that
  /// uses [item], or null.
  String? _activeProject(StorageItem item, List<String> folders,
      List<_Project> projects, DateTime now) {
    for (final pr in projects) {
      if (!pr.isActive(now, rules.activeProjectWindow)) continue;
      final how = pr.uses(item, folders);
      if (how != null) {
        return '$how ${pr.item.displayName}, changed '
            '${_ago(now.difference(pr.item.modified!))}';
      }
    }
    return null;
  }

  /// Evidence for a flagged video that an old project used.
  String? _inactiveProject(StorageItem item, List<String> folders,
      List<_Project> projects, DateTime now) {
    for (final pr in projects) {
      if (pr.isActive(now, rules.activeProjectWindow)) continue;
      final how = pr.uses(item, folders);
      if (how != null) {
        final when = pr.item.modified == null
            ? ''
            : ', last changed ${_ago(now.difference(pr.item.modified!))}';
        return '$how ${pr.item.displayName}$when (not active)';
      }
    }
    return null;
  }

  Future<_Project> _readProject(
      ScanContext context, StorageItem item, void Function(int) onRead) async {
    final folder = _folderKey(item);
    if (item.origin != ItemOrigin.fileSystem ||
        !context.source.canReadContent(item) ||
        item.sizeBytes > rules.projectMaxBytes) {
      return _Project(item, folder, null);
    }
    try {
      var data = await context.source.readRange(item, 0, item.sizeBytes);
      onRead(data.length);
      if (bytesAt(data, 0, const [0x1F, 0x8B])) {
        data = Uint8List.fromList(const GZipDecoder().decodeBytes(data));
      }
      if (bytesAt(data, 0, const [0x50, 0x4B])) {
        return _Project(item, folder, null); // A ZIP: can't search cheaply.
      }
      // Projects store paths as UTF-8 (XML, JSON) or UTF-16 (Vegas, some
      // Windows tools); search both.
      final utf16 = StringBuffer();
      for (var i = 0; i + 1 < data.length; i += 2) {
        utf16.writeCharCode(data[i] | data[i + 1] << 8);
      }
      return _Project(item, folder, [
        utf8.decode(data, allowMalformed: true).toLowerCase(),
        utf16.toString().toLowerCase(),
      ]);
    } on Object {
      return _Project(item, folder, null);
    }
  }

  List<VideoBatch> _batches(
      List<VideoVerdict> verdicts, List<VideoHealth> healthHits) {
    Map<String, int> sources(Iterable<VideoSource> all) {
      final out = <String, int>{};
      for (final s in all) {
        out[s.label] = (out[s.label] ?? 0) + 1;
      }
      return out;
    }

    List<StorageItem> largestFirst(Iterable<StorageItem> items) =>
        items.toList()..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));

    VideoBatch? batch(String id, String label, Set<VideoRule> rules,
        {bool preselect = false, bool withSaving = false}) {
      final these = [
        for (final v in verdicts)
          if (rules.contains(v.rule)) v
      ];
      if (these.isEmpty) return null;
      return VideoBatch(id, label, largestFirst(these.map((v) => v.item)),
          preselect: preselect,
          sources: sources(these.map((v) => v.source)),
          estimatedSavingBytes: withSaving
              ? these.fold<int>(0, (s, v) => s + (v.estimatedSavingBytes ?? 0))
              : null);
    }

    final unplayable = [
      for (final v in verdicts)
        if (v.rule.preselect) v
    ];
    return [
      if (healthHits.isNotEmpty || unplayable.isNotEmpty)
        VideoBatch(
            'unplayable',
            "Videos that can't be played",
            largestFirst([
              for (final h in healthHits) h.item,
              for (final v in unplayable) v.item,
            ]),
            preselect: true,
            sources: sources([
              for (final h in healthHits) h.source,
              for (final v in unplayable) v.source,
            ])),
      ...[
        batch('damaged', 'Damaged & interrupted recordings',
            {VideoRule.v03Damaged, VideoRule.v04Interrupted}),
        batch('oldLarge', 'Old & large videos', {VideoRule.v10OldLarge}),
        batch('huge', 'Huge videos', {VideoRule.v11Huge}),
        batch('oversized', 'Recordings that could be compressed',
            {VideoRule.v12Oversized},
            withSaving: true),
        batch('large', 'Large videos', {VideoRule.v13Large}),
        batch('old', 'Old videos', {VideoRule.v14Old}),
      ].nonNulls,
    ];
  }

  /// The app folder above [folders] (`android/data`), or null.
  String? _appFolder(List<String> folders) {
    for (final seq in rules.appDataFolders) {
      for (var i = 0; i + seq.length <= folders.length; i++) {
        var match = true;
        for (var j = 0; j < seq.length; j++) {
          if (folders[i + j] != seq[j]) {
            match = false;
            break;
          }
        }
        if (match) return seq.join('/');
      }
    }
    return null;
  }

  /// `Screenshot_1.mp4.part` → `Screenshot_1.mp4`.
  String _withoutPartialExtension(String name) {
    final ext = extensionOf(name);
    return health.rules.partialDownloadExtensions.contains(ext)
        ? name.substring(0, name.length - ext.length - 1)
        : name;
  }

  /// Folders above the file, lower case, nearest last.
  static List<String> _folders(StorageItem item) {
    final parts = (item.path ?? item.id).toLowerCase().split(RegExp(r'[/\\]'));
    return parts.sublist(0, parts.length - 1);
  }

  static String _folderKey(StorageItem item) => _folders(item).join('/');

  /// Folder and name without extension, lower case: matches a Live Photo's
  /// still to its movie.
  static String _stemKey(StorageItem item, String name) {
    final dot = name.lastIndexOf('.');
    return '${_folderKey(item)}/'
        '${(dot > 0 ? name.substring(0, dot) : name).toLowerCase()}';
  }
}

final class _Candidate {
  const _Candidate(this.rule, this.reason, this.confidence, this.evidence,
      {this.saving});

  final VideoRule rule;
  final String reason;
  final Confidence confidence;
  final String evidence;
  final int? saving;
}

/// An editing project. [texts] is its contents (as UTF-8 and as UTF-16, lower
/// case) to search for video names, or null when it can't be searched (a
/// ZIP, too large, unreadable): then it covers the videos in its folder and
/// below.
final class _Project {
  _Project(this.item, this.folder, this.texts);

  final StorageItem item;
  final String folder;
  final List<String>? texts;

  bool isActive(DateTime now, Duration window) {
    final m = item.modified;
    return m != null && now.difference(m) <= window;
  }

  /// How this project uses [video] ("used by", "next to"), or null.
  String? uses(StorageItem video, List<String> videoFolders) {
    final t = texts;
    if (t != null) {
      final name = video.displayName.toLowerCase();
      return t.any((s) => s.contains(name)) ? 'used by' : null;
    }
    final here = videoFolders.join('/');
    return here == folder || here.startsWith('$folder/')
        ? 'next to (and possibly used by)'
        : null;
  }
}

String? _codecName(String? codec) => switch (codec) {
      null => null,
      'apco' || 'apcs' || 'apcn' || 'apch' || 'ap4h' || 'ap4x' => 'ProRes',
      'v_prores' => 'ProRes',
      'avdn' || 'avdh' => 'DNxHD',
      'mjpa' || 'mjpb' || 'mjpg' || 'jpeg' || 'v_mjpeg' => 'Motion JPEG',
      'ulrg' ||
      'ulra' ||
      'uly0' ||
      'uly2' ||
      'uly4' ||
      'ulh0' ||
      'ulh2' =>
        'Ut Video (lossless)',
      'ffv1' || 'v_ffv1' => 'FFV1 (lossless)',
      'lags' => 'Lagarith (lossless)',
      'hfyu' => 'HuffYUV (lossless)',
      'fps1' => 'the Fraps codec',
      'cfhd' => 'CineForm',
      'raw ' ||
      'v210' ||
      '2vuy' ||
      'yuv2' ||
      'v_uncompressed' =>
        'uncompressed video',
      _ => null,
    };

String _resolution(VideoInfo info) {
  final short = math.min(info.width!, info.height!);
  final name = switch (short) {
    >= 2160 => '4K',
    >= 1440 => '1440p',
    >= 1080 => '1080p',
    >= 720 => '720p',
    _ => '${info.width}×${info.height}',
  };
  final fps = info.frameRate;
  return fps == null ? name : '$name at ${fps.round()} fps';
}

String _rate(double mbps) => mbps >= 1
    ? '${mbps.toStringAsFixed(mbps < 10 ? 1 : 0)} Mbit/s'
    : '${(mbps * 1000).round()} kbit/s';

/// "1.5 GB game recording (OBS, Starfall Odyssey), 25 min".
String _describe(
    int size, VideoSource source, VideoName? named, VideoInfo? info) {
  final by = [
    if (named != null && named.tool != 'camera') named.tool,
    if (named?.app != null) named!.app!,
  ];
  final duration = info?.duration;
  return '${formatBytes(size)} ${source.noun}'
      '${by.isEmpty ? '' : ' (${by.join(', ')})'}'
      '${duration == null ? '' : ', ${formatDuration(duration)}'}';
}

String _date(DateTime t) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${t.day} ${months[t.month - 1]} ${t.year}';
}

String _ago(Duration d) {
  if (d.inDays >= 730) return '${d.inDays ~/ 365} years ago';
  if (d.inDays >= 60) return '${d.inDays ~/ 30} months ago';
  if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  if (d.inHours >= 1) return '${d.inHours} h ago';
  return '${math.max(0, d.inMinutes)} min ago';
}

/// Large and old videos, as found by the deep scan. scan_engine has no video
/// category yet, so findings are filed under [category]; see the ruleset's
/// merge notes.
final class DeepLargeOldVideoDetector extends WasteDetector {
  const DeepLargeOldVideoDetector(this.analyzer, this.category);

  final LargeOldVideoAnalyzer analyzer;

  @override
  final WasteCategory category;

  @override
  Future<List<Finding>> detect(ScanContext context) async => [
        for (final v in (await analyzer.analyze(context, category)).verdicts)
          v.toFinding(category)
      ];
}
