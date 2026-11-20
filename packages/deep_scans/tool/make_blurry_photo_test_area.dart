import 'dart:io';

import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;

/// Builds the blurry photo test area: a fake phone's camera roll with
/// blurry photos from each scenario in the project doc, look-alikes that
/// must not be flagged, empty and unreadable photo files, and an
/// `expected.json` describing all of them.
///
///   dart run tool/make_blurry_photo_test_area.dart [output-folder]
///
/// Defaults to `test_area/blurry_photos`. Then scan it with:
///
///   dart run deep_scans:blurry_photo_scan test_area/blurry_photos --grant-access
Future<void> main(List<String> args) async {
  final root = args.isEmpty ? p.join('test_area', 'blurry_photos') : args.first;
  try {
    final area = await buildBlurryPhotoTestArea(root);
    final blurry = area.photos
        .where((e) => e.rule != null && e.rule!.startsWith('B'))
        .length;
    final broken = area.photos
        .where((e) => e.rule != null && !e.rule!.startsWith('B'))
        .length;
    stdout
      ..writeln('Test area written to ${p.relative(area.root)}')
      ..writeln('  ${area.photos.length} files: $blurry blurry photos, '
          '$broken empty or unreadable photos, '
          '${area.photos.length - blurry - broken} look-alikes that must not '
          'be flagged')
      ..writeln('  expectations: ${p.relative(area.manifest)}');
  } on StateError catch (e) {
    stderr.writeln('${e.message}; choose another folder.');
    exitCode = 1;
  }
}
