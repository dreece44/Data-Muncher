import '../imaging/image_features.dart';
import '../model/scan_report.dart';
import '../model/storage_item.dart';
import '../model/waste_category.dart';
import '../platform/device_adapter.dart';
import '../platform/storage_source.dart';
import 'scan_progress.dart';
import 'scan_rules.dart';

/// Outcome of analysing one image.
sealed class ImageAnalysis {
  const ImageAnalysis();
}

final class AnalyzedImage extends ImageAnalysis {
  const AnalyzedImage(this.features);
  final ImageFeatures features;
}

/// The file has an image extension but its data can't be decoded.
final class UndecodableImage extends ImageAnalysis {
  const UndecodableImage();
}

/// Not analysed (too small to be a photo, too large, unsupported format…).
final class SkippedImage extends ImageAnalysis {
  const SkippedImage(this.reason);
  final String reason;
}

/// Shared state for one scan, handed to every detector.
final class ScanContext {
  ScanContext({
    required this.device,
    required this.items,
    required this.rules,
    required this.now,
    required this.issues,
    void Function(ScanProgress)? onProgress,
    ScanCancelToken? cancelToken,
  })  : _onProgress = onProgress,
        _cancelToken = cancelToken;

  final DeviceAdapter device;

  /// Every item found in storage, listed once up front.
  final List<StorageItem> items;
  final ScanRules rules;

  /// "Now" for age-based rules. Fixed per scan so results are consistent.
  final DateTime now;

  /// Non-fatal problems; detectors add to this.
  final List<ScanIssue> issues;

  final void Function(ScanProgress)? _onProgress;
  final ScanCancelToken? _cancelToken;
  final _imageCache = <String, Future<ImageAnalysis>>{};

  StorageSource get source => device.storage;

  /// Reports detector progress and stops the scan if it was cancelled.
  /// Detectors call this inside their loops.
  void tick(WasteCategory category, int done, int total) {
    throwIfCancelled();
    _onProgress?.call(ScanProgress(ScanPhase.detecting,
        category: category, done: done, total: total));
  }

  void throwIfCancelled() {
    if (_cancelToken?.isCancelled ?? false) {
      throw const ScanCancelledException();
    }
  }

  /// Decodes and measures an image. Memoised, so the several detectors that
  /// look at photos only decode each one once.
  Future<ImageAnalysis> analyzeImage(StorageItem item) =>
      _imageCache[item.id] ??= _analyze(item);

  /// Analyses [photos] several at a time (see [ScanRules.imageConcurrency]),
  /// reporting progress under [category]. Detectors call this before looping
  /// so decoding runs in parallel.
  Future<void> analyzeImages(
      WasteCategory category, List<StorageItem> photos) async {
    var next = 0;
    var done = 0;
    Future<void> worker() async {
      while (next < photos.length) {
        final item = photos[next++];
        await analyzeImage(item);
        tick(category, ++done, photos.length);
      }
    }

    final workers = rules.imageConcurrency < photos.length
        ? rules.imageConcurrency
        : photos.length;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  }

  Future<ImageAnalysis> _analyze(StorageItem item) async {
    if (!item.isPhoto) return const SkippedImage('not a photo format');
    if (item.sizeBytes == 0) return const SkippedImage('empty file');
    if (item.sizeBytes > rules.maxPhotoBytes) {
      return const SkippedImage('too large to analyse');
    }
    if (!source.canDecodeThumbnail(item)) {
      return const SkippedImage('format not supported on this device');
    }
    try {
      final thumb = await source.loadThumbnail(item, rules.thumbnailSize);
      if (thumb == null) return const UndecodableImage();
      if (thumb.sourceWidth < rules.minPhotoDimension ||
          thumb.sourceHeight < rules.minPhotoDimension) {
        return const SkippedImage('too small to be a photo');
      }
      return AnalyzedImage(ImageFeatures.fromThumbnail(thumb));
    } on StorageReadException catch (e) {
      // Can't open it at all; the unreadable-file detector reports that.
      return SkippedImage(e.message);
    }
  }
}
