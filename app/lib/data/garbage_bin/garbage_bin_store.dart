import 'bin_entry.dart';

/// Read access to the Garbage Bin.
///
/// The bin storage subsystem (PB-12 / DAT-17) implements this. The viewer
/// depends only on this interface, so it can be built and tested before
/// DAT-17 lands by using `InMemoryGarbageBinStore`.
abstract interface class GarbageBinStore {
  /// Everything currently in the bin, in any order.
  ///
  /// Should come from the bin's index, without decompressing any files.
  /// Throw if the bin can't be read; the viewer shows an error and retry.
  Future<List<BinEntry>> listEntries();

  /// Emits whenever the bin's contents change: files collected, recovered,
  /// deleted, expired, or the bin emptied. Open viewers reload when it fires.
  Stream<void> get changes;
}
