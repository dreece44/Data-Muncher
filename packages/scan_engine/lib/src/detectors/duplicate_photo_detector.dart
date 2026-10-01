import 'package:crypto/crypto.dart';

import '../imaging/image_features.dart';
import '../model/finding.dart';
import '../model/storage_item.dart';
import '../model/waste_category.dart';
import '../scan/scan_context.dart';
import 'waste_detector.dart';

/// Groups of identical or near-identical photos: re-saved copies, burst
/// shots, the same receipt photographed several times.
///
/// Photos are compared by perceptual hash, so copies match even after being
/// resized or recompressed (e.g. sent through a messaging app). Blank photos
/// are left to BlankPhotoDetector, since all-black shots would otherwise all
/// "match" each other.
final class DuplicatePhotoDetector extends WasteDetector {
  const DuplicatePhotoDetector();

  @override
  WasteCategory get category => WasteCategory.duplicatePhoto;

  @override
  Future<List<Finding>> detect(ScanContext context) async {
    final rules = context.rules;
    final photos = [
      for (final i in context.items)
        if (i.isPhoto) i
    ];
    await context.analyzeImages(category, photos);

    final candidates = <_Photo>[];
    for (final item in photos) {
      final analysis = await context.analyzeImage(item);
      if (analysis is AnalyzedImage &&
          analysis.features.stdDev > rules.blankMaxStdDev) {
        candidates.add(_Photo(item, analysis.features));
      }
    }

    // Each group is anchored on its first photo. Comparing against the anchor
    // rather than any member stops a long chain of gradually changing shots
    // from merging into one huge group.
    final groups = <List<_Photo>>[];
    for (var i = 0; i < candidates.length; i++) {
      context.tick(category, i + 1, candidates.length);
      final photo = candidates[i];
      final group =
          groups.where((g) => _similar(g.first, photo, context)).firstOrNull;
      if (group != null) {
        group.add(photo);
      } else {
        groups.add([photo]);
      }
    }

    final findings = <Finding>[];
    for (final group in groups.where((g) => g.length > 1)) {
      final keep = _bestCopy(group);
      final exact = await _allIdentical(context, group);
      findings.add(Finding(
        category: category,
        items: [for (final p in group) p.item],
        keep: keep.item,
        reason: exact
            ? '${group.length} identical copies of the same photo'
            : '${group.length} near-identical photos; keeping the '
                'highest-resolution one',
      ));
    }
    findings.sort((a, b) => b.reclaimableBytes.compareTo(a.reclaimableBytes));
    return findings;
  }

  bool _similar(_Photo a, _Photo b, ScanContext context) =>
      hammingDistance(a.features.coarseHash, b.features.coarseHash) <=
          context.rules.nearDuplicateCoarseDistance &&
      hammingDistance(a.features.fineHash, b.features.fineHash) <=
          context.rules.nearDuplicateFineDistance;

  /// The copy to keep: most pixels, then largest file (least compressed),
  /// then oldest (most likely the original).
  ///
  /// Placeholder for DAT-34, which will also use blur scores (DAT-22) to
  /// pick the clearest copy.
  _Photo _bestCopy(List<_Photo> group) {
    final ranked = [...group]..sort((a, b) {
        final byPixels = b.features.pixelCount.compareTo(a.features.pixelCount);
        if (byPixels != 0) return byPixels;
        final bySize = b.item.sizeBytes.compareTo(a.item.sizeBytes);
        if (bySize != 0) return bySize;
        final aTime = a.item.modified, bTime = b.item.modified;
        if (aTime == null || bTime == null) return 0;
        return aTime.compareTo(bTime);
      });
    return ranked.first;
  }

  /// Whether every photo in the group is byte-for-byte identical. Only
  /// hashes contents when sizes already match, and only where the platform
  /// lets the engine read raw bytes.
  Future<bool> _allIdentical(ScanContext context, List<_Photo> group) async {
    final first = group.first.item;
    if (group.any((p) =>
        p.item.sizeBytes != first.sizeBytes ||
        !context.source.canReadContent(p.item))) {
      return false;
    }
    try {
      final digests = {
        for (final p in group)
          (await sha256.bind(context.source.openRead(p.item)).first).toString(),
      };
      return digests.length == 1;
    } on Exception {
      return false; // Couldn't read one; still near-identical.
    }
  }
}

final class _Photo {
  _Photo(this.item, this.features);
  final StorageItem item;
  final ImageFeatures features;
}
