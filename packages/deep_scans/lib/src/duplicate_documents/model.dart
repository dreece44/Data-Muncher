import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

import 'content.dart';
import 'rules.dart';

/// Why two documents matched (or nearly did), kept for tuning.
final class DocumentMatch {
  const DocumentMatch(this.rule, this.score, this.evidence);

  /// Null for a near miss.
  final DocumentRule? rule;

  /// How alike: 1 for F02/F03, shingle similarity for F04, the weakest
  /// page's brightness correlation for F05.
  final double score;
  final String evidence;

  Map<String, Object?> toJson() => {
        'rule': rule?.code,
        'score': double.parse(score.toStringAsFixed(3)),
        'evidence': evidence,
      };
}

/// What the keeper ranking knows about one document.
final class DocumentFacts {
  const DocumentFacts({
    required this.item,
    required this.content,
    this.secondhand = false,
    this.copyName = false,
    this.sharpness,
    this.pixels = 0,
  });

  final StorageItem item;
  final DocumentContent content;

  /// Lives in a folder that holds second-hand copies (Download, WhatsApp…).
  final bool secondhand;

  /// Name looks like a copy: "(1)", "copy", "- Copy".
  final bool copyName;

  /// Scans only: average sharpness of the scanned pages.
  final double? sharpness;

  /// Scans only: pixels in the first scanned page.
  final int pixels;

  Map<String, Object?> toJson() => {
        'id': item.id,
        'sizeBytes': item.sizeBytes,
        if (item.modified != null) 'modified': item.modified!.toIso8601String(),
        'format': content.format.name,
        if (content.words.isNotEmpty) 'words': content.words.length,
        if (content.pageCount > 0) 'pages': content.pageCount,
        if (sharpness != null)
          'sharpness': double.parse(sharpness!.toStringAsFixed(1)),
        'secondhand': secondhand,
        'copyName': copyName,
      };
}

/// One document in a group and how it relates to the copy being kept.
final class DocumentMember {
  const DocumentMember(this.facts, this.rule, [this.match]);

  final DocumentFacts facts;

  /// Null for the keeper.
  final DocumentRule? rule;

  /// Measurements behind [rule] (null for identical copies).
  final DocumentMatch? match;

  StorageItem get item => facts.item;
  bool get isKeeper => rule == null;

  Map<String, Object?> toJson() => {
        'role': rule?.code ?? 'keep',
        ...facts.toJson(),
        if (match != null) 'match': match!.toJson(),
      };
}

/// What kind of group this is, which decides how the keeper is chosen.
enum GroupKind {
  /// Copies of one document: keep the original.
  copies,

  /// Versions of a document (an F04 link): keep the newest.
  versions,

  /// Repeated scans of one paper (an F05 link): keep the clearest.
  scans,
}

/// A set of duplicate documents with one suggested to keep.
final class DocumentGroup {
  DocumentGroup(this.members, this.kind, this.keepReason)
      : assert(members.where((m) => m.isKeeper).length == 1);

  /// Keeper first, then the rest by path.
  final List<DocumentMember> members;
  final GroupKind kind;

  /// Why this copy was chosen to keep.
  final String keepReason;

  DocumentMember get keeper => members.first;
  Iterable<DocumentMember> get duplicates => members.skip(1);

  Confidence get confidence =>
      duplicates.every((m) => m.rule!.confidence == Confidence.certain)
          ? Confidence.certain
          : Confidence.likely;

  int get reclaimableBytes =>
      duplicates.fold(0, (s, m) => s + m.item.sizeBytes);

  String get reason {
    final counts = <DocumentRule, int>{};
    for (final m in duplicates) {
      counts[m.rule!] = (counts[m.rule!] ?? 0) + 1;
    }
    final parts = [
      for (final r in DocumentRule.values)
        if (counts[r] != null) '${counts[r]} ${_plural(r.label, counts[r]!)}'
    ];
    final what = switch (kind) {
      GroupKind.versions => '${members.length} versions of the same document',
      GroupKind.scans => '${members.length} scans of the same document',
      GroupKind.copies => '${members.length} copies of the same document',
    };
    return '$what (${parts.join(', ')}); keeping '
        '${p.basename(keeper.item.displayName)} ($keepReason)';
  }

  /// As a mass-scan finding. scan_engine has no duplicate-document category
  /// yet, so the caller says which one to file it under (see the ruleset's
  /// merge notes).
  Finding toFinding(WasteCategory category) => Finding(
        category: category,
        items: [for (final m in members) m.item],
        keep: keeper.item,
        reason: reason,
      );

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'confidence': confidence.name,
        'reason': reason,
        'keepReason': keepReason,
        'reclaimableBytes': reclaimableBytes,
        'members': [for (final m in members) m.toJson()],
      };
}

String _plural(String label, int n) {
  if (n == 1) return label;
  return label
      .replaceFirst('copy', 'copies')
      .replaceFirst('version', 'versions')
      .replaceFirst('scan', 'scans')
      .replaceFirst('another file', 'other files');
}

/// A document the scan left out, or a near-miss worth knowing about when
/// tuning.
final class DocumentObservation {
  const DocumentObservation(this.kind, this.ids, this.detail, {this.rule});

  final DocumentObservationKind kind;
  final List<String> ids;
  final String detail;

  /// For [DocumentObservationKind.empty] / [unreadable]: the empty &
  /// unreadable scan's rule code (E01, U06…).
  final String? rule;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'ids': ids,
        'detail': detail,
        if (rule != null) 'rule': rule,
      };
}

enum DocumentObservationKind {
  /// X01: empty; left to the empty-file scan.
  empty,

  /// X02: can't be opened or is damaged; left to the unreadable-file scan.
  unreadable,

  /// An unreadable document whose bytes are the start of a healthy one: a
  /// failed or interrupted download of it.
  partialCopy,

  /// X03: modified moments ago and may still be being written.
  beingWritten,

  /// X04: smaller than [DuplicateDocumentRules.minBytes].
  tooSmall,

  /// X05: an app's or the system's file.
  systemFile,

  /// Larger than [DuplicateDocumentRules.contentMaxBytes]: only identical
  /// copies checked.
  identicalOnly,

  /// A document format that normally has text, but none could be used:
  /// only F01, F02 and F05 apply.
  noText,

  /// Scanned pages that couldn't be decoded: F05 doesn't apply.
  scanUndecodable,

  /// Two documents that came close to matching but didn't.
  nearMiss,

  /// Linked through a chain of matches but not all alike, so split.
  split,

  /// A member dropped from its group (below the confidence threshold or a
  /// disabled rule).
  dropped,
}
