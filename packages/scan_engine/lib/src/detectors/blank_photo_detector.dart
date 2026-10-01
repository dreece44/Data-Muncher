import '../model/finding.dart';
import '../model/waste_category.dart';
import '../scan/scan_context.dart';
import 'waste_detector.dart';

/// Photos that are one flat colour: pocket shots, lens-cap photos, blank
/// screenshots.
final class BlankPhotoDetector extends WasteDetector {
  const BlankPhotoDetector();

  @override
  WasteCategory get category => WasteCategory.blankPhoto;

  @override
  Future<List<Finding>> detect(ScanContext context) async {
    final photos = [
      for (final i in context.items)
        if (i.isPhoto) i
    ];
    await context.analyzeImages(category, photos);

    final findings = <Finding>[];
    for (final item in photos) {
      final analysis = await context.analyzeImage(item);
      if (analysis is! AnalyzedImage) continue;
      final f = analysis.features;
      if (f.stdDev > context.rules.blankMaxStdDev) continue;
      final looks = f.mean < 40
          ? 'almost entirely black'
          : f.mean > 215
              ? 'almost entirely white'
              : 'a single flat colour';
      findings.add(Finding(
          category: category,
          items: [item],
          reason: 'Photo is $looks with no visible detail'));
    }
    return findings;
  }
}
