/// How sure a deep-scan rule is about a finding. Shared by every deep scan
/// so results can be filtered the same way once they're merged.
enum Confidence {
  /// Provably waste: a 0-byte file, a failed checksum, a byte-for-byte copy.
  certain,

  /// Strong signs, but a rare legitimate file could look the same (a CSV
  /// with only a header row, two burst shots the user wants both of). Shown
  /// to the user, but worth a second look when tuning.
  likely;

  bool atLeast(Confidence minimum) => index <= minimum.index;
}
