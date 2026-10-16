import 'dart:io' show Platform;

import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/garbage_bin/bin_entry.dart';
import 'rules.dart';

/// Days a recovered file is protected by "Do not collect".
const int excludeDays = 30;

/// How long the phone's own trash keeps deleted photos and videos (iOS
/// Recently Deleted, the Android 11+ trash). Emptying the bin relies on it
/// for Deletion Backups (PB-17).
const Duration systemTrashRetention = Duration(days: 30);

/// The phone has no trash to keep deleted files in (Android 10 and older),
/// so deleting would be permanent. Ask the user, then retry with
/// `allowPermanent: true`.
class NoSystemTrashException implements Exception {
  const NoSystemTrashException();

  @override
  String toString() => 'NoSystemTrashException: deletion would be permanent';
}

/// Which bin files were removed, and whether they can still be restored.
class BinDeletion {
  const BinDeletion(this.removedIds, {required this.restorable});

  final Set<String> removedIds;

  /// True when the files went to the phone's trash rather than being
  /// deleted for good.
  final bool restorable;
}

/// Why and when a file went into the Garbage Bin.
class BinRecord {
  const BinRecord(this.reason, this.collectedAt);

  final CollectionReason reason;
  final DateTime collectedAt;

  String encode(String id) =>
      '$id|${reason.name}|${collectedAt.millisecondsSinceEpoch}';

  /// Parses `id|reason|ms`; returns null for a malformed line.
  static MapEntry<String, BinRecord>? decode(String line) {
    final parts = line.split('|');
    if (parts.length < 3) return null;
    final ms = int.tryParse(parts.last);
    if (ms == null) return null;
    final id = parts.sublist(0, parts.length - 2).join('|');
    final reasonName = parts[parts.length - 2];
    final reason = CollectionReason.values.firstWhere(
      (r) => r.name == reasonName,
      orElse: () => CollectionReason.other,
    );
    return MapEntry(id, BinRecord(reason, DateTime.fromMillisecondsSinceEpoch(ms)));
  }
}

/// Turns a scan's verdicts for one file into the reason shown in the bin.
/// Returns null when the scan didn't flag the file.
CollectionReason? reasonForVerdicts(Iterable<Verdict> verdicts) {
  final list = verdicts.toList();
  if (list.isEmpty) return null;
  for (final v in list) {
    if (v.category == WasteCategory.empty) {
      return v.ruleId == 'R1-unreadable' ? CollectionReason.unreadable : CollectionReason.blank;
    }
  }
  if (list.any((v) => v.category == WasteCategory.duplicate)) return CollectionReason.duplicate;
  if (list.any((v) => v.category == WasteCategory.blurry)) return CollectionReason.blurry;
  return CollectionReason.other;
}

class MunchState extends ChangeNotifier {
  List<AssetEntity> all = [];
  List<AssetEntity> duplicates = [], empty = [], blurry = [];
  Set<String> bin = {}; // Garbage Bin (asset ids)
  Map<String, BinRecord> binInfo = {}; // id -> why/when it was collected
  Map<String, int> excluded = {}; // id -> expiry (ms)
  double usedFraction = 0, freeGb = 0, progress = 0;
  bool scanning = false, scanned = false, denied = false;

  /// Goes up every time the bin's contents change, so the Garbage Bin viewer
  /// can ignore the many other notifications (scan progress, storage).
  int binRevision = 0;

  /// Reason each file was flagged in the latest scan.
  Map<String, CollectionReason> _flags = {};
  late SharedPreferences _p;

  Iterable<AssetEntity> get images => all.where((a) => a.type == AssetType.image);
  Iterable<AssetEntity> get videos => all.where((a) => a.type == AssetType.video);

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    bin = (_p.getStringList('bin') ?? []).toSet();
    for (final line in _p.getStringList('binInfo') ?? <String>[]) {
      final e = BinRecord.decode(line);
      if (e != null && bin.contains(e.key)) binInfo[e.key] = e.value;
    }
    // Items binned before binInfo existed: reason unknown, date = now.
    final now = DateTime.now();
    for (final id in bin) {
      binInfo.putIfAbsent(id, () => BinRecord(CollectionReason.other, now));
    }
    final nowMs = now.millisecondsSinceEpoch;
    for (final e in _p.getStringList('excl') ?? []) {
      final i = e.lastIndexOf('|');
      final t = int.tryParse(e.substring(i + 1)) ?? 0;
      if (t > nowMs) excluded[e.substring(0, i)] = t;
    }
    binRevision++;
    await refreshStorage();
    await scan();
  }

  Future<void> _save() async {
    await _p.setStringList('bin', bin.toList());
    await _p.setStringList('binInfo', [
      for (final id in bin)
        if (binInfo[id] != null) binInfo[id]!.encode(id),
    ]);
    await _p.setStringList('excl', [for (final e in excluded.entries) '${e.key}|${e.value}']);
  }

  /// Storage indicator data.
  Future<void> refreshStorage() async {
    try {
      final d = DiskSpacePlus();
      final free = await d.getFreeDiskSpace ?? 0; // MB
      final total = await d.getTotalDiskSpace ?? 0; // MB
      if (total > 0) {
        usedFraction = ((total - free) / total).clamp(0.0, 1.0);
        freeGb = free / 1024;
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Mass storage scan + bad photo detection.
  Future<void> scan() async {
    final perm = await PhotoManager.requestPermissionExtend();
    denied = !perm.hasAccess;
    if (denied) return notifyListeners();
    scanning = true;
    progress = 0;
    notifyListeners();

    final paths = await PhotoManager.getAssetPathList(onlyAll: true);
    if (paths.isEmpty) {
      scanning = false;
      return notifyListeners();
    }
    final count = await paths.first.assetCountAsync;
    all = await paths.first.getAssetListRange(start: 0, end: count);

    final classifier = WasteClassifier(defaultRuleConfig);
    final dup = <AssetEntity>[], emp = <AssetEntity>[], blu = <AssetEntity>[];
    final flags = <String, CollectionReason>{};

    for (var i = 0; i < all.length; i++) {
      final a = all[i];
      if (!bin.contains(a.id) && !excluded.containsKey(a.id)) {
        final bytes = await a.thumbnailDataWithSize(const ThumbnailSize(128, 128));
        final im = bytes == null ? null : img.decodeImage(bytes);
        final f = AssetFeatures.fromImage(a.id, im,
            isImage: a.type == AssetType.image, durationSec: a.duration);
        final verdicts = classifier.classify(f);
        for (final v in verdicts) {
          switch (v.category) {
            case WasteCategory.duplicate:
              dup.add(a);
            case WasteCategory.empty:
              emp.add(a);
            case WasteCategory.blurry:
              blu.add(a);
          }
        }
        final reason = reasonForVerdicts(verdicts);
        if (reason != null) flags[a.id] = reason;
      }
      if (i % 10 == 0) {
        progress = i / all.length;
        notifyListeners();
      }
    }
    duplicates = dup;
    empty = emp;
    blurry = blu;
    _flags = flags;
    scanning = false;
    scanned = true;
    await refreshStorage();
  }

  /// Garbage Collection: send items to the Garbage Bin.
  Future<void> collect(Iterable<AssetEntity> items) async {
    final ids = items.map((a) => a.id).toSet();
    final now = DateTime.now();
    for (final id in ids) {
      if (bin.add(id)) {
        binInfo[id] = BinRecord(_flags[id] ?? CollectionReason.manual, now);
      }
    }
    for (final l in [duplicates, empty, blurry]) {
      l.removeWhere((a) => ids.contains(a.id));
    }
    binRevision++;
    await _save();
    notifyListeners();
  }

  /// File Recovery (+ optional Collection Exclusion).
  Future<void> recover(Iterable<String> ids, {bool doNotCollect = false}) async {
    final list = ids.toList();
    bin.removeAll(list);
    for (final id in list) {
      binInfo.remove(id);
    }
    if (doNotCollect) {
      final until = DateTime.now().add(const Duration(days: excludeDays)).millisecondsSinceEpoch;
      for (final id in list) {
        excluded[id] = until;
      }
    }
    binRevision++;
    await _save();
    notifyListeners();
  }

  bool? _hasSystemTrash;

  /// Whether deleted photos and videos go to a trash the user can restore
  /// them from: iOS always, Android from 11 (API 30).
  Future<bool> systemTrashAvailable() async {
    final known = _hasSystemTrash;
    if (known != null) return known;
    var result = false;
    try {
      if (Platform.isIOS || Platform.isMacOS) {
        result = true;
      } else if (Platform.isAndroid) {
        final sdk = int.tryParse((await PhotoManager.systemVersion()).trim());
        result = sdk != null && sdk >= 30;
      }
    } catch (_) {}
    return _hasSystemTrash = result;
  }

  /// Removes bin items from the device, sending them to the phone's trash
  /// when it has one. Without a trash this throws [NoSystemTrashException]
  /// unless [allowPermanent] is set.
  ///
  /// The phone shows its own confirmation, which the user can refuse, so only
  /// the returned ids actually left the bin. Items that were already deleted
  /// outside DataMuncher are dropped from the bin and counted as removed.
  Future<BinDeletion> deleteFromBin(Iterable<String> ids, {bool allowPermanent = false}) async {
    final wanted = ids.where(bin.contains).toSet();
    final trash = await systemTrashAvailable();
    if (wanted.isEmpty) return BinDeletion(const {}, restorable: trash);
    if (!trash && !allowPermanent) throw const NoSystemTrashException();

    final assets = <AssetEntity>[];
    final missing = <String>{};
    for (final id in wanted) {
      final asset = await AssetEntity.fromId(id);
      if (asset == null) {
        missing.add(id);
      } else {
        assets.add(asset);
      }
    }

    var removed = <String>[];
    if (assets.isNotEmpty) {
      if (trash && Platform.isAndroid) {
        removed = await PhotoManager.editor.android.moveToTrash(assets);
      } else {
        // iOS: goes to Recently Deleted. Old Android: permanent (allowed above).
        removed = await PhotoManager.editor.deleteWithIds([for (final a in assets) a.id]);
      }
    }

    final gone = {...removed.where(wanted.contains), ...missing};
    bin.removeAll(gone);
    for (final id in gone) {
      binInfo.remove(id);
    }
    binRevision++;
    await _save();
    await refreshStorage();
    return BinDeletion(gone, restorable: trash);
  }

  /// Drops bin ids whose files no longer exist (deleted outside DataMuncher),
  /// so the bin count stays right.
  Future<void> forgetMissing(Iterable<String> ids) async {
    final gone = ids.where(bin.contains).toSet();
    if (gone.isEmpty) return;
    bin.removeAll(gone);
    for (final id in gone) {
      binInfo.remove(id);
    }
    binRevision++;
    await _save();
    notifyListeners();
  }

  /// Garbage Bin Empty (PB-14 / DAT-28): removes everything in the bin.
  Future<BinDeletion> emptyBin({bool allowPermanent = false}) =>
      deleteFromBin(bin.toList(), allowPermanent: allowPermanent);
}
