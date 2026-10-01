import '../model/finding.dart';
import '../model/storage_item.dart';
import '../model/waste_category.dart';
import '../platform/storage_source.dart';
import '../scan/scan_context.dart';
import 'waste_detector.dart';

/// Files with no content: zero bytes long, or small files containing only
/// whitespace / zero bytes (e.g. failed downloads, blank notes).
final class EmptyFileDetector extends WasteDetector {
  const EmptyFileDetector();

  @override
  WasteCategory get category => WasteCategory.emptyFile;

  @override
  Future<List<Finding>> detect(ScanContext context) async {
    final rules = context.rules;
    final files = [
      for (final item in context.items)
        if (item.origin == ItemOrigin.fileSystem &&
            !rules.ignoredEmptyFileNames.contains(item.displayName))
          item,
    ];

    final findings = <Finding>[];
    for (var i = 0; i < files.length; i++) {
      context.tick(category, i + 1, files.length);
      final item = files[i];
      if (item.sizeBytes == 0) {
        findings.add(Finding(
            category: category, items: [item], reason: 'File is 0 bytes'));
      } else if (item.sizeBytes <= rules.blankContentMaxBytes &&
          context.source.canReadContent(item)) {
        try {
          final bytes = await context.source.readRange(item, 0, item.sizeBytes);
          if (isBlankContent(bytes)) {
            findings.add(Finding(
                category: category,
                items: [item],
                reason: 'File contains only blank space'));
          }
        } on StorageReadException {
          // UnreadableFileDetector reports files that can't be opened.
        }
      }
    }
    return findings;
  }
}
