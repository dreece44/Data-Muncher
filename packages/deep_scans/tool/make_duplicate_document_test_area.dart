import 'dart:io';

import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;

/// Builds the duplicate document test area: a fake phone's Documents,
/// Download and messaging folders with planted duplicate groups, documents
/// that must stay apart, empty and unreadable documents that must be left
/// out, and an `expected.json` describing all three.
///
///   dart run tool/make_duplicate_document_test_area.dart [output-folder]
///
/// Defaults to `test_area/duplicate_documents`. Then scan it with:
///
///   dart run deep_scans:duplicate_document_scan test_area/duplicate_documents --grant-access
Future<void> main(List<String> args) async {
  final root =
      args.isEmpty ? p.join('test_area', 'duplicate_documents') : args.first;
  try {
    final area = await buildDuplicateDocumentTestArea(root);
    stdout
      ..writeln('Test area written to ${p.relative(area.root)}')
      ..writeln('  ${area.fileCount} files: ${area.groups.length} duplicate '
          'groups, ${area.singles.length} files that must stay apart, '
          '${area.health.length} empty/unreadable/in-progress documents')
      ..writeln('  expectations: ${p.relative(area.manifest)}')
      ..writeln('  one download is "in progress" for 10 minutes; scan within '
          'that time or after it, the expectations follow the clock');
  } on StateError catch (e) {
    stderr.writeln('${e.message}; choose another folder.');
    exitCode = 1;
  }
}
