import 'dart:math' as math;

/// Text similarity and file-name checks for the F04 (edited version) rule.

const _mask32 = 0xFFFFFFFF;

/// 32-bit FNV-1a, stable across runs and platforms.
int fnv32(String s) {
  var h = 0x811C9DC5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & _mask32;
  }
  return h;
}

/// The set of overlapping [k]-word runs in [words], hashed. Texts shorter
/// than [k] words give one shingle of the whole text.
Set<int> shingles(List<String> words, int k) {
  if (words.isEmpty) return const {};
  if (words.length <= k) return {fnv32(words.join(' '))};
  return {
    for (var i = 0; i + k <= words.length; i++)
      fnv32(words.sublist(i, i + k).join(' '))
  };
}

/// Jaccard similarity: shared shingles over all shingles.
double jaccard(Set<int> a, Set<int> b) {
  if (a.isEmpty && b.isEmpty) return 1;
  final (small, large) = a.length <= b.length ? (a, b) : (b, a);
  var shared = 0;
  for (final x in small) {
    if (large.contains(x)) shared++;
  }
  return shared / (a.length + b.length - shared);
}

const _prime = 2147483647; // 2^31 − 1

/// MinHash signatures, so likely F04 pairs are found without comparing
/// every pair of documents: two texts share any one band of [rows] values
/// with probability 1 − (1 − s^rows)^bands at similarity s.
final class MinHasher {
  MinHasher({required this.bands, required this.rows}) {
    final r = math.Random(0x0D0C5);
    for (var i = 0; i < bands * rows; i++) {
      _a.add(1 + r.nextInt(_prime - 1));
      _b.add(r.nextInt(_prime));
    }
  }

  final int bands;
  final int rows;
  final _a = <int>[];
  final _b = <int>[];

  List<int> signature(Set<int> shingles) => [
        for (var i = 0; i < _a.length; i++)
          shingles.fold(_prime,
              (m, x) => math.min(m, (_a[i] * (x % _prime) + _b[i]) % _prime))
      ];

  /// Pairs of indexes into [signatures] that share at least one band.
  Set<(int, int)> candidates(List<List<int>?> signatures) {
    final pairs = <(int, int)>{};
    for (var band = 0; band < bands; band++) {
      final buckets = <String, List<int>>{};
      for (var i = 0; i < signatures.length; i++) {
        final s = signatures[i];
        if (s == null) continue;
        (buckets[s.sublist(band * rows, band * rows + rows).join(',')] ??= [])
            .add(i);
      }
      for (final b in buckets.values) {
        for (var x = 0; x < b.length; x++) {
          for (var y = x + 1; y < b.length; y++) {
            pairs.add((b[x], b[y]));
          }
        }
      }
    }
    return pairs;
  }
}

final _nameSplit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Words that mark a copy or a version rather than saying what a document
/// is ("Report final v2 (1)" is still "Report").
const versionWords = {
  'copy', 'of', 'final', 'draft', 'new', 'old', 'updated', 'update', //
  'revised', 'rev', 'edited', 'edit', 'latest', 'version', 'ver', 'fixed',
  'duplicate', 'backup',
};

/// The words of a file name that say what the document is: lower case,
/// extension, copy and version markers, and short numbers removed.
Set<String> nameStem(String fileName) {
  var base = fileName.toLowerCase();
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  return {
    for (final w in base.split(_nameSplit))
      if (w.isNotEmpty &&
          !versionWords.contains(w) &&
          !RegExp(r'^(v|rev)?\d{1,2}$').hasMatch(w))
        w
  };
}

/// Whether two file names describe the same document: one name's stem
/// contains the other's ("Shipping manifest" and "Shipping manifest final
/// v3").
bool namesRelated(String a, String b) {
  final sa = nameStem(a), sb = nameStem(b);
  if (sa.isEmpty || sb.isEmpty) return false;
  return sa.containsAll(sb) || sb.containsAll(sa);
}

final _nonDigit = RegExp(r'\D');

/// Words with four or more digits: invoice, order and account numbers,
/// years, reference codes. Versions of one document share them; two records
/// made from one template don't.
Set<String> identifiers(List<String> words) => {
      for (final w in words)
        if (w.replaceAll(_nonDigit, '').length >= 4) w
    };
