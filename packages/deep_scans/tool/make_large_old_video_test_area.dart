import 'dart:io';

import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;

/// Builds the large & old video test area: Timmy's game and desktop
/// recordings, editing projects, the recording that failed to save, phone
/// camera rolls and chat videos from the other personas, broken videos of
/// every kind, look-alikes that must not be flagged, and an
/// `expected.json` describing all of them.
///
///   dart run tool/make_large_old_video_test_area.dart [output-folder]
///
/// Files are written at 1/1024 of real size (1 MB stands for 1 GB, ~40 MB
/// in all). Then scan it with:
///
///   dart run deep_scans:large_old_video_scan test_area/large_old_videos --grant-access
Future<void> main(List<String> args) async {
  final root =
      args.isEmpty ? p.join('test_area', 'large_old_videos') : args.first;
  try {
    final area = await buildLargeOldVideoTestArea(root);
    bool broken(ExpectedVideo e) =>
        e.rule != null && (VideoRule.byCode(e.rule!)?.health ?? true);
    final flagged = area.videos.where((e) => e.rule != null).length;
    final bad = area.videos.where(broken).length;
    stdout
      ..writeln('Test area written to ${p.relative(area.root)}')
      ..writeln('  ${area.videos.length} videos at 1/${area.sizeScale} of '
          'real size: $bad broken (V01–V04 and empty & unreadable), '
          '${flagged - bad} large or old, '
          '${area.videos.length - flagged} that must not be flagged')
      ..writeln('  expectations: ${p.relative(area.manifest)}');
  } on StateError catch (e) {
    stderr.writeln('${e.message}; choose another folder.');
    exitCode = 1;
  }
}
