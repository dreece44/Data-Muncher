import '../../data/garbage_bin/bin_entry.dart';

/// Files leaving the bin within this window are called out as "leaving soon".
const Duration expiringSoonWindow = Duration(days: 3);

/// Orders the viewer can show the bin in.
enum BinSort {
  newestFirst('Newest first'),
  oldestFirst('Oldest first'),
  largestFirst('Largest first'),
  nameAToZ('Name (A–Z)'),
  leavingSoonest('Leaving the bin soonest');

  const BinSort(this.label);

  final String label;
}

/// What the user has asked to see: search text, one category, and an order.
class BinQuery {
  const BinQuery({
    this.searchText = '',
    this.category,
    this.sort = BinSort.newestFirst,
  });

  final String searchText;

  /// Only show this kind of file; null shows every kind.
  final FileCategory? category;

  final BinSort sort;

  /// Whether the list may be hiding some of the bin.
  bool get isFiltering => searchText.trim().isNotEmpty || category != null;

  BinQuery copyWith({
    String? searchText,
    FileCategory? category,
    bool clearCategory = false,
    BinSort? sort,
  }) {
    return BinQuery(
      searchText: searchText ?? this.searchText,
      category: clearCategory ? null : (category ?? this.category),
      sort: sort ?? this.sort,
    );
  }
}

/// Filters and orders [entries] for display.
///
/// Search is case-insensitive and matches the file name, the original path
/// (so folder names work) and the collection reason ("duplicate", "blurry").
List<BinEntry> applyBinQuery(Iterable<BinEntry> entries, BinQuery query) {
  final needle = query.searchText.trim().toLowerCase();
  final category = query.category;
  final result = entries.where((entry) {
    if (category != null && entry.category != category) return false;
    if (needle.isEmpty) return true;
    return entry.fileName.toLowerCase().contains(needle) ||
        entry.originalPath.toLowerCase().contains(needle) ||
        entry.reason.label.toLowerCase().contains(needle);
  }).toList();
  result.sort((a, b) => _compareEntries(a, b, query.sort));
  return result;
}

int _compareEntries(BinEntry a, BinEntry b, BinSort sort) {
  final primary = switch (sort) {
    BinSort.newestFirst => b.collectedAt.compareTo(a.collectedAt),
    BinSort.oldestFirst => a.collectedAt.compareTo(b.collectedAt),
    BinSort.largestFirst => b.originalSizeBytes.compareTo(a.originalSizeBytes),
    BinSort.nameAToZ => _compareNames(a, b),
    BinSort.leavingSoonest => _compareExpiry(a, b),
  };
  if (primary != 0) return primary;
  // List.sort isn't stable, so break ties the same way every time.
  final byName = _compareNames(a, b);
  if (byName != 0) return byName;
  return a.id.compareTo(b.id);
}

int _compareNames(BinEntry a, BinEntry b) =>
    a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());

/// Soonest expiry first; files with no time limit go last.
int _compareExpiry(BinEntry a, BinEntry b) {
  final aExpires = a.expiresAt;
  final bExpires = b.expiresAt;
  if (aExpires == null && bExpires == null) return 0;
  if (aExpires == null) return 1;
  if (bExpires == null) return -1;
  return aExpires.compareTo(bExpires);
}

/// Totals for everything in the bin, regardless of the current filter.
class BinSummary {
  const BinSummary({
    required this.itemCount,
    required this.totalOriginalBytes,
    required this.totalStoredBytes,
    required this.bytesSavedByCompression,
    required this.expiringSoonCount,
    required this.countsByCategory,
  });

  factory BinSummary.of(Iterable<BinEntry> entries, {required DateTime now}) {
    var itemCount = 0;
    var originalBytes = 0;
    var storedBytes = 0;
    var savedBytes = 0;
    var expiringSoon = 0;
    final counts = <FileCategory, int>{};
    final cutoff = now.add(expiringSoonWindow);

    for (final entry in entries) {
      itemCount++;
      originalBytes += entry.originalSizeBytes;
      storedBytes += entry.storedSizeBytes;
      savedBytes += entry.bytesSavedByCompression;
      counts.update(entry.category, (count) => count + 1, ifAbsent: () => 1);
      final expiresAt = entry.expiresAt;
      if (expiresAt != null && !expiresAt.isAfter(cutoff)) expiringSoon++;
    }

    return BinSummary(
      itemCount: itemCount,
      totalOriginalBytes: originalBytes,
      totalStoredBytes: storedBytes,
      bytesSavedByCompression: savedBytes,
      expiringSoonCount: expiringSoon,
      countsByCategory: Map<FileCategory, int>.unmodifiable(counts),
    );
  }

  static const BinSummary empty = BinSummary(
    itemCount: 0,
    totalOriginalBytes: 0,
    totalStoredBytes: 0,
    bytesSavedByCompression: 0,
    expiringSoonCount: 0,
    countsByCategory: <FileCategory, int>{},
  );

  final int itemCount;

  /// Combined size of the files before they went into the bin.
  final int totalOriginalBytes;

  /// Space the bin is actually using.
  final int totalStoredBytes;

  final int bytesSavedByCompression;

  /// Files whose time in the bin ends within [expiringSoonWindow]
  /// (including any already overdue).
  final int expiringSoonCount;

  final Map<FileCategory, int> countsByCategory;

  int countFor(FileCategory category) => countsByCategory[category] ?? 0;
}
