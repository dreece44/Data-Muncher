import 'dart:io';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;

/// Builds the screenshot test area: a fake phone and computer with
/// screenshots from each scenario in the project doc, blank and empty
/// screenshots, screenshot files that are empty or unreadable, look-alikes
/// that must not be flagged, and an `expected.json` describing all of them.
///
///   dart run tool/make_screenshot_test_area.dart [output-folder]
///
/// Defaults to `test_area/screenshot_detection` (not `…/screenshots`: a
/// folder of that name above the files would count as a screenshots
/// folder). Then scan it with:
///
///   dart run deep_scans:screenshot_scan test_area/screenshot_detection --grant-access
Future<void> main(List<String> args) async {
  final root =
      args.isEmpty ? p.join('test_area', 'screenshot_detection') : args.first;
  try {
    final area = await buildScreenshotTestArea(root);
    bool screenshot(ExpectedScreenshot e) =>
        e.rule != null && ScreenshotRule.byCode(e.rule!) != null;
    final shots = area.images.where(screenshot).length;
    final empty = area.images
        .where((e) => screenshot(e) && ScreenshotRule.byCode(e.rule!)!.empty)
        .length;
    final broken =
        area.images.where((e) => e.rule != null && !screenshot(e)).length;
    stdout
      ..writeln('Test area written to ${p.relative(area.root)}')
      ..writeln('  ${area.images.length} files: $shots screenshots '
          '($empty of them blank or empty), $broken empty or unreadable '
          'screenshot files, ${area.images.length - shots - broken} '
          'look-alikes and held-back screenshots that must not be flagged')
      ..writeln('  expectations: ${p.relative(area.manifest)}');
  } on StateError catch (e) {
    stderr.writeln('${e.message}; choose another folder.');
    exitCode = 1;
  }
}
