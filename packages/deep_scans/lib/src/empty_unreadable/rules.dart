import 'package:scan_engine/scan_engine.dart';

import '../shared/confidence.dart';

export '../shared/confidence.dart';

/// Every rule the empty & unreadable deep scan applies, in precedence order:
/// a file gets at most one finding, from the first rule that matches.
///
/// Documented in `docs/EMPTY_UNREADABLE_RULESET.md`; keep the two in sync.
enum DeepRule {
  e01ZeroBytes('E01', WasteCategory.emptyFile, 'Zero-byte file'),
  u03UnfinishedDownload(
      'U03', WasteCategory.unreadableFile, 'Unfinished download'),
  u01CannotOpen('U01', WasteCategory.unreadableFile, 'Cannot be opened'),
  u02ShortRead(
      'U02', WasteCategory.unreadableFile, 'Data shorter than reported size'),
  e02BlankContent('E02', WasteCategory.emptyFile, 'Only blank content'),
  u04ZeroFilled('U04', WasteCategory.unreadableFile, 'Zero-filled'),
  u05WrongContent(
      'U05', WasteCategory.unreadableFile, "Contents don't match the type"),
  u09GarbledText('U09', WasteCategory.unreadableFile, 'Garbled text'),
  e03EmptyDocument(
      'E03', WasteCategory.emptyFile, 'Document with no entries or text'),
  e04EmptyArchive('E04', WasteCategory.emptyFile, 'Archive with nothing in it'),
  e05EmptyMedia('E05', WasteCategory.emptyFile, 'Media with no content'),
  u06CutOff('U06', WasteCategory.unreadableFile, 'Cut off / unfinished'),
  u07Corrupt('U07', WasteCategory.unreadableFile, 'Internal structure damaged'),
  u08Undecodable('U08', WasteCategory.unreadableFile, "Image won't decode");

  const DeepRule(this.code, this.category, this.title);

  /// Stable id used in the ruleset doc, reports and test expectations.
  final String code;
  final WasteCategory category;
  final String title;

  static DeepRule? byCode(String code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// Thresholds and switches for the empty & unreadable deep scan. Every
/// number here is a tuning knob for the accuracy/performance pass; see the
/// ruleset doc for what each one trades off.
final class EmptyUnreadableRules {
  const EmptyUnreadableRules({
    this.ignoredEmptyFileNames = const {'.nomedia', '.gitkeep', '.keep'},
    this.ignoredEmptyExtensions = const {'lock'},
    this.partialDownloadExtensions = const {
      'crdownload', 'part', 'partial', 'download', 'opdownload', //
      '!ut', '!qb', 'bc!',
    },
    this.recentlyModifiedGrace = const Duration(minutes: 10),
    this.graceRules = const {
      DeepRule.e01ZeroBytes, DeepRule.e02BlankContent, //
      DeepRule.e05EmptyMedia, DeepRule.u02ShortRead,
      DeepRule.u03UnfinishedDownload, DeepRule.u04ZeroFilled,
      DeepRule.u06CutOff, DeepRule.u08Undecodable,
    },
    this.blankContentMaxBytes = 4096,
    this.headBytes = 4096,
    this.tailBytes = 22 + 65535,
    this.sampleBytes = 4096,
    this.fullReadMaxBytes = 32 * 1024 * 1024,
    this.structuredTextMaxBytes = 1024 * 1024,
    this.garbledControlRatio = 0.10,
    this.replacementCharMin = 8,
    this.replacementCharRatio = 0.02,
    this.concurrency = 4,
    this.minConfidence = Confidence.likely,
    this.disabledRules = const {},
    this.decodeImages = true,
  })  : assert(concurrency >= 1),
        assert(tailBytes >= 22 + 65535,
            'ZIP end records can sit this far from the end');

  /// Zero-byte files that exist on purpose (E01 exclusions).
  final Set<String> ignoredEmptyFileNames;

  /// Extensions whose zero-byte files are markers, not waste (E01).
  final Set<String> ignoredEmptyExtensions;

  /// Extensions download managers use until a download finishes (U03).
  final Set<String> partialDownloadExtensions;

  /// Files modified this recently may still be downloading, recording or
  /// saving. Findings from [graceRules] are held back for them.
  final Duration recentlyModifiedGrace;

  /// Rules a file that is still being written could trigger (it starts at 0
  /// bytes, then is partly filled, then gets its end markers). Rules not in
  /// here, like "PDF is really a web page", apply straight away.
  final Set<DeepRule> graceRules;

  /// Max size for "only whitespace / zero bytes" to count as empty (E02).
  /// Larger zero-filled files are U04 instead.
  final int blankContentMaxBytes;

  /// Bytes read from the start of every non-empty file.
  final int headBytes;

  /// Bytes read from the end of files whose format has an end marker.
  final int tailBytes;

  /// Size of the middle sample used by the zero-fill check (U04).
  final int sampleBytes;

  /// Files up to this size may be read whole for deep checks (PNG
  /// checksums, JPEG end-of-image search, PDF page count, RTF braces). Larger
  /// files only get the cheap checks.
  final int fullReadMaxBytes;

  /// Text formats up to this size are parsed for E03 / JSON validity.
  final int structuredTextMaxBytes;

  /// Share of control characters in a text file above which it's garbled
  /// (U09).
  final double garbledControlRatio;

  /// U09: a text file with at least this many U+FFFD replacement characters,
  /// making up at least [replacementCharRatio] of its characters, was
  /// damaged by a bad conversion.
  final int replacementCharMin;
  final double replacementCharRatio;

  /// Files checked at once.
  final int concurrency;

  /// Findings below this confidence are dropped.
  final Confidence minConfidence;

  /// Rules switched off for experiments. A file a disabled rule would have
  /// matched is reported clean (it doesn't fall through to later rules).
  final Set<DeepRule> disabledRules;

  /// Whether photos get a full decode test (U08). The slowest check.
  final bool decodeImages;
}
