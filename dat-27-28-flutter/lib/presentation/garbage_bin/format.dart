// Plain-language formatting for the Garbage Bin Viewer. No intl dependency.

import '../../application/garbage_bin/empty_bin.dart';

const List<String> _byteUnits = ['B', 'KB', 'MB', 'GB', 'TB'];

const List<String> _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Formats a size the way phone storage settings do (1 KB = 1000 bytes):
/// `0 B`, `1.5 KB`, `4.2 MB`, `123 MB`, `1.2 GB`.
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  var value = bytes.toDouble();
  var unit = 0;
  // 999.5 rather than 1000 so a value never rounds up to "1000 KB".
  while (value >= 999.5 && unit < _byteUnits.length - 1) {
    value /= 1000;
    unit++;
  }
  var text = value.toStringAsFixed(value >= 100 ? 0 : 1);
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  return '$text ${_byteUnits[unit]}';
}

/// `Oct 7, 2026`
String formatDate(DateTime date) {
  final local = date.toLocal();
  return '${_monthNames[local.month - 1]} ${local.day}, ${local.year}';
}

/// Whole calendar days from [from] to [to], ignoring the time of day.
int calendarDaysBetween(DateTime from, DateTime to) {
  final a = from.toLocal();
  final b = to.toLocal();
  // UTC dates so daylight-saving changes can't make a day 23 or 25 hours.
  return DateTime.utc(b.year, b.month, b.day)
      .difference(DateTime.utc(a.year, a.month, a.day))
      .inDays;
}

/// When a file went into the bin: `Today`, `Yesterday`, `3 days ago`, or a
/// date once it's a week or more old.
String formatCollectedAt(DateTime collectedAt, DateTime now) {
  final days = calendarDaysBetween(collectedAt, now);
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return '$days days ago';
  return formatDate(collectedAt);
}

/// How long until a file leaves the bin.
String formatTimeLeft(DateTime expiresAt, DateTime now) {
  final remaining = expiresAt.difference(now);
  if (remaining <= Duration.zero) return 'Due for removal';
  if (remaining < const Duration(days: 1)) return 'Less than a day left';
  final days = remaining.inDays;
  return days == 1 ? '1 day left' : '$days days left';
}

/// `1 file`, `3 files`
String pluralize(int count, String noun) =>
    count == 1 ? '1 $noun' : '$count ${noun}s';

/// The message shown after emptying the bin.
String describeEmptyBin(EmptyBinReport report) {
  if (report.removedCount == 0) {
    return 'Nothing was deleted. Your files are still in the bin.';
  }
  final size = formatBytes(report.removedBytes);
  final files = pluralize(report.removedCount, 'file');
  final kept = report.keptCount;
  final restorable = report.restorableFor;
  final text = StringBuffer();

  if (restorable == null) {
    text.write(kept == 0
        ? 'Emptied the bin and freed $size.'
        : 'Deleted $files and freed $size.');
  } else {
    text.write(kept == 0
        ? 'Emptied the bin: $files ($size).'
        : 'Removed $files ($size) from the bin.');
  }
  if (kept > 0) {
    text.write(' ${pluralize(kept, 'file')} ${kept == 1 ? 'is' : 'are'} '
        'still in the bin.');
  }
  if (restorable != null) {
    text.write(" You can restore ${report.removedCount == 1 ? 'it' : 'them'} "
        "from your phone's trash for ${restorable.inDays} days; "
        'the space is freed after that.');
  }
  return text.toString();
}
