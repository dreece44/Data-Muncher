import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

import '../duplicate_photos/matcher.dart';
import '../duplicate_photos/rules.dart' show DuplicatePhotoRules;
import '../empty_unreadable/analyzer.dart';
import '../empty_unreadable/bytes.dart' show kb;
import '../empty_unreadable/rules.dart' show DeepRule;
import '../empty_unreadable/verdict.dart';
import 'content.dart';
import 'model.dart';
import 'page_match.dart';
import 'rules.dart';
import 'similarity.dart';

/// Everything one run of the duplicate document analysis produced.
final class DuplicateDocumentAnalysis {
  const DuplicateDocumentAnalysis({
    required this.groups,
    required this.observations,
    required this.filesConsidered,
    required this.documentsCompared,
    required this.bytesHashed,
    required this.bytesRead,
    required this.bytesInflated,
    required this.candidatePairs,
    required this.matchedPairs,
    required this.elapsed,
  });

  static const empty = DuplicateDocumentAnalysis(
      groups: [],
      observations: [],
      filesConsidered: 0,
      documentsCompared: 0,
      bytesHashed: 0,
      bytesRead: 0,
      bytesInflated: 0,
      candidatePairs: 0,
      matchedPairs: 0,
      elapsed: Duration.zero);

  /// Largest reclaimable space first.
  final List<DocumentGroup> groups;
  final List<DocumentObservation> observations;

  /// Non-image files found in storage.
  final int filesConsidered;

  /// Distinct healthy documents whose content was compared (one per set of
  /// identical copies).
  final int documentsCompared;

  /// Bytes read to find identical copies (F01) and failed downloads.
  final int bytesHashed;

  /// Bytes read to look inside documents (F02–F05).
  final int bytesRead;

  /// Bytes produced by inflating compressed PDF streams and office parts.
  final int bytesInflated;

  /// Pairs that got a full F04/F05 comparison, and how many pairs of
  /// distinct documents matched under any rule.
  final int candidatePairs;
  final int matchedPairs;
  final Duration elapsed;

  Map<String, int> get countsByRule => {
        for (final rule in DocumentRule.values)
          if (groups.any((g) => g.duplicates.any((m) => m.rule == rule)))
            rule.code: groups.fold(0,
                (s, g) => s + g.duplicates.where((m) => m.rule == rule).length),
      };
}

/// One healthy document, or a set of byte-identical copies of one, with
/// what its content checks found.
final class _Unit {
  _Unit(this.items);
  final List<StorageItem> items;
  StorageItem get rep => items.first;
  DocumentContent content = DocumentContent.binary;
  List<ScanPage> pages = const [];
  Set<int>? shingleSet;
  Set<String>? ids;
}

/// The duplicate document deep scan's pipeline (ruleset in
/// `docs/DUPLICATE_DOCUMENT_RULESET.md`):
///
/// 1. leave out empty and unreadable files (from the empty & unreadable
///    deep scan), files still being written, tiny files and app files;
/// 2. identical files by size → first 64 KB hash → full SHA-256 (F01);
/// 3. look inside one document per identical set: content key, text,
///    scanned pages;
/// 4. match: same content key (F02), same text (F03), MinHash candidates
///    compared by shingles (F04), scans compared page by page (F05);
/// 5. group so every member matches every other (complete linkage);
/// 6. pick the copy to keep;
/// 7. check whether unreadable documents are failed downloads of healthy
///    ones.
final class DuplicateDocumentAnalyzer {
  DuplicateDocumentAnalyzer({
    this.rules = const DuplicateDocumentRules(),
    this.scanRules = const DuplicatePhotoRules(),
    EmptyUnreadableAnalyzer? health,
    this.pageDecoder = const PureDartThumbnailDecoder(),
  }) : health = health ?? EmptyUnreadableAnalyzer();

  final DuplicateDocumentRules rules;

  /// Thresholds scanned pages are compared with (F05): the duplicate photo
  /// scan's copy and shot tests.
  final DuplicatePhotoRules scanRules;

  /// Says which files are empty or unreadable. Share one analyzer with the
  /// empty & unreadable detectors in the same [ScanEngine] so each file is
  /// checked once.
  final EmptyUnreadableAnalyzer health;

  /// Decodes the JPEG pages inside scanned PDFs.
  final ThumbnailDecoder pageDecoder;

  final _runs = Expando<Future<DuplicateDocumentAnalysis>>();

  /// The most recent completed analysis.
  DuplicateDocumentAnalysis? lastResult;

  /// A [WasteDetector] for this scan, filing groups under [category].
  WasteDetector detector(WasteCategory category) =>
      DeepDuplicateDocumentDetector(this, category);

  Future<DuplicateDocumentAnalysis> analyze(
          ScanContext context, WasteCategory progressCategory) =>
      _runs[context] ??= _run(context, progressCategory);

  Future<DuplicateDocumentAnalysis> _run(
      ScanContext context, WasteCategory category) async {
    final clock = Stopwatch()..start();
    final source = context.source;
    final observations = <DocumentObservation>[];
    final files = [
      for (final item in context.items)
        if (item.origin == ItemOrigin.fileSystem &&
            item.kind != MediaKind.image &&
            source.canReadContent(item))
          item
    ]..sort((a, b) => a.id.compareTo(b.id));

    // 1. What the empty & unreadable scan says, and other exclusions.
    final checked = await health.analyze(context, category);
    final verdicts = {for (final v in checked.verdicts) v.item.id: v};
    final writing = {
      for (final o in checked.observations)
        if (o.kind == ObservationKind.recentlyModified) o.item.id: o.detail
    };
    final healthy = <StorageItem>[];
    final broken = <FileVerdict>[];
    final grouped = <String, List<String>>{};
    for (final item in files) {
      final verdict = verdicts[item.id];
      final system = _systemReason(item);
      if (system != null) {
        (grouped[system] ??= []).add(item.id);
      } else if (verdict != null) {
        final empty = verdict.category == WasteCategory.emptyFile;
        observations.add(DocumentObservation(
            empty
                ? DocumentObservationKind.empty
                : DocumentObservationKind.unreadable,
            [item.id],
            '${verdict.reason}; left to the '
            '${empty ? 'empty' : 'unreadable'}-file scan',
            rule: verdict.rule.code));
        if (!empty) broken.add(verdict);
      } else if (writing.containsKey(item.id)) {
        observations.add(DocumentObservation(
            DocumentObservationKind.beingWritten,
            [item.id],
            writing[item.id]!));
      } else if (item.sizeBytes < rules.minBytes) {
        (grouped['tooSmall'] ??= []).add(item.id);
      } else {
        healthy.add(item);
      }
    }
    for (final e in grouped.entries) {
      observations.add(e.key == 'tooSmall'
          ? DocumentObservation(DocumentObservationKind.tooSmall, e.value,
              'smaller than ${rules.minBytes} bytes; not compared')
          : DocumentObservation(DocumentObservationKind.systemFile, e.value,
              '${e.key}; not compared'));
    }

    // 2. Identical files.
    var bytesHashed = 0;
    final sets = await _identicalSets(
        source, healthy, observations, (n) => bytesHashed += n);
    final inSet = {
      for (final s in sets)
        for (final i in s) i.id
    };
    final units = [
      for (final s in sets) _Unit(s),
      for (final i in healthy)
        if (!inSet.contains(i.id)) _Unit([i])
    ]..sort((a, b) => a.rep.id.compareTo(b.rep.id));

    // 3. Look inside each document.
    var bytesRead = 0, inflated = 0;
    for (var u = 0; u < units.length; u++) {
      final unit = units[u];
      final rep = unit.rep;
      context.tick(category, u + 1, units.length);
      if (rep.sizeBytes > rules.contentMaxBytes) {
        observations.add(DocumentObservation(
            DocumentObservationKind.identicalOnly,
            [for (final i in unit.items) i.id],
            '${kb(rep.sizeBytes)} is over the ${kb(rules.contentMaxBytes)} '
            'content limit; only identical copies checked'));
        continue;
      }
      final Uint8List bytes;
      try {
        bytes = await source.readRange(rep, 0, rep.sizeBytes);
      } on StorageReadException catch (e) {
        observations.add(DocumentObservation(
            DocumentObservationKind.unreadable, [rep.id], e.message));
        continue;
      }
      bytesRead += bytes.length;
      unit.content = readDocument(bytes, _innerExtension(rep), rules);
      inflated += unit.content.bytesInflated;
      final c = unit.content;
      if (c.noTextReason != null &&
          !c.isScan &&
          c.format != DocumentFormat.binary &&
          c.noTextReason != 'no text') {
        observations.add(DocumentObservation(DocumentObservationKind.noText,
            [rep.id], '${c.noTextReason}; only F01/F02 apply'));
      }
      if (c.isScan &&
          !rules.disabledRules.contains(DocumentRule.f05RepeatedScan)) {
        unit.pages = await _decodePages(c.scanPages);
        if (unit.pages.length != c.scanPages.length) {
          unit.pages = const [];
          observations.add(DocumentObservation(
              DocumentObservationKind.scanUndecodable,
              [rep.id],
              "scanned pages can't be decoded; F05 doesn't apply"));
        }
      }
    }

    // 4. Matches between units.
    final edges = <(int, int), DocumentMatch>{};
    void link(int a, int b, DocumentMatch m) {
      final key = a < b ? (a, b) : (b, a);
      if (rules.disabledRules.contains(m.rule)) {
        observations.add(DocumentObservation(
            DocumentObservationKind.dropped,
            [units[a].rep.id, units[b].rep.id],
            '${m.rule!.code} is disabled (${m.evidence})'));
        return;
      }
      edges.putIfAbsent(key, () => m);
    }

    void byKey(String? Function(_Unit) key,
        DocumentMatch Function(_Unit, _Unit) match) {
      final buckets = <String, List<int>>{};
      for (var i = 0; i < units.length; i++) {
        final k = key(units[i]);
        if (k != null) (buckets[k] ??= []).add(i);
      }
      for (final b in buckets.values) {
        for (var x = 0; x < b.length; x++) {
          for (var y = x + 1; y < b.length; y++) {
            if (!edges.containsKey((b[x], b[y]))) {
              link(b[x], b[y], match(units[b[x]], units[b[y]]));
            }
          }
        }
      }
    }

    // F02: same content key.
    byKey(
        (u) => u.content.contentKey == null
            ? null
            : '${u.content.format.name}:${u.content.contentKey}',
        (a, b) => DocumentMatch(
            DocumentRule.f02ReSaved, 1, 'same content: ${a.content.keyBasis}'));

    // F03: same text, enough of it.
    byKey(
        (u) => u.content.words.length >= rules.minTextWords
            ? u.content.textKey
            : null,
        (a, b) => DocumentMatch(
            DocumentRule.f03SameText,
            1,
            'same ${a.content.words.length} words '
            '(${a.content.format.label} and ${b.content.format.label})'));

    // F04: lightly edited versions.
    final hasher =
        MinHasher(bands: rules.minHashBands, rows: rules.minHashRows);
    final signatures = [
      for (final u in units)
        if (u.content.words.length >= rules.minVersionWords)
          hasher.signature(
              u.shingleSet = shingles(u.content.words, rules.shingleWords))
        else
          null
    ];
    final versionPairs = hasher.candidates(signatures);
    for (final (a, b) in versionPairs) {
      if (edges.containsKey((a, b))) continue;
      final m = _compareVersions(units[a], units[b]);
      if (m == null) continue;
      if (m.rule != null) {
        link(a, b, m);
      } else {
        observations.add(DocumentObservation(DocumentObservationKind.nearMiss,
            [units[a].rep.id, units[b].rep.id], m.evidence));
      }
    }

    // F05: repeated scans, page by page.
    var scanPairs = 0;
    final scans = [
      for (var i = 0; i < units.length; i++)
        if (units[i].pages.isNotEmpty) i
    ];
    for (var x = 0; x < scans.length; x++) {
      for (var y = x + 1; y < scans.length; y++) {
        final a = scans[x], b = scans[y];
        if (edges.containsKey((a, b)) ||
            units[a].pages.length != units[b].pages.length) {
          continue;
        }
        context.throwIfCancelled();
        scanPairs++;
        var m = _compareScans(units[a], units[b]);
        if (m == null) continue;
        final gap = _closestInTime(units[a], units[b]);
        if (m.rule != null && (gap == null || gap > rules.scanTimeWindow)) {
          m = DocumentMatch(
              null,
              m.score,
              gap == null
                  ? 'pages match, but there is no time to compare them by'
                  : 'pages match, but scanned ${_days(gap)} apart: '
                      'probably another document with the same layout and '
                      'wording (${m.evidence})');
        }
        if (m.rule != null) {
          link(a, b, m);
        } else {
          observations.add(DocumentObservation(DocumentObservationKind.nearMiss,
              [units[a].rep.id, units[b].rep.id], m.evidence));
        }
      }
    }

    // 5. Groups in which every document matches every other.
    final clusters = _cluster(units, edges, observations);

    // 6. Keeper and members.
    final groups = <DocumentGroup>[];
    for (final cluster in clusters) {
      if (cluster.fold(0, (n, i) => n + units[i].items.length) < 2) continue;
      final rulesIn = {
        for (final e in edges.entries)
          if (cluster.contains(e.key.$1) && cluster.contains(e.key.$2))
            e.value.rule
      };
      final kind = rulesIn.contains(DocumentRule.f04EditedVersion)
          ? GroupKind.versions
          : rulesIn.contains(DocumentRule.f05RepeatedScan)
              ? GroupKind.scans
              : GroupKind.copies;
      final group = _group(units, cluster, kind,
          (a, b) => edges[a < b ? (a, b) : (b, a)], observations);
      if (group != null) groups.add(group);
    }
    groups.sort((a, b) {
      final bySpace = b.reclaimableBytes.compareTo(a.reclaimableBytes);
      return bySpace != 0
          ? bySpace
          : a.keeper.item.id.compareTo(b.keeper.item.id);
    });

    // 7. Failed downloads of documents that are fine.
    bytesHashed += await _partialCopies(source, broken, healthy, observations);

    return lastResult = DuplicateDocumentAnalysis(
      groups: groups,
      observations: observations
        ..sort((a, b) => a.ids.first.compareTo(b.ids.first)),
      filesConsidered: files.length,
      documentsCompared:
          units.where((u) => u.content.format != DocumentFormat.binary).length,
      bytesHashed: bytesHashed,
      bytesRead: bytesRead,
      bytesInflated: inflated,
      candidatePairs: versionPairs.length + scanPairs,
      matchedPairs: edges.length,
      elapsed: clock.elapsed,
    );
  }

  // --- Exclusions ---------------------------------------------------------

  /// X05: why [item] is an app's or the system's file, or null.
  String? _systemReason(StorageItem item) {
    final name = item.displayName.toLowerCase();
    if (rules.ignoredNames.contains(name)) return 'system file ($name)';
    if (name.startsWith('.')) return 'hidden file';
    final path =
        '/${(item.path ?? item.id).toLowerCase().replaceAll(r'\', '/')}';
    for (final folder in rules.ignoredFolders) {
      if (path.contains('/$folder/')) return 'app files in $folder';
    }
    return null;
  }

  /// The extension a document will have once finished: "report.docx" for
  /// "report.docx.crdownload".
  String _innerExtension(StorageItem item) {
    final ext = item.extension;
    if (!health.rules.partialDownloadExtensions.contains(ext)) {
      return ext;
    }
    return extensionOf(item.displayName
        .substring(0, item.displayName.length - ext.length - 1));
  }

  // --- F01 ----------------------------------------------------------------

  /// Sets of byte-identical files: same size, then same first 64 KB, then
  /// same SHA-256. Only same-size files are ever read.
  Future<List<List<StorageItem>>> _identicalSets(
      StorageSource source,
      List<StorageItem> items,
      List<DocumentObservation> observations,
      void Function(int) countBytes) async {
    if (rules.disabledRules.contains(DocumentRule.f01Identical)) return [];
    final bySize = <int, List<StorageItem>>{};
    for (final i in items) {
      (bySize[i.sizeBytes] ??= []).add(i);
    }
    Future<Map<String, List<StorageItem>>> split(List<StorageItem> items,
        Future<String> Function(StorageItem) digest) async {
      final out = <String, List<StorageItem>>{};
      for (final i in items) {
        try {
          (out[await digest(i)] ??= []).add(i);
        } on StorageReadException catch (e) {
          observations.add(DocumentObservation(
              DocumentObservationKind.unreadable, [i.id], e.message));
        }
      }
      return out;
    }

    final sets = <List<StorageItem>>[];
    for (final same in bySize.values.where((s) => s.length > 1)) {
      final size = same.first.sizeBytes;
      final prefix = math.min(size, rules.prefixBytes);
      final byPrefix = await split(same, (i) async {
        countBytes(prefix);
        return sha256.convert(await source.readRange(i, 0, prefix)).toString();
      });
      for (final candidates in byPrefix.values.where((s) => s.length > 1)) {
        if (size <= rules.prefixBytes) {
          sets.add(candidates);
          continue;
        }
        final byContent = await split(candidates, (i) async {
          countBytes(size);
          return (await sha256.bind(source.openRead(i)).first).toString();
        });
        sets.addAll(byContent.values.where((s) => s.length > 1));
      }
    }
    return sets;
  }

  // --- F04 ----------------------------------------------------------------

  /// Compares two texts that the MinHash index paired. Returns an F04 match,
  /// a near miss (rule null) worth recording, or null.
  DocumentMatch? _compareVersions(_Unit a, _Unit b) {
    final wa = a.content.words, wb = b.content.words;
    final similarity = jaccard(a.shingleSet!, b.shingleSet!);
    if (similarity < rules.nearMissSimilarity) return null;
    final ratio =
        math.min(wa.length, wb.length) / math.max(wa.length, wb.length);
    final evidence = 'shingle similarity ${similarity.toStringAsFixed(3)}, '
        'length ${wa.length} vs ${wb.length} words';
    String? blocked;
    if (similarity < rules.versionMinSimilarity) {
      blocked = 'below the version threshold';
    } else if (ratio < rules.versionMinLengthRatio) {
      blocked = 'lengths too different';
    } else if (!namesRelated(a.rep.displayName, b.rep.displayName)) {
      blocked = 'similar text, but the names say different documents';
    } else {
      final ia = a.ids ??= identifiers(wa), ib = b.ids ??= identifiers(wb);
      final onlyA = ia.difference(ib), onlyB = ib.difference(ia);
      if (onlyA.isNotEmpty && onlyB.isNotEmpty) {
        blocked = 'similar text, but different reference numbers '
            '(${onlyA.take(3).join(', ')} vs ${onlyB.take(3).join(', ')})';
      }
    }
    return blocked == null
        ? DocumentMatch(DocumentRule.f04EditedVersion, similarity, evidence)
        : DocumentMatch(null, similarity, '$blocked: $evidence');
  }

  // --- F05 ----------------------------------------------------------------

  Future<List<ScanPage>> _decodePages(List<Uint8List> jpegs) async {
    final out = <ScanPage>[];
    for (final jpeg in jpegs) {
      final thumb = await pageDecoder.decode(jpeg, rules.scanAnalysisSize);
      if (thumb == null) return out;
      out.add(ScanPage.fromThumbnail(thumb,
          borderMaxStdDev: scanRules.borderMaxStdDev,
          borderMaxShare: scanRules.borderMaxShare));
    }
    return out;
  }

  /// Compares two scans with the same number of pages, page by page in
  /// order. Every page must pass the layout test (the photo scan's copy or
  /// shot test) and the detail test (no tile differs by more than
  /// [DuplicateDocumentRules.scanMaxTileDifference] once aligned).
  DocumentMatch? _compareScans(_Unit a, _Unit b) {
    var worst = 0.0;
    String? firstPage;
    for (var i = 0; i < a.pages.length; i++) {
      final where = a.pages.length == 1 ? '' : 'page ${i + 1}: ';
      final layout = comparePhotos(
          a.pages[i].fingerprint, b.pages[i].fingerprint, scanRules,
          shotAllowed: true);
      if (layout == null || !layout.matched) {
        // Unrelated first pages aren't worth a note.
        if (i == 0) return null;
        return DocumentMatch(null, layout?.correlation ?? 0,
            '${where}different layout${layout == null ? '' : ' (${layout.evidence})'}');
      }
      final detail = comparePageDetail(a.pages[i], b.pages[i],
          maxShift: rules.scanMaxShift);
      if (detail.worstTile > rules.scanMaxTileDifference) {
        return DocumentMatch(
            null,
            1 - detail.worstTile,
            '${where}same layout, but the writing differs: '
            '${detail.evidence} (limit '
            '${rules.scanMaxTileDifference.toStringAsFixed(3)})');
      }
      worst = math.max(worst, detail.worstTile);
      firstPage ??= '${layout.evidence}; ${detail.evidence}';
    }
    return DocumentMatch(
        DocumentRule.f05RepeatedScan,
        1 - worst,
        '${a.pages.length == 1 ? 'page matches' : 'all ${a.pages.length} pages match'}; '
        'worst tile Δ${worst.toStringAsFixed(3)}; page 1: $firstPage');
  }

  /// Smallest time between any copy in [a] and any copy in [b], or null if
  /// a time is missing.
  static Duration? _closestInTime(_Unit a, _Unit b) {
    Duration? best;
    for (final x in a.items) {
      for (final y in b.items) {
        if (x.modified == null || y.modified == null) return null;
        final gap = x.modified!.difference(y.modified!).abs();
        if (best == null || gap < best) best = gap;
      }
    }
    return best;
  }

  static String _days(Duration d) => d.inDays >= 1
      ? '${d.inDays} day${d.inDays == 1 ? '' : 's'}'
      : '${d.inHours} h';

  // --- Grouping -----------------------------------------------------------

  /// Complete-linkage clustering inside each connected set of matches: two
  /// clusters merge only if every document in one matches every document in
  /// the other, most alike first. Stops chains of gradually edited versions
  /// becoming one group.
  List<List<int>> _cluster(
      List<_Unit> units,
      Map<(int, int), DocumentMatch> edges,
      List<DocumentObservation> observations) {
    final n = units.length;
    final parent = List<int>.generate(n, (i) => i);
    int find(int i) => parent[i] == i ? i : parent[i] = find(parent[i]);
    for (final (a, b) in edges.keys) {
      parent[find(a)] = find(b);
    }
    final components = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      (components[find(i)] ??= []).add(i);
    }

    final out = <List<int>>[];
    for (final component in components.values) {
      if (component.length == 1 || component.length > rules.maxClusterSize) {
        out.add(component);
        continue;
      }
      var clusters = [
        for (final i in component) [i]
      ];
      while (true) {
        (int, int)? best;
        var bestScore = -1.0;
        for (var x = 0; x < clusters.length; x++) {
          for (var y = x + 1; y < clusters.length; y++) {
            var score = 2.0;
            for (final a in clusters[x]) {
              for (final b in clusters[y]) {
                final e = edges[a < b ? (a, b) : (b, a)];
                score = e == null ? -2 : math.min(score, _strength(e));
              }
            }
            if (score > bestScore) {
              bestScore = score;
              best = (x, y);
            }
          }
        }
        if (best == null || bestScore < 0) break;
        final (x, y) = best;
        clusters = [
          for (var k = 0; k < clusters.length; k++)
            if (k != x && k != y) clusters[k],
          [...clusters[x], ...clusters[y]],
        ];
      }
      if (clusters.length > 1) {
        observations.add(DocumentObservation(
            DocumentObservationKind.split,
            [for (final i in component) units[i].rep.id],
            'linked by a chain of matches but not all alike; split into '
            '${clusters.length} groups'));
      }
      out.addAll(clusters);
    }
    return out;
  }

  /// Orders matches for clustering: stronger rules first, then score.
  static double _strength(DocumentMatch m) =>
      (DocumentRule.values.length - m.rule!.index) + m.score.clamp(0, 1) * 0.5;

  static final _copyName =
      RegExp(r'\(\d+\)|\bcopy\b|\bduplicate\b', caseSensitive: false);

  List<String> _folders(StorageItem item) {
    final parts = (item.path ?? item.id).toLowerCase().split(RegExp(r'[/\\]'));
    return parts.sublist(0, parts.length - 1);
  }

  DocumentGroup? _group(
      List<_Unit> units,
      List<int> cluster,
      GroupKind kind,
      DocumentMatch? Function(int a, int b) edge,
      List<DocumentObservation> observations) {
    final entries = [
      for (final i in cluster)
        for (final item in units[i].items) (unit: i, item: item)
    ];
    final facts = <String, DocumentFacts>{};
    for (final e in entries) {
      final pages = units[e.unit].pages;
      facts[e.item.id] = DocumentFacts(
        item: e.item,
        content: units[e.unit].content,
        secondhand: _folders(e.item).any(rules.secondhandFolders.contains),
        copyName: _copyName.hasMatch(e.item.displayName),
        sharpness: pages.isEmpty
            ? null
            : pages.fold(0.0, (s, f) => s + f.sharpness) / pages.length,
        pixels: pages.isEmpty ? 0 : pages.first.pixels,
      );
    }

    final all = facts.values.toList();
    final sharpest = all.map((f) => f.sharpness ?? 0).reduce(math.max);
    final eligible = [
      for (final f in all)
        if (kind != GroupKind.scans ||
            (f.sharpness ?? 0) >= sharpest * rules.keepSharpnessShare)
          f
    ]..sort((a, b) => _keeperOrder(a, b, kind));
    final keep = eligible.first;
    final keepUnit = entries.firstWhere((e) => e.item.id == keep.item.id).unit;

    final members = [DocumentMember(keep, null)];
    for (final e in entries) {
      if (e.item.id == keep.item.id) continue;
      final match = e.unit == keepUnit ? null : edge(e.unit, keepUnit);
      final rule = e.unit == keepUnit ? DocumentRule.f01Identical : match?.rule;
      if (rule == null) {
        observations.add(DocumentObservation(DocumentObservationKind.dropped,
            [e.item.id], 'not directly matched to the kept copy'));
        continue;
      }
      if (!rule.confidence.atLeast(rules.minConfidence)) {
        observations.add(DocumentObservation(DocumentObservationKind.dropped,
            [e.item.id], '${rule.code} is ${rule.confidence.name}'));
        continue;
      }
      members.add(DocumentMember(facts[e.item.id]!, rule, match));
    }
    if (members.length < 2) return null;
    members.sort((a, b) => a.isKeeper
        ? -1
        : b.isKeeper
            ? 1
            : a.item.id.compareTo(b.item.id));
    return DocumentGroup(members, kind, _keepReason(keep, all, kind, sharpest));
  }

  /// K01 (versions): newest. K02 (scans): sharp enough, then most pixels.
  /// Then K04 not in a second-hand folder, K05 not named like a copy, K06
  /// oldest, K07 path.
  static int _keeperOrder(DocumentFacts a, DocumentFacts b, GroupKind kind) {
    int flag(bool x) => x ? 1 : 0;
    final ta = a.item.modified ?? DateTime(9999),
        tb = b.item.modified ?? DateTime(9999);
    final steps = [
      if (kind == GroupKind.versions) tb.compareTo(ta),
      if (kind == GroupKind.scans) b.pixels.compareTo(a.pixels),
      flag(a.secondhand).compareTo(flag(b.secondhand)),
      flag(a.copyName).compareTo(flag(b.copyName)),
      ta.compareTo(tb),
      a.item.id.compareTo(b.item.id),
    ];
    return steps.firstWhere((s) => s != 0, orElse: () => 0);
  }

  String _keepReason(DocumentFacts keep, List<DocumentFacts> all,
      GroupKind kind, double sharpest) {
    final others = all.where((f) => f.item.id != keep.item.id);
    final reasons = [
      if (kind == GroupKind.versions) 'newest version',
      if (kind == GroupKind.scans &&
          others.any(
              (f) => (f.sharpness ?? 0) < sharpest * rules.keepSharpnessShare))
        'clearest scan',
      if (!keep.secondhand && others.any((f) => f.secondhand))
        'original location',
      if (!keep.copyName && others.any((f) => f.copyName))
        'not named as a copy',
    ];
    if (reasons.isEmpty) return 'oldest copy';
    return reasons.join(', ');
  }

  // --- Failed downloads ---------------------------------------------------

  /// For each cut-off, short or unfinished document (U02, U03, U06), whether
  /// its bytes are the start of a healthy document of the same type: the
  /// download or copy that failed. Returns the bytes read.
  Future<int> _partialCopies(StorageSource source, List<FileVerdict> broken,
      List<StorageItem> healthy, List<DocumentObservation> observations) async {
    var read = 0;
    for (final v in broken) {
      final item = v.item;
      if (item.sizeBytes < rules.minBytes ||
          !_truncationRules.contains(v.rule)) {
        continue;
      }
      final ext = _innerExtension(item);
      final candidates = [
        for (final h in healthy)
          if (h.extension == ext && h.sizeBytes > item.sizeBytes) h
      ]..sort((a, b) => _originalFirst(item, a, b));
      if (candidates.isEmpty) continue;
      final length = math.min(item.sizeBytes, rules.prefixBytes);
      final String head;
      try {
        head =
            sha256.convert(await source.readRange(item, 0, length)).toString();
      } on StorageReadException {
        continue;
      }
      read += length;
      for (final c in candidates.take(rules.partialCopyCandidates)) {
        try {
          read += length;
          final other =
              sha256.convert(await source.readRange(c, 0, length)).toString();
          if (other != head) continue;
        } on StorageReadException {
          continue;
        }
        observations.add(DocumentObservation(
            DocumentObservationKind.partialCopy,
            [item.id, c.id],
            'failed download or copy of ${p.basename(c.displayName)}: its '
            'first ${kb(length)} are identical, the rest is missing; left to '
            'the unreadable-file scan (${v.rule.code})',
            rule: v.rule.code));
        break;
      }
    }
    return read;
  }

  static const _truncationRules = {
    DeepRule.u02ShortRead,
    DeepRule.u03UnfinishedDownload,
    DeepRule.u06CutOff,
  };

  /// Order for failed-download candidates: names sharing a stem with
  /// [broken] first, then originals (not in a second-hand folder, not named
  /// as a copy), then by path.
  int _originalFirst(StorageItem broken, StorageItem a, StorageItem b) {
    final name = _innerExtension(broken) == broken.extension
        ? broken.displayName
        : broken.displayName.substring(
            0, broken.displayName.length - broken.extension.length - 1);
    int rank(StorageItem c) =>
        (namesRelated(name, c.displayName) ? 0 : 4) +
        (_folders(c).any(rules.secondhandFolders.contains) ? 2 : 0) +
        (_copyName.hasMatch(c.displayName) ? 1 : 0);
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : a.id.compareTo(b.id);
  }
}

/// Duplicate documents, as found by the deep scan, filed under [category].
/// scan_engine has no duplicate-document category yet; see the ruleset's
/// merge notes for the one to add.
final class DeepDuplicateDocumentDetector extends WasteDetector {
  const DeepDuplicateDocumentDetector(this.analyzer, this.category);

  final DuplicateDocumentAnalyzer analyzer;

  @override
  final WasteCategory category;

  @override
  Future<List<Finding>> detect(ScanContext context) async => [
        for (final g in (await analyzer.analyze(context, category)).groups)
          g.toFinding(category)
      ];
}
