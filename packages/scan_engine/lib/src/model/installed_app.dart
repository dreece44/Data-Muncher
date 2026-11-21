import 'storage_item.dart';

/// An app installed on the device, with the usage data needed to decide
/// whether it is still used.
final class InstalledApp implements Reclaimable {
  const InstalledApp({
    required this.packageName,
    required this.label,
    required this.sizeBytes,
    this.installedAt,
    this.lastUsedAt,
    this.isSystem = false,
    this.isEssential = false,
  });

  final String packageName;
  final String label;
  @override
  final int sizeBytes;
  final DateTime? installedAt;

  /// Last time the app was in the foreground, or null if the OS has no
  /// record of it being used.
  final DateTime? lastUsedAt;

  /// Pre-installed apps. These can't be uninstalled, so they are never
  /// suggested.
  final bool isSystem;

  /// Apps that work without being opened (the default launcher, keyboard or
  /// SMS app). They look unused but aren't.
  final bool isEssential;

  @override
  String get id => packageName;
  @override
  String get displayName => label;

  factory InstalledApp.fromJson(Map<String, Object?> json) => InstalledApp(
        packageName: json['packageName'] as String,
        label: (json['label'] as String?) ?? json['packageName'] as String,
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        installedAt: _date(json['installedAt']),
        lastUsedAt: _date(json['lastUsedAt']),
        isSystem: (json['isSystem'] as bool?) ?? false,
        isEssential: (json['isEssential'] as bool?) ?? false,
      );

  /// Accepts ISO-8601 strings or epoch milliseconds (what the Android
  /// platform channel sends).
  static DateTime? _date(Object? value) => switch (value) {
        null => null,
        int ms => DateTime.fromMillisecondsSinceEpoch(ms),
        String s => DateTime.parse(s),
        _ => throw FormatException('Not a date: $value'),
      };

  @override
  Map<String, Object?> toJson() => {
        'type': 'app',
        'id': packageName,
        'name': label,
        'sizeBytes': sizeBytes,
        if (installedAt != null) 'installedAt': installedAt!.toIso8601String(),
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
      };
}
