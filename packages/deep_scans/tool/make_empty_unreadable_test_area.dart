import 'dart:io';

import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;

/// Builds the empty & unreadable test area: a folder of planted examples
/// for every rule, plus look-alikes that must not be flagged, and an
/// `expected.json` saying what each file should get.
///
///   dart run tool/make_empty_unreadable_test_area.dart [output-folder]
///
/// Defaults to `test_area/empty_unreadable`. Then scan it with:
///
///   dart run deep_scans:empty_unreadable_scan test_area/empty_unreadable --grant-access
Future<void> main(List<String> args) async {
  final root =
      args.isEmpty ? p.join('test_area', 'empty_unreadable') : args.first;
  try {
    final area = await buildEmptyUnreadableTestArea(root);
    final flagged = area.cases.where((c) => c.rule != null).length;
    stdout
      ..writeln('Test area written to ${p.relative(area.root)}')
      ..writeln('  ${area.cases.length} files: $flagged should be flagged, '
          '${area.cases.length - flagged} should not')
      ..writeln('  expectations: ${p.relative(area.manifest)}');
    if (!area.cases.any((c) => c.rule == 'U01')) {
      stdout.writeln('  (U01 "cannot be opened" example skipped: needs chmod '
          'and a non-root user; covered by unit tests)');
    }
  } on StateError catch (e) {
    stderr.writeln('${e.message}; choose another folder.');
    exitCode = 1;
  }
}
