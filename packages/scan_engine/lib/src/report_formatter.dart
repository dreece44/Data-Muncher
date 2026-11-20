import 'package:path/path.dart' as p;

import 'model/scan_report.dart';
import 'model/storage_item.dart';
import 'model/waste_category.dart';

/// `1536` → `1.5 KB`. Uses 1024-based units, like phone storage screens.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// Plain-text version of a report, for the command-line scanner and
/// on-device test logs.
///
/// File paths are shown relative to [relativeTo] when given. At most
/// [maxPerCategory] findings are listed per category.
String formatReport(ScanReport report,
    {String? relativeTo, int maxPerCategory = 20}) {
  final out = StringBuffer();
  final seconds = report.duration.inMilliseconds / 1000;
  out.writeln('DataMuncher scan (${report.platform.name})');
  final storage = report.storage;
  out.writeln(storage == null
      ? 'Device storage: totals not available'
      : 'Device storage: ${formatBytes(storage.usedBytes)} used of '
          '${formatBytes(storage.totalBytes)} '
          '(${formatBytes(storage.freeBytes)} free)');
  out.writeln('Scanned ${report.itemsScanned} items '
      '(${formatBytes(report.bytesScanned)}) in ${seconds.toStringAsFixed(1)} s');
  out.writeln('Reclaimable: ${formatBytes(report.reclaimableBytes)}');
  out.writeln();

  for (final e in report.categories.entries) {
    final label = e.key.label.padRight(18);
    final result = e.value;
    final findings = report.findingsFor(e.key);
    out.writeln(switch (result.state) {
      CategoryState.completed => '  $label ${findings.length} found, '
          '${formatBytes(report.reclaimableBytesFor(e.key))} reclaimable',
      CategoryState.unsupported => '  $label not supported: ${result.note}',
      CategoryState.skipped => '  $label skipped: ${result.note}',
      CategoryState.failed => '  $label FAILED: ${result.note}',
    });
  }

  for (final category in WasteCategory.values) {
    final findings = report.findingsFor(category);
    if (findings.isEmpty) continue;
    out
      ..writeln()
      ..writeln('${category.label}:');
    for (final f in findings.take(maxPerCategory)) {
      if (f.keep == null) {
        out.writeln('  - ${_name(f.items.single, relativeTo)} '
            '(${formatBytes(f.reclaimableBytes)}): ${f.reason}');
      } else {
        out.writeln('  - ${f.reason} (${formatBytes(f.reclaimableBytes)} '
            'reclaimable)');
        for (final item in f.items) {
          final tag = item.id == f.keep!.id ? 'keep  ' : 'remove';
          out.writeln('      $tag ${_name(item, relativeTo)}');
        }
      }
    }
    if (findings.length > maxPerCategory) {
      out.writeln('  … and ${findings.length - maxPerCategory} more');
    }
  }

  if (report.issues.isNotEmpty) {
    out
      ..writeln()
      ..writeln('Issues:');
    for (final issue in report.issues) {
      out.writeln('  - $issue');
    }
  }
  if (report.notes.isNotEmpty) {
    out
      ..writeln()
      ..writeln('Notes:');
    for (final note in report.notes) {
      out.writeln('  - $note');
    }
  }
  return out.toString();
}

String _name(Reclaimable item, String? relativeTo) {
  if (item is StorageItem && item.path != null && relativeTo != null) {
    return p.relative(item.path!, from: relativeTo).replaceAll(r'\', '/');
  }
  return item.displayName;
}
