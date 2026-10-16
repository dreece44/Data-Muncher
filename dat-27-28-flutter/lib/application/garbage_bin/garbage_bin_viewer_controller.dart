import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/garbage_bin/bin_entry.dart';
import '../../data/garbage_bin/garbage_bin_store.dart';
import 'bin_query.dart';

/// Where the viewer is in opening the bin.
enum BinLoadStatus {
  /// First load in progress; nothing to show yet.
  loading,

  /// Contents loaded (possibly an empty bin).
  ready,

  /// The first load failed, so there is nothing to show.
  failed,
}

/// Holds what the Garbage Bin Viewer shows and applies the user's search,
/// category and sort choices.
///
/// Read-only: it never changes the bin. It reloads by itself whenever the
/// store reports a change.
class GarbageBinViewerController extends ChangeNotifier {
  GarbageBinViewerController({
    required GarbageBinStore store,
    DateTime Function()? clock,
  })  : _store = store,
        _clock = clock ?? DateTime.now {
    _changesSubscription = _store.changes.listen((_) => load());
  }

  final GarbageBinStore _store;
  final DateTime Function() _clock;
  late final StreamSubscription<void> _changesSubscription;

  BinLoadStatus _status = BinLoadStatus.loading;
  Object? _error;
  List<BinEntry> _allEntries = const [];
  List<BinEntry> _visibleEntries = const [];
  BinSummary _summary = BinSummary.empty;
  BinQuery _query = const BinQuery();
  int _loadGeneration = 0;
  bool _disposed = false;

  BinLoadStatus get status => _status;

  /// Why the last load failed, or null if it succeeded.
  Object? get error => _error;

  /// A refresh failed but the previously loaded list is still on screen.
  bool get refreshFailed => _status == BinLoadStatus.ready && _error != null;

  /// Everything in the bin, unfiltered.
  List<BinEntry> get allEntries => _allEntries;

  /// What the list should show after search, category and sort.
  List<BinEntry> get visibleEntries => _visibleEntries;

  BinSummary get summary => _summary;
  BinQuery get query => _query;
  DateTime now() => _clock();

  /// Fetches the bin's contents.
  ///
  /// Only the first load shows a spinner; later refreshes keep the current
  /// list on screen. If several loads overlap, only the newest one counts.
  Future<void> load() async {
    final generation = ++_loadGeneration;
    if (_status != BinLoadStatus.ready) {
      _status = BinLoadStatus.loading;
      _error = null;
      _notify();
    }

    try {
      final entries = await _store.listEntries();
      if (_disposed || generation != _loadGeneration) return;
      _allEntries = List<BinEntry>.unmodifiable(entries);
      _status = BinLoadStatus.ready;
      _error = null;
      _recompute();
    } catch (error) {
      if (_disposed || generation != _loadGeneration) return;
      _error = error;
      if (_status != BinLoadStatus.ready) _status = BinLoadStatus.failed;
    }
    _notify();
  }

  void setSearchText(String text) {
    if (text == _query.searchText) return;
    _query = _query.copyWith(searchText: text);
    _recompute();
    _notify();
  }

  /// Shows only [category], or every kind of file when null.
  void setCategory(FileCategory? category) {
    if (category == _query.category) return;
    _query = category == null
        ? _query.copyWith(clearCategory: true)
        : _query.copyWith(category: category);
    _recompute();
    _notify();
  }

  void setSort(BinSort sort) {
    if (sort == _query.sort) return;
    _query = _query.copyWith(sort: sort);
    _recompute();
    _notify();
  }

  /// Clears the search and category, keeping the sort order.
  void clearFilters() {
    _query = BinQuery(sort: _query.sort);
    _recompute();
    _notify();
  }

  void _recompute() {
    _summary = BinSummary.of(_allEntries, now: _clock());
    // A category with nothing left in it has no chip, so it can't stay
    // selected (e.g. after the last video is recovered).
    final category = _query.category;
    if (category != null && _summary.countFor(category) == 0) {
      _query = _query.copyWith(clearCategory: true);
    }
    _visibleEntries =
        List<BinEntry>.unmodifiable(applyBinQuery(_allEntries, _query));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_changesSubscription.cancel());
    super.dispose();
  }
}
