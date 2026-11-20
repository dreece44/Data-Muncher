/// DAT-36 (PB-23): warn the user before the phone's storage fills up, so the
/// camera never fails to save a photo.
///
/// Pure Dart: decides *whether* and *what* to notify. The phone side (reading
/// free space, posting the notification, background checks) lives in
/// `lib/data/storage_alert/storage_alert_service.dart`.
library;

const int _mb = 1024 * 1024;
const int _gb = 1024 * _mb;

/// How full the phone is.
enum StorageLevel {
  /// Plenty of room.
  ok,

  /// Getting close: warn so the user can clean up at their leisure.
  low,

  /// Nearly out: photos, videos and app updates may fail to save now.
  critical,
}

/// Free and total space on the phone's main storage, in bytes.
class StorageReading {
  const StorageReading({required this.freeBytes, required this.totalBytes});

  /// From the megabyte values `disk_space_plus` reports.
  factory StorageReading.fromMb({required double freeMb, required double totalMb}) =>
      StorageReading(freeBytes: (freeMb * _mb).round(), totalBytes: (totalMb * _mb).round());

  final int freeBytes;
  final int totalBytes;

  /// False when the phone didn't report a size (emulator quirks, errors).
  bool get isValid => totalBytes > 0 && freeBytes >= 0 && freeBytes <= totalBytes;

  double get freeFraction => isValid ? freeBytes / totalBytes : 1;
}

/// When storage counts as low or critical.
///
/// Each level triggers at whichever is *smaller*: a share of the phone's size
/// or a fixed amount. The share keeps small phones (16–32 GB) from being warned
/// too late; the fixed amount keeps large phones (256 GB+) from being warned
/// while they still have tens of gigabytes free.
class StorageAlertPolicy {
  const StorageAlertPolicy({
    this.lowFraction = 0.10,
    this.lowBytes = 5 * _gb,
    this.criticalFraction = 0.05,
    this.criticalBytes = 1 * _gb,
    this.repeatAfter = const Duration(hours: 24),
  });

  final double lowFraction;
  final int lowBytes;
  final double criticalFraction;
  final int criticalBytes;

  /// A warning at the same level is repeated no more often than this.
  final Duration repeatAfter;

  int lowThreshold(int totalBytes) => _smaller((totalBytes * lowFraction).round(), lowBytes);

  int criticalThreshold(int totalBytes) =>
      _smaller((totalBytes * criticalFraction).round(), criticalBytes);

  StorageLevel levelOf(StorageReading r) {
    if (!r.isValid) return StorageLevel.ok;
    if (r.freeBytes < criticalThreshold(r.totalBytes)) return StorageLevel.critical;
    if (r.freeBytes < lowThreshold(r.totalBytes)) return StorageLevel.low;
    return StorageLevel.ok;
  }

  static int _smaller(int a, int b) => a < b ? a : b;
}

/// What was last told to the user, saved between checks (and between the app
/// and the background check).
class StorageAlertMemory {
  const StorageAlertMemory({this.level = StorageLevel.ok, this.notifiedAt});

  /// Level of the notification currently showing; [StorageLevel.ok] when none.
  final StorageLevel level;
  final DateTime? notifiedAt;

  String encode() => '${level.name}|${notifiedAt?.millisecondsSinceEpoch ?? ''}';

  static StorageAlertMemory decode(String? s) {
    if (s == null) return const StorageAlertMemory();
    final parts = s.split('|');
    final level = StorageLevel.values.where((l) => l.name == parts.first).firstOrNull;
    if (level == null) return const StorageAlertMemory();
    final ms = parts.length > 1 ? int.tryParse(parts[1]) : null;
    return StorageAlertMemory(
      level: level,
      notifiedAt: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }
}

/// What to do after a check.
enum StorageAlertAction {
  /// Post (or replace) the storage notification.
  notify,

  /// Storage is fine again: take the notification down.
  clear,

  /// Nothing changed worth bothering the user about.
  none,
}

class StorageAlertDecision {
  const StorageAlertDecision(this.action, this.level, this.memory);

  final StorageAlertAction action;
  final StorageLevel level;

  /// Save this for the next check.
  final StorageAlertMemory memory;
}

/// Decides whether a check should notify.
///
/// - Storage got worse (ok → low, low → critical): notify now.
/// - Still at the same level: remind once [StorageAlertPolicy.repeatAfter]
///   has passed, so the user isn't nagged on every check.
/// - Got better but still low (critical → low): keep quiet, update memory.
/// - Back to ok: clear the notification.
StorageAlertDecision decideStorageAlert({
  required StorageReading reading,
  required StorageAlertMemory memory,
  required DateTime now,
  StorageAlertPolicy policy = const StorageAlertPolicy(),
}) {
  final level = policy.levelOf(reading);
  if (level == StorageLevel.ok) {
    return StorageAlertDecision(
      memory.level == StorageLevel.ok ? StorageAlertAction.none : StorageAlertAction.clear,
      level,
      const StorageAlertMemory(),
    );
  }
  final worse = level.index > memory.level.index;
  final last = memory.notifiedAt;
  final due = last == null || !now.isBefore(last.add(policy.repeatAfter)) || now.isBefore(last);
  if (worse || (level == memory.level && due)) {
    return StorageAlertDecision(
        StorageAlertAction.notify, level, StorageAlertMemory(level: level, notifiedAt: now));
  }
  return StorageAlertDecision(
      StorageAlertAction.none, level, StorageAlertMemory(level: level, notifiedAt: last));
}

/// Title and body of a storage notification.
class StorageAlertMessage {
  const StorageAlertMessage(this.title, this.body);

  final String title;
  final String body;

  factory StorageAlertMessage.of(StorageLevel level, StorageReading r) {
    final free = formatFreeSpace(r.freeBytes);
    return switch (level) {
      StorageLevel.critical => StorageAlertMessage(
          'Storage almost full',
          'Only $free left. New photos and videos may not save. '
              'Tap to free up space with DataMuncher.'),
      _ => StorageAlertMessage(
          'Storage running low',
          '$free free (${(r.freeFraction * 100).round()}%). '
              'Clear duplicates and junk now so your camera never runs out of room.'),
    };
  }
}

/// "1.2 GB", "850 MB".
String formatFreeSpace(int bytes) {
  if (bytes >= _gb) return '${(bytes / _gb).toStringAsFixed(1)} GB';
  return '${(bytes / _mb).round()} MB';
}
