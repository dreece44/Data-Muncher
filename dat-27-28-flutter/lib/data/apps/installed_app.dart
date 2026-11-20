import 'package:flutter/foundation.dart';

/// An app installed on the phone, with the usage data needed to decide
/// whether it is still used.
///
/// Same fields and JSON as `InstalledApp` in the scan engine
/// (packages/scan_engine, DAT-1), so the two can be swapped once that
/// package is merged.
@immutable
class InstalledApp {
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

  /// App, data and cache together.
  final int sizeBytes;
  final DateTime? installedAt;

  /// Last time the app was on screen, or null if the phone has no record of
  /// it being used.
  final DateTime? lastUsedAt;

  /// Pre-installed apps. These can't be uninstalled, so they are never
  /// suggested.
  final bool isSystem;

  /// Apps that work without being opened (home screen, keyboard, SMS,
  /// phone, or anything without a launcher icon). They look unused but
  /// aren't.
  final bool isEssential;

  /// Accepts epoch milliseconds (what the Android side sends) or ISO-8601.
  factory InstalledApp.fromJson(Map<Object?, Object?> json) {
    final packageName = json['packageName'];
    if (packageName is! String || packageName.isEmpty) {
      throw FormatException('App without a packageName: $json');
    }
    final label = json['label'];
    return InstalledApp(
      packageName: packageName,
      label: label is String && label.isNotEmpty ? label : packageName,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      installedAt: _date(json['installedAt']),
      lastUsedAt: _date(json['lastUsedAt']),
      isSystem: (json['isSystem'] as bool?) ?? false,
      isEssential: (json['isEssential'] as bool?) ?? false,
    );
  }

  static DateTime? _date(Object? value) => switch (value) {
        null => null,
        int ms when ms <= 0 => null,
        int ms => DateTime.fromMillisecondsSinceEpoch(ms),
        String s => DateTime.parse(s),
        _ => throw FormatException('Not a date: $value'),
      };

  InstalledApp copyWith({DateTime? lastUsedAt, int? sizeBytes}) => InstalledApp(
        packageName: packageName,
        label: label,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        installedAt: installedAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        isSystem: isSystem,
        isEssential: isEssential,
      );

  @override
  bool operator ==(Object other) =>
      other is InstalledApp &&
      other.packageName == packageName &&
      other.label == label &&
      other.sizeBytes == sizeBytes &&
      other.installedAt == installedAt &&
      other.lastUsedAt == lastUsedAt &&
      other.isSystem == isSystem &&
      other.isEssential == isEssential;

  @override
  int get hashCode => Object.hash(packageName, label, sizeBytes, installedAt,
      lastUsedAt, isSystem, isEssential);

  @override
  String toString() => 'InstalledApp($packageName)';
}
