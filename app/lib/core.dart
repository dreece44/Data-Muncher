import 'dart:io' show FileSystemException, Platform;

import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';
import 'package:scan_engine_flutter/scan_engine_flutter.dart' show NativeBridge;
import 'package:shared_preferences/shared_preferences.dart';

import 'application/duplicate_groups/best_copy.dart';
import 'application/exclusion/exclusion_list.dart';
import 'application/storage_alert/storage_alert.dart';
import 'application/storage_scan/storage_scan.dart';
import 'data/exclusion/shared_prefs_exclusion_store.dart';
import 'data/garbage_bin/bin_entry.dart';
import 'data/garbage_bin/file_bin.dart';
import 'data/storage_alert/storage_alert_service.dart';
import 'rules.dart';

/// How long the phone's own trash keeps deleted photos and videos (iOS
/// Recently Deleted, the Android 11+ trash). Emptying the bin relies on it
/// for Deletion Backups (PB-17).
const Duration systemTrashRetention = Duration(days: 30);

/// Deleting would be permanent: the phone has no trash for photos and videos
/// (Android 10 and older), or the items are storage files, which never go to
/// a trash. Ask the user, then retry with `allowPermanent: true`.
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

/// What happened when scan results were moved to the Garbage Bin.
class FileCollection {
  const FileCollection({required this.moved, required this.bytes, required this.failed});

  final int moved;
  final int bytes;

  /// Paths that couldn't be moved and are still where they were.
  final List<String> failed;
}

/// Tells Android's media index that files moved, so the gallery and the
/// photo scan stop listing binned photos and see recovered ones again.
class MediaIndex {
  static const _channel = MethodChannel('datamuncher/media');

  static Future<void> refresh(Iterable<String> paths) async {
    final list = paths.toList();
    if (list.isEmpty || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('scanFiles', {'paths': list});
    } catch (_) {
      // Only the gallery is affected; the move itself already happened.
    }
  }
}

class MunchState extends ChangeNotifier {
  MunchState({ExclusionList? exclusions})
      : exclusions = exclusions ?? ExclusionList() {
    this.exclusions.addListener(notifyListeners);
  }

  /// Do-not-collect list (DAT-32): recovered files and kept apps that scans
  /// skip until their period ends.
  final ExclusionList exclusions;

  List<AssetEntity> all = [];
  List<AssetEntity> duplicates = [], empty = [], blurry = [];

  /// Duplicates grouped, each with the copy suggested to keep (DAT-34).
  /// [duplicates] is every copy in these groups except that one.
  List<DuplicateGroup> duplicateGroups = [];
  Set<String> bin = {}; // Garbage Bin (asset ids)
  Map<String, BinRecord> binInfo = {}; // id -> why/when it was collected

  /// Storage files moved to the bin by the storage scan.
  late FileBin fileBin = FileBin(binFolderFor: (path) => binFolderUnder(_storageRoots, path));
  List<String> _storageRoots = const [];
  double usedFraction = 0, freeGb = 0, progress = 0;
  bool scanning = false, scanned = false, denied = false;

  /// How full the phone is (DAT-36). Drives the warning on the home page.
  StorageLevel storageLevel = StorageLevel.ok;

  /// Latest free/total space reading; null until the phone reports one.
  StorageReading? storageReading;

  /// Goes up every time the bin's contents change, so the Garbage Bin viewer
  /// can ignore the many other notifications (scan progress, storage).
  int binRevision = 0;

  /// Reason each file was flagged in the latest scan.
  Map<String, CollectionReason> _flags = {};
  late SharedPreferences _p;

  Iterable<AssetEntity> get images => all.where((a) => a.type == AssetType.image);
  Iterable<AssetEntity> get videos => all.where((a) => a.type == AssetType.video);

  /// Everything in the Garbage Bin: photo library items and storage files.
  int get binCount => bin.length + fileBin.length;
  List<String> get binIds => [...bin, ...fileBin.records.map((r) => r.id)];

  /// Whether a storage file at [path] was recovered with "Do not collect".
  /// Storage files get a new bin id each time, so they're kept by path.
  bool isExcludedPath(String path) => exclusions.isExcluded(path);

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
    // Also moves the old 'excl' entries into the new format.
    await exclusions.load(SharedPrefsExclusionStore(_p));
    fileBin = FileBin(
      binFolderFor: fileBin.binFolderFor,
      records: FileBin.decode(_p.getStringList('fileBin') ?? const []),
    );
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
    await _p.setStringList('fileBin', fileBin.encode());
  }

  /// Storage indicator data, and the storage-full warning (DAT-36).
  Future<void> refreshStorage() async {
    StorageReading? reading;
    try {
      final d = DiskSpacePlus();
      final free = await d.getFreeDiskSpace ?? 0; // MB
      final total = await d.getTotalDiskSpace ?? 0; // MB
      if (total > 0) {
        usedFraction = ((total - free) / total).clamp(0.0, 1.0);
        freeGb = free / 1024;
        reading = StorageReading.fromMb(freeMb: free, totalMb: total);
      }
    } catch (_) {}
    if (reading != null && reading.isValid) setStorageReading(reading);
    notifyListeners();
    if (reading != null && reading.isValid) {
      // Post the notification, or take it down once space is freed.
      try {
        await StorageAlertService.instance.check(reading: reading);
      } catch (_) {}
    }
  }

  /// Updates [storageLevel] from a free/total space reading.
  @visibleForTesting
  void setStorageReading(StorageReading reading) {
    storageReading = reading;
    storageLevel = StorageAlertService.instance.policy.levelOf(reading);
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
    // Exclusions that ended since the last scan make those files eligible
    // again.
    await exclusions.purgeExpired();
    final count = await paths.first.assetCountAsync;
    all = await paths.first.getAssetListRange(start: 0, end: count);

    final classifier = WasteClassifier(defaultRuleConfig);
    final emp = <AssetEntity>[], blu = <AssetEntity>[];
    final flags = <String, CollectionReason>{};
    final copies = <DuplicateCandidate>[];

    for (var i = 0; i < all.length; i++) {
      final a = all[i];
      if (!bin.contains(a.id) && !exclusions.isExcluded(a.id)) {
        // A damaged photo or video has no thumbnail; the phone throws rather
        // than returning null. Treat it as missing so it's flagged, not fatal.
        img.Image? im;
        try {
          final bytes = await a.thumbnailDataWithSize(const ThumbnailSize(128, 128));
          im = bytes == null ? null : img.decodeImage(bytes);
        } catch (_) {
          im = null;
        }
        final isImage = a.type == AssetType.image;
        final f = AssetFeatures.fromImage(a.id, im, isImage: isImage, durationSec: a.duration);
        // Duplicates are found by grouping below (DAT-34), which keeps the
        // best copy rather than the first one seen.
        final verdicts = [
          for (final v in classifier.classify(f))
            if (v.category != WasteCategory.duplicate) v
        ];
        for (final v in verdicts) {
          switch (v.category) {
            case WasteCategory.duplicate:
              break;
            case WasteCategory.empty:
              emp.add(a);
            case WasteCategory.blurry:
              blu.add(a);
          }
        }
        final reason = reasonForVerdicts(verdicts);
        if (reason != null) flags[a.id] = reason;
        if (im != null && reason != CollectionReason.unreadable && reason != CollectionReason.blank) {
          copies.add(DuplicateCandidate(
            id: a.id,
            hash: hashFromBits(f.hash),
            quality: isImage ? PhotoQuality.fromImage(im) : null,
            width: a.width,
            height: a.height,
            taken: a.createDateTime,
            isVideo: !isImage,
            durationSec: a.duration,
          ));
        }
      }
      if (i % 10 == 0) {
        progress = i / all.length;
        notifyListeners();
      }
    }
    duplicateGroups = groupDuplicates(copies);
    final byId = {for (final a in all) a.id: a};
    final dup = <AssetEntity>[];
    for (final group in duplicateGroups) {
      for (final copy in group.others) {
        dup.add(byId[copy.id]!);
        // Duplicate wins over blurry, as in reasonForVerdicts.
        flags[copy.id] = CollectionReason.duplicate;
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

  /// Garbage Collection: send items to the Garbage Bin. [reason] overrides
  /// the scan's reason for each item.
  ///
  /// Collecting a file by hand overrides its "Do not collect" mark (the
  /// review page asks first), so the mark is removed.
  Future<void> collect(Iterable<AssetEntity> items, {CollectionReason? reason}) async {
    final ids = items.map((a) => a.id).toSet();
    await exclusions.removeAll(ids);
    final now = DateTime.now();
    for (final id in ids) {
      if (bin.add(id)) {
        binInfo[id] = BinRecord(reason ?? _flags[id] ?? CollectionReason.manual, now);
      }
    }
    for (final l in [duplicates, empty, blurry]) {
      l.removeWhere((a) => ids.contains(a.id));
    }
    // A group that lost its suggested copy gets a new one; the duplicates
    // list follows, so "Munch my data" never takes the last copy.
    duplicateGroups = [
      for (final g in duplicateGroups)
        ?g.without(ids),
    ];
    final byId = {for (final a in all) a.id: a};
    duplicates = [
      for (final g in duplicateGroups)
        for (final copy in g.others)
          ?byId[copy.id],
    ];
    binRevision++;
    await _save();
    notifyListeners();
  }

  /// Moves storage scan results (DAT-1) into the Garbage Bin. Each file is
  /// moved to the bin folder on its volume; one that can't be moved is left
  /// in place and listed in [FileCollection.failed].
  Future<FileCollection> collectFiles(Iterable<ScanCandidate> candidates) async {
    if (_storageRoots.isEmpty && Platform.isAndroid) {
      try {
        _storageRoots = await const NativeBridge().androidStorageRoots();
      } catch (_) {}
    }
    final now = DateTime.now();
    final movedFrom = <String>[];
    final failed = <String>[];
    var bytes = 0;
    for (final c in candidates) {
      try {
        final record = await fileBin.collect(c.path, c.reason, now: now);
        movedFrom.add(c.path);
        bytes += record.sizeBytes;
      } on FileSystemException {
        failed.add(c.path);
      }
    }
    if (movedFrom.isNotEmpty) {
      binRevision++;
      await _save();
      notifyListeners();
      await MediaIndex.refresh(movedFrom);
    }
    return FileCollection(moved: movedFrom.length, bytes: bytes, failed: failed);
  }

  /// File Recovery, optionally marking the files "Do not collect" for 30
  /// days (DAT-32). [names] gives each file's name for the Do-not-collect
  /// list.
  Future<void> recover(
    Iterable<String> ids, {
    bool doNotCollect = false,
    Map<String, String> names = const {},
  }) async {
    final list = ids.toList();
    final restored = <String>[];
    final keptPaths = <String, String?>{};
    for (final id in list.where(fileBin.contains).toList()) {
      final original = fileBin[id]!.originalPath;
      restored.add(await fileBin.restore(id));
      // Storage files get a new id each time they're binned, so exclude the path.
      keptPaths[original] = names[id] ?? original.split(RegExp(r'[/\\]')).last;
    }
    bin.removeAll(list);
    for (final id in list) {
      binInfo.remove(id);
    }
    if (doNotCollect) {
      await exclusions.excludeAll(
        {
          for (final id in list)
            if (!id.startsWith(fileBinIdPrefix)) id: names[id],
          ...keptPaths,
        },
        kind: ExcludedKind.file,
      );
    }
    await MediaIndex.refresh(restored);
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

  /// Removes bin items from the device, sending photos and videos to the
  /// phone's trash when it has one. Storage files have no trash and are
  /// deleted for good. Whenever something would be deleted for good this
  /// throws [NoSystemTrashException] unless [allowPermanent] is set.
  ///
  /// The phone shows its own confirmation, which the user can refuse, so only
  /// the returned ids actually left the bin. Items that were already deleted
  /// outside DataMuncher are dropped from the bin and counted as removed.
  Future<BinDeletion> deleteFromBin(Iterable<String> ids, {bool allowPermanent = false}) async {
    final requested = ids.toSet();
    final wanted = requested.where(bin.contains).toSet();
    final files = requested.where(fileBin.contains).toSet();
    final trash = await systemTrashAvailable();
    if (wanted.isEmpty && files.isEmpty) return BinDeletion(const {}, restorable: trash);
    if ((files.isNotEmpty || (wanted.isNotEmpty && !trash)) && !allowPermanent) {
      throw const NoSystemTrashException();
    }

    final deletedFiles = <String>{};
    for (final id in files) {
      try {
        await fileBin.delete(id);
        deletedFiles.add(id);
      } on FileSystemException {
        // Still in the bin; the viewer reports it as not deleted.
      }
    }

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
    return BinDeletion({...gone, ...deletedFiles}, restorable: trash && files.isEmpty);
  }

  /// Drops bin ids whose files no longer exist (deleted outside DataMuncher),
  /// so the bin count stays right.
  Future<void> forgetMissing(Iterable<String> ids) async {
    final gone = ids.where((id) => bin.contains(id) || fileBin.contains(id)).toSet();
    if (gone.isEmpty) return;
    bin.removeAll(gone);
    for (final id in gone) {
      binInfo.remove(id);
      fileBin.forget(id);
    }
    binRevision++;
    await _save();
    notifyListeners();
  }

  /// Garbage Bin Empty (PB-14 / DAT-28): removes everything in the bin.
  Future<BinDeletion> emptyBin({bool allowPermanent = false}) =>
      deleteFromBin(binIds, allowPermanent: allowPermanent);
}
