import 'dart:io';

import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;

/// Builds the duplicate photo test area: a fake phone's photo folders with
/// planted duplicate groups (one per scenario in the project doc), photos
/// that must stay apart, and an `expected.json` describing both.
///
///   dart run tool/make_duplicate_photo_test_area.dart [output-folder]
///
/// Defaults to `test_area/duplicate_photos`. Then scan it with:
///
///   dart run deep_scans:duplicate_photo_scan test_area/duplicate_photos --grant-access
Future<void> main(List<String> args) async {
  final root =
      args.isEmpty ? p.join('test_area', 'duplicate_photos') : args.first;
  try {
    final area = await buildDuplicatePhotoTestArea(root);
    stdout
      ..writeln('Test area written to ${p.relative(area.root)}')
      ..writeln('  ${area.fileCount} photos: ${area.groups.length} duplicate '
          'groups, ${area.singles.length} photos that must stay apart')
      ..writeln('  expectations: ${p.relative(area.manifest)}');
  } on StateError catch (e) {
    stderr.writeln('${e.message}; choose another folder.');
    exitCode = 1;
  }
}
