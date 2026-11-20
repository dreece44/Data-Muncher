import 'dart:typed_data';

/// A small square greyscale copy of an image. The image detectors work on
/// these instead of full photos so every platform analyses images the same
/// way, and a 12-megapixel photo costs a few KB of memory.
final class Thumbnail {
  Thumbnail({
    required this.size,
    required this.luma,
    required this.sourceWidth,
    required this.sourceHeight,
  }) : assert(luma.length == size * size);

  /// Width and height in pixels. The source aspect ratio is not kept.
  final int size;

  /// Brightness 0–255, row by row.
  final Uint8List luma;

  /// Dimensions of the original image.
  final int sourceWidth;
  final int sourceHeight;
}

/// Turns encoded image bytes (JPEG, PNG, …) into a [Thumbnail].
abstract interface class ThumbnailDecoder {
  /// Whether this decoder understands files with this extension.
  bool supportsExtension(String extension);

  /// A `size`×`size` thumbnail, or null if the bytes aren't a decodable image.
  Future<Thumbnail?> decode(Uint8List bytes, int size);
}

/// Converts RGBA pixels to brightness (ITU-R BT.601 weights). Shared by the
/// platform decoders so they all measure brightness identically.
Uint8List lumaFromRgba(Uint8List rgba, int pixelCount) {
  final luma = Uint8List(pixelCount);
  for (var i = 0; i < pixelCount; i++) {
    final o = i * 4;
    luma[i] = (0.299 * rgba[o] + 0.587 * rgba[o + 1] + 0.114 * rgba[o + 2])
        .round()
        .clamp(0, 255);
  }
  return luma;
}
