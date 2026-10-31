import 'dart:convert';

import 'package:flutter/foundation.dart';

/// PB-18 / DAT-32 Collection Exclusion ("Do not collect").
///
/// Things the user has deliberately kept: files they recovered from the
/// Garbage Bin and marked "Do not collect", and apps they chose to keep
/// (DAT-25). Scans skip them until their exclusion period ends.

/// What an exclusion protects.
enum ExcludedKind {
  file('Recovered file'),
  app('App');

  const ExcludedKind(this.fallbackLabel);

  /// Shown when no name was recorded.
  final String fallbackLabel;
}

/// How long something stays excluded: the "defined period of time" in the
/// spec, set to 30 days by the team (DAT-32).
const Duration exclusionPeriod = Duration(days: 30);

/// One excluded file or app.
@immutable
class Exclusion {
  const Exclusion({
    required this.id,
    required this.kind,
    required this.excludedAt,
    this.until,
    this.label,
  });

  /// Photo library asset id for files, package name for apps.
  final String id;
  final ExcludedKind kind;
  final DateTime excludedAt;

  /// When scans may pick it up again ([excludedAt] + [exclusionPeriod]).
  /// Null only for an entry saved without an end date, which never ends.
  final DateTime? until;

  /// File or app name at the time it was excluded, if known.
  final String? label;

  String get key => keyFor(id, kind);
  String get displayName =>
      (label == null || label!.isEmpty) ? kind.fallbackLabel : label!;
  bool get isPermanent => until == null;

  bool isActiveAt(DateTime now) => until == null || now.isBefore(until!);

  static String keyFor(String id, ExcludedKind kind) => '${kind.name}:$id';

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'excludedAt': excludedAt.millisecondsSinceEpoch,
        if (until != null) 'until': until!.millisecondsSinceEpoch,
        if (label != null) 'label': label,
      };

  /// Returns null for an entry that can't be read, so one bad line never
  /// loses the rest of the list.
  static Exclusion? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final excludedAt = json['excludedAt'];
    if (id is! String || id.isEmpty || excludedAt is! int) return null;
    final until = json['until'];
    final label = json['label'];
    return Exclusion(
      id: id,
      kind: ExcludedKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => ExcludedKind.file,
      ),
      excludedAt: DateTime.fromMillisecondsSinceEpoch(excludedAt),
      until: until is int ? DateTime.fromMillisecondsSinceEpoch(until) : null,
      label: label is String ? label : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Exclusion &&
      other.id == id &&
      other.kind == kind &&
      other.excludedAt == excludedAt &&
      other.until == until &&
      other.label == label;

  @override
  int get hashCode => Object.hash(id, kind, excludedAt, until, label);

  @override
  String toString() => 'Exclusion($key until $until)';
}

/// Where the list is saved. SharedPreferences in the app, memory in tests.
abstract interface class ExclusionStore {
  List<String>? getStringList(String key);
  Future<void> setStringList(String key, List<String> value);
  Future<void> remove(String key);
}

class MemoryExclusionStore implements ExclusionStore {
  MemoryExclusionStore([Map<String, List<String>>? initial])
      : values = {...?initial};

  final Map<String, List<String>> values;

  @override
  List<String>? getStringList(String key) => values[key];

  @override
  Future<void> setStringList(String key, List<String> value) async =>
      values[key] = List.of(value);

  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// The Do-not-collect list.
class ExclusionList extends ChangeNotifier {
  ExclusionList({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// Saved entries, one JSON object per string.
  static const String storageKey = 'exclusions';

  /// The draft app's original format: `assetId|untilMillis`.
  static const String legacyStorageKey = 'excl';

  final DateTime Function() _clock;
  final Map<String, Exclusion> _entries = {};
  ExclusionStore? _store;

  DateTime now() => _clock();

  /// Reads the saved list, moving any entries in the old format across, and
  /// drops entries that have already ended. Saves from then on go to [store].
  Future<void> load(ExclusionStore store) async {
    _store = store;
    _entries.clear();
    for (final line in store.getStringList(storageKey) ?? const <String>[]) {
      Exclusion? entry;
      try {
        entry = Exclusion.fromJson(jsonDecode(line));
      } on FormatException {
        entry = null;
      }
      if (entry != null) _entries[entry.key] = entry;
    }

    final legacy = store.getStringList(legacyStorageKey);
    if (legacy != null) {
      for (final line in legacy) {
        final split = line.lastIndexOf('|');
        if (split <= 0) continue;
        final ms = int.tryParse(line.substring(split + 1));
        if (ms == null) continue;
        final until = DateTime.fromMillisecondsSinceEpoch(ms);
        final entry = Exclusion(
          id: line.substring(0, split),
          kind: ExcludedKind.file,
          // The old format didn't record this; it always used 30 days.
          excludedAt: until.subtract(exclusionPeriod),
          until: until,
        );
        _entries.putIfAbsent(entry.key, () => entry);
      }
    }

    _dropExpired();
    if (legacy != null) {
      await _save();
      await store.remove(legacyStorageKey);
    }
    notifyListeners();
  }

  /// Whether scans must skip [id] right now.
  bool isExcluded(String id, {ExcludedKind kind = ExcludedKind.file}) =>
      entryFor(id, kind: kind) != null;

  /// The active exclusion for [id], or null.
  Exclusion? entryFor(String id, {ExcludedKind kind = ExcludedKind.file}) {
    final entry = _entries[Exclusion.keyFor(id, kind)];
    return entry != null && entry.isActiveAt(_clock()) ? entry : null;
  }

  /// Active exclusions: the ones ending soonest first, permanent ones last,
  /// then by name.
  List<Exclusion> get active {
    final now = _clock();
    final list = [
      for (final e in _entries.values)
        if (e.isActiveAt(now)) e
    ];
    list.sort((a, b) {
      final au = a.until, bu = b.until;
      if (au != null && bu != null && au != bu) return au.compareTo(bu);
      if (au == null && bu != null) return 1;
      if (au != null && bu == null) return -1;
      final byName =
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      return byName != 0 ? byName : a.key.compareTo(b.key);
    });
    return list;
  }

  int count({ExcludedKind? kind}) =>
      active.where((e) => kind == null || e.kind == kind).length;

  /// Excludes [id] for [exclusionPeriod]. Excluding something again
  /// restarts its period.
  Future<Exclusion> exclude(
    String id, {
    required ExcludedKind kind,
    String? label,
  }) async {
    final entry = _make(id, kind, label);
    _entries[entry.key] = entry;
    await _save();
    notifyListeners();
    return entry;
  }

  /// Excludes several items at once, with one save. [items] maps ids to
  /// names (null when unknown).
  Future<void> excludeAll(
    Map<String, String?> items, {
    required ExcludedKind kind,
  }) async {
    if (items.isEmpty) return;
    for (final item in items.entries) {
      final entry = _make(item.key, kind, item.value);
      _entries[entry.key] = entry;
    }
    await _save();
    notifyListeners();
  }

  /// Puts back an entry exactly as it was (for Undo).
  Future<void> restore(Exclusion entry) async {
    _entries[entry.key] = entry;
    await _save();
    notifyListeners();
  }

  /// Lets scans pick [id] up again. Returns the removed entry, or null if
  /// it wasn't excluded.
  Future<Exclusion?> remove(String id,
      {ExcludedKind kind = ExcludedKind.file}) async {
    final removed = _entries.remove(Exclusion.keyFor(id, kind));
    if (removed == null) return null;
    await _save();
    notifyListeners();
    return removed;
  }

  /// Removes several at once. Returns how many were excluded.
  Future<int> removeAll(Iterable<String> ids,
      {ExcludedKind kind = ExcludedKind.file}) async {
    var removed = 0;
    for (final id in ids) {
      if (_entries.remove(Exclusion.keyFor(id, kind)) != null) removed++;
    }
    if (removed > 0) {
      await _save();
      notifyListeners();
    }
    return removed;
  }

  /// Forgets entries whose period has ended. Returns how many.
  Future<int> purgeExpired() async {
    final removed = _dropExpired();
    if (removed > 0) {
      await _save();
      notifyListeners();
    }
    return removed;
  }

  Exclusion _make(String id, ExcludedKind kind, String? label) {
    final now = _clock();
    return Exclusion(
      id: id,
      kind: kind,
      excludedAt: now,
      until: now.add(exclusionPeriod),
      label: label,
    );
  }

  int _dropExpired() {
    final now = _clock();
    final before = _entries.length;
    _entries.removeWhere((_, e) => !e.isActiveAt(now));
    return before - _entries.length;
  }

  Future<void> _save() async {
    await _store?.setStringList(storageKey, [
      for (final e in _entries.values) jsonEncode(e.toJson()),
    ]);
  }
}
