import 'package:scan_engine_flutter/scan_engine_flutter.dart' as engine;

import '../../data/garbage_bin/bin_entry.dart';

/// One file the storage scan (DAT-1) suggests sending to the Garbage Bin.
class ScanCandidate {
  const ScanCandidate({required this.item, required this.reason, required this.explanation});

  final engine.StorageItem item;
  final CollectionReason reason;

  /// The engine's plain-language reason, e.g. "Download never finished".
  final String explanation;

  String get path => item.path!;
}

/// The bin reason for a scan category.
CollectionReason reasonForCategory(engine.WasteCategory category) => switch (category) {
      engine.WasteCategory.emptyFile => CollectionReason.emptyFile,
      engine.WasteCategory.unreadableFile => CollectionReason.unreadable,
      engine.WasteCategory.duplicatePhoto => CollectionReason.duplicate,
      engine.WasteCategory.blankPhoto => CollectionReason.blank,
      engine.WasteCategory.unusedApp => CollectionReason.unusedApp,
    };

/// When one file is flagged more than once, the most clear-cut reason wins.
const List<engine.WasteCategory> _priority = [
  engine.WasteCategory.emptyFile,
  engine.WasteCategory.unreadableFile,
  engine.WasteCategory.blankPhoto,
  engine.WasteCategory.duplicatePhoto,
];

/// Files from [report] that can be moved to the Garbage Bin, one per file,
/// in the order the scan found them.
///
/// Only files with a path qualify: unused apps have to be uninstalled, and
/// iOS photo library items aren't files. For a duplicate group the copy the
/// engine suggests keeping is left out. [skip] drops paths the user asked
/// not to collect.
List<ScanCandidate> candidatesFrom(engine.ScanReport report, {bool Function(String path)? skip}) {
  final best = <String, (engine.Finding, engine.StorageItem)>{};
  for (final finding in report.findings) {
    if (!_priority.contains(finding.category)) continue;
    for (final item in finding.removable) {
      if (item is! engine.StorageItem || item.path == null) continue;
      if (skip?.call(item.path!) ?? false) continue;
      final current = best[item.id];
      if (current == null || _rank(finding) < _rank(current.$1)) best[item.id] = (finding, item);
    }
  }
  return [
    for (final (finding, item) in best.values)
      ScanCandidate(item: item, reason: reasonForCategory(finding.category), explanation: finding.reason),
  ];
}

int _rank(engine.Finding f) => _priority.indexOf(f.category);

/// A check the scan didn't finish, explained on the results page so a
/// missing category isn't mistaken for "nothing found".
class SkippedCheck {
  const SkippedCheck({required this.category, required this.state, required this.message});

  final engine.WasteCategory category;
  final engine.CategoryState state;
  final String message;

  /// The unused-app check was skipped for want of Android's Usage access,
  /// which the user can turn on.
  bool get needsUsageAccess =>
      category == engine.WasteCategory.unusedApp && state == engine.CategoryState.skipped;
}

/// The categories in [report] that were skipped, unsupported or failed.
List<SkippedCheck> skippedChecksFrom(engine.ScanReport report) => [
      for (final MapEntry(key: category, value: result) in report.categories.entries)
        if (result.state != engine.CategoryState.completed)
          SkippedCheck(
            category: category,
            state: result.state,
            message: switch (result.state) {
              engine.CategoryState.skipped when category == engine.WasteCategory.unusedApp =>
                "Unused apps weren't checked. DataMuncher needs Usage access to see "
                    "which apps you haven't opened in a while.",
              engine.CategoryState.skipped => "${category.label} weren't checked: ${result.note ?? 'permission missing'}.",
              engine.CategoryState.unsupported =>
                "${category.label} can't be checked on this phone${result.note == null ? '' : ': ${result.note}'}.",
              _ => "Couldn't check ${category.label.toLowerCase()}${result.note == null ? '' : ': ${result.note}'}.",
            },
          ),
    ];

/// Unused-app findings, which the user deals with by uninstalling.
List<engine.InstalledApp> unusedAppsFrom(engine.ScanReport report) => [
      for (final finding in report.findingsFor(engine.WasteCategory.unusedApp))
        for (final item in finding.removable)
          if (item is engine.InstalledApp) item,
    ];
