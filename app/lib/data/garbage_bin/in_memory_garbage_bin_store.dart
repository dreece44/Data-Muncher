import 'dart:async';

import 'bin_entry.dart';
import 'garbage_bin_store.dart';

/// A [GarbageBinStore] that keeps entries in memory.
///
/// Stand-in until the real bin storage (DAT-17) exists, and used by the tests
/// and the demo app. Nothing is saved to disk.
class InMemoryGarbageBinStore implements GarbageBinStore {
  InMemoryGarbageBinStore([Iterable<BinEntry> entries = const []]) {
    for (final entry in entries) {
      _entries[entry.id] = entry;
    }
  }

  final Map<String, BinEntry> _entries = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Future<List<BinEntry>> listEntries() async =>
      List<BinEntry>.unmodifiable(_entries.values);

  @override
  Stream<void> get changes => _changes.stream;

  /// Adds an entry, or replaces the one with the same id.
  void put(BinEntry entry) {
    _entries[entry.id] = entry;
    _changes.add(null);
  }

  /// Removes an entry and returns it, or returns null if it wasn't there.
  BinEntry? remove(String id) {
    final removed = _entries.remove(id);
    if (removed != null) _changes.add(null);
    return removed;
  }

  /// Removes everything.
  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    _changes.add(null);
  }

  Future<void> close() => _changes.close();
}
