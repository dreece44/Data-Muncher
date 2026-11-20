import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart';

import 'bytes.dart';
import 'file_probe.dart';
import 'formats.dart';
import 'rules.dart';
import 'text_checks.dart';
import 'verdict.dart';

/// Everything one run of the empty & unreadable analysis produced.
final class AnalysisResult {
  const AnalysisResult({
    required this.verdicts,
    required this.observations,
    required this.filesConsidered,
    required this.reads,
    required this.elapsed,
  });

  static final empty = AnalysisResult(
      verdicts: const [],
      observations: const [],
      filesConsidered: 0,
      reads: ReadStats(),
      elapsed: Duration.zero);

  final List<FileVerdict> verdicts;
  final List<FileObservation> observations;

  /// Files the analysis was able to look at (file-system items whose content
  /// can be read). Photo-library assets on iOS aren't included.
  final int filesConsidered;
  final ReadStats reads;
  final Duration elapsed;

  Map<String, int> get countsByRule => {
        for (final rule in DeepRule.values)
          if (verdicts.any((v) => v.rule == rule))
            rule.code: verdicts.where((v) => v.rule == rule).length,
      };
}

/// The empty & unreadable deep scan's rule pipeline (ruleset in
/// `docs/EMPTY_UNREADABLE_RULESET.md`).
///
/// Runs once per [ScanContext] and is shared by [DeepEmptyFileDetector] and
/// [DeepUnreadableFileDetector], so dropping both into a [ScanEngine] reads
/// each file only once.
final class EmptyUnreadableAnalyzer {
  EmptyUnreadableAnalyzer({this.rules = const EmptyUnreadableRules()});

  final EmptyUnreadableRules rules;
  final _runs = Expando<Future<AnalysisResult>>();

  /// The most recent completed analysis, for callers that ran it through a
  /// [ScanEngine] and want the rule-level detail.
  AnalysisResult? lastResult;

  /// Both detectors, sharing this analyzer.
  List<WasteDetector> detectors() =>
      [DeepEmptyFileDetector(this), DeepUnreadableFileDetector(this)];

  Future<AnalysisResult> analyze(
          ScanContext context, WasteCategory progressCategory) =>
      _runs[context] ??= _run(context, progressCategory);

  Future<AnalysisResult> _run(
      ScanContext context, WasteCategory progressCategory) async {
    final clock = Stopwatch()..start();
    final files = [
      for (final item in context.items)
        if (item.origin == ItemOrigin.fileSystem &&
            context.source.canReadContent(item))
          item,
    ];
    final stats = ReadStats();
    final verdicts = List<FileVerdict?>.filled(files.length, null);
    final observations = <FileObservation>[];

    var next = 0, done = 0;
    Future<void> worker() async {
      while (next < files.length) {
        final i = next++;
        verdicts[i] =
            await checkFile(context, files[i], stats, observations.add);
        context.tick(progressCategory, ++done, files.length);
      }
    }

    final workers =
        rules.concurrency < files.length ? rules.concurrency : files.length;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    observations.sort((a, b) => a.item.id.compareTo(b.item.id));

    return lastResult = AnalysisResult(
      verdicts: [
        for (final v in verdicts)
          if (v != null) v
      ],
      observations: observations,
      filesConsidered: files.length,
      reads: stats,
      elapsed: clock.elapsed,
    );
  }

  /// Applies the rules to one file. Returns null when the file is fine (or
  /// wasn't judged; [observe] says why).
  Future<FileVerdict?> checkFile(ScanContext context, StorageItem item,
      ReadStats stats, void Function(FileObservation) observe) async {
    final hit = await _firstHit(context, item, stats, observe);
    if (hit == null) return null;

    // A file still being downloaded, recorded or saved looks empty or cut
    // off. Hold those findings back until it has been left alone a while.
    final modified = item.modified;
    if (modified != null &&
        rules.graceRules.contains(hit.rule) &&
        context.now.difference(modified) < rules.recentlyModifiedGrace) {
      observe(FileObservation(
          item,
          ObservationKind.recentlyModified,
          'would be ${hit.rule.code} (${hit.reason}), but it was modified at '
          '$modified and may still be being written; judged once '
          '${rules.recentlyModifiedGrace.inMinutes} min have passed'));
      return null;
    }
    if (rules.disabledRules.contains(hit.rule) ||
        !hit.confidence.atLeast(rules.minConfidence)) {
      observe(FileObservation(item, ObservationKind.suppressed,
          '${hit.rule.code} (${hit.confidence.name}) ${hit.reason}'));
      return null;
    }
    return FileVerdict(
        item: item,
        rule: hit.rule,
        confidence: hit.confidence,
        reason: hit.reason,
        evidence: hit.evidence);
  }

  static final _androidPending = RegExp(r'^\.pending-\d+-');

  Future<Hit?> _firstHit(ScanContext context, StorageItem item, ReadStats stats,
      void Function(FileObservation) observe) async {
    final ext = item.extension;

    // E01 — nothing to read.
    if (item.sizeBytes == 0) {
      if (rules.ignoredEmptyFileNames.contains(item.displayName) ||
          rules.ignoredEmptyExtensions.contains(ext)) {
        return null;
      }
      return const Hit(DeepRule.e01ZeroBytes, Confidence.certain,
          'File is 0 bytes', 'size 0');
    }

    // U03 — judged on the name alone.
    if (rules.partialDownloadExtensions.contains(ext)) {
      return Hit(
          DeepRule.u03UnfinishedDownload,
          Confidence.certain,
          'Unfinished download: the download never completed',
          'temporary download extension .$ext');
    }
    if (_androidPending.hasMatch(item.displayName)) {
      return const Hit(
          DeepRule.u03UnfinishedDownload,
          Confidence.certain,
          'Unfinished save: the app writing this file never finished',
          'Android MediaStore ".pending-" name');
    }

    final probe = FileProbe(context.source, item, stats,
        headBytes: rules.headBytes,
        tailBytes: rules.tailBytes,
        fullReadMaxBytes: rules.fullReadMaxBytes);
    try {
      return await _contentHit(context, item, probe, observe);
    } on StorageReadException catch (e) {
      return Hit(DeepRule.u01CannotOpen, Confidence.certain,
          'File could not be opened (${e.message})', e.message);
    } on ShortReadException catch (e) {
      return Hit(
          DeepRule.u02ShortRead,
          Confidence.certain,
          'Only part of the file could be read; it may be stored online '
              'only, or damaged',
          'read ${e.got} of ${e.expected} bytes at offset ${e.offset}');
    }
  }

  Future<Hit?> _contentHit(ScanContext context, StorageItem item,
      FileProbe probe, void Function(FileObservation) observe) async {
    final ext = item.extension;
    final isText = textExtensions.contains(ext);
    final format = formatFor(ext);
    final head = await probe.head();

    // E02 — small and blank.
    if (item.sizeBytes <= rules.blankContentMaxBytes &&
        isBlank((await probe.all())!)) {
      return const Hit(DeepRule.e02BlankContent, Confidence.certain,
          'File contains only blank space', 'whitespace / zero bytes only');
    }

    // U04 — zero-filled (sampled at the start, middle and end).
    if (allZero(head)) {
      final rest = [
        ...await probe.middle(rules.sampleBytes),
        ...await probe.tail(rules.sampleBytes),
      ];
      if (allZero(rest)) {
        return Hit(
            DeepRule.u04ZeroFilled,
            format != null || isText ? Confidence.certain : Confidence.likely,
            'File is filled with zero bytes, likely a failed download or copy',
            'start, middle and end samples are all zero');
      }
      if (format != null || isText) {
        return Hit(
            DeepRule.u05WrongContent,
            Confidence.certain,
            "The start of the file is blank, so it can't be opened",
            'first ${head.length} bytes are zero; data follows');
      }
    }

    if (item.sizeBytes > rules.fullReadMaxBytes) {
      observe(FileObservation(
          item,
          ObservationKind.deepChecksSkipped,
          '${kb(item.sizeBytes)} is over the ${kb(rules.fullReadMaxBytes)} '
          'deep-check limit'));
    }

    if (isText) return _textHit(item, probe, head);
    if (format == null) return null; // Unknown type: nothing to validate.

    // U05 — does the content match the name?
    var spec = format;
    if (!format.matches(head)) {
      final real = sniffBinary(head);
      if (real == null) {
        final text = sniffTextKind(head);
        return Hit(
            DeepRule.u05WrongContent,
            Confidence.certain,
            text == 'a web page'
                ? 'Named .$ext but contains a web page (often a saved error '
                    'or sign-in page instead of the real file)'
                : text != null
                    ? 'Named .$ext but contains $text, not a ${format.name} '
                        'file'
                    : 'Contents are not a valid ${format.name} file',
            'signature mismatch; starts ${_preview(head)}');
      }
      observe(FileObservation(item, ObservationKind.misnamed,
          'named .$ext but is a ${real.name} file; checked as ${real.name}'));
      spec = real;
    }

    // E04 / E05 / U06 / U07 — format structure.
    final structural = await spec.check?.call(probe, rules);
    if (structural != null) return structural;

    // U08 — full decode, last because it's the slowest.
    if (rules.decodeImages &&
        item.isPhoto &&
        await context.analyzeImage(item) is UndecodableImage) {
      return const Hit(
          DeepRule.u08Undecodable,
          Confidence.certain,
          "Image data is damaged and can't be displayed",
          'image decoder could not decode it');
    }
    return null;
  }

  Future<Hit?> _textHit(
      StorageItem item, FileProbe probe, Uint8List head) async {
    final whole = item.sizeBytes <= rules.structuredTextMaxBytes
        ? await probe.all()
        : null;
    final garbled = garbledText(head, whole, rules);
    if (garbled != null || whole == null) return garbled;
    final text = decodeText(whole);
    if (text.trim().isEmpty) {
      return const Hit(DeepRule.e02BlankContent, Confidence.certain,
          'File contains only blank space', 'decoded text is whitespace');
    }
    return structuredText(item.extension, text);
  }

  static String _preview(List<int> head) => [
        for (final b in head.take(8)) b.toRadixString(16).padLeft(2, '0')
      ].join(' ');
}

/// Empty files, as found by the deep scan. Drop-in alternative to the mass
/// scan's `EmptyFileDetector`.
final class DeepEmptyFileDetector extends WasteDetector {
  const DeepEmptyFileDetector(this.analyzer);

  final EmptyUnreadableAnalyzer analyzer;

  @override
  WasteCategory get category => WasteCategory.emptyFile;

  @override
  Future<List<Finding>> detect(ScanContext context) async => [
        for (final v in (await analyzer.analyze(context, category)).verdicts)
          if (v.category == category) v.toFinding()
      ];
}

/// Unreadable files, as found by the deep scan. Drop-in alternative to the
/// mass scan's `UnreadableFileDetector`.
final class DeepUnreadableFileDetector extends WasteDetector {
  const DeepUnreadableFileDetector(this.analyzer);

  final EmptyUnreadableAnalyzer analyzer;

  @override
  WasteCategory get category => WasteCategory.unreadableFile;

  @override
  Future<List<Finding>> detect(ScanContext context) async => [
        for (final v in (await analyzer.analyze(context, category)).verdicts)
          if (v.category == category) v.toFinding()
      ];
}
