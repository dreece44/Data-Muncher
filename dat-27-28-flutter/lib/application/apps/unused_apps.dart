import 'package:flutter/foundation.dart';

import '../../data/apps/installed_app.dart';

/// PB-10 / DAT-25 Unused app detection rules.
///
/// Same rules as `UnusedAppDetector` in the scan engine (DAT-1): system and
/// essential apps are never suggested, recently installed apps get a grace
/// period, and anything else not opened within [UnusedAppRules.unusedAfter]
/// is unused.
@immutable
class UnusedAppRules {
  const UnusedAppRules({this.unusedAfter = const Duration(days: 90)});

  /// Apps not opened for this long are reported as unused.
  final Duration unusedAfter;
}

/// An app suggested for removal.
@immutable
class UnusedApp {
  const UnusedApp({required this.app, required this.reason, this.daysUnused});

  final InstalledApp app;

  /// Plain-language explanation, e.g. "Last opened 120 days ago".
  final String reason;

  /// Days since last opened, or null if it has never been seen in use.
  final int? daysUnused;
}

/// The apps in [apps] that look unused at [now], largest first.
/// [isKept] says which ones the user chose to keep (DAT-32).
List<UnusedApp> findUnusedApps(
  Iterable<InstalledApp> apps, {
  required DateTime now,
  UnusedAppRules rules = const UnusedAppRules(),
  bool Function(String packageName)? isKept,
}) {
  final cutoff = now.subtract(rules.unusedAfter);
  final days = rules.unusedAfter.inDays;
  final found = <UnusedApp>[];
  for (final app in apps) {
    if (app.isSystem || app.isEssential) continue;
    if (isKept?.call(app.packageName) ?? false) continue;
    // Recently installed apps haven't had a chance to be used yet.
    final installed = app.installedAt;
    if (installed != null && installed.isAfter(cutoff)) continue;
    final lastUsed = app.lastUsedAt;
    if (lastUsed != null && !lastUsed.isBefore(cutoff)) continue;

    final daysUnused = lastUsed == null ? null : now.difference(lastUsed).inDays;
    found.add(UnusedApp(
      app: app,
      daysUnused: daysUnused,
      reason: daysUnused == null
          ? 'Not opened in at least $days days'
          : 'Last opened $daysUnused days ago',
    ));
  }
  found.sort((a, b) {
    final bySize = b.app.sizeBytes.compareTo(a.app.sizeBytes);
    if (bySize != 0) return bySize;
    return a.app.label.toLowerCase().compareTo(b.app.label.toLowerCase());
  });
  return found;
}
