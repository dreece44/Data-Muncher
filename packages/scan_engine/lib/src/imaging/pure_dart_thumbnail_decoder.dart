import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'thumbnail.dart';

/// Decodes images with the pure-Dart `image` package. Works anywhere Dart
/// runs, so it's what the engine uses on a development computer. On phones
/// the Flutter adapter swaps in the platform's much faster native decoder
/// (which also handles HEIC).
final class PureDartThumbnailDecoder implements ThumbnailDecoder {
  const PureDartThumbnailDecoder({this.useIsolates = true});

  /// Decode on a background isolate so several images decode in parallel
  /// and a slow decode doesn't block the event loop.
  final bool useIsolates;

  static const _supported = {
    'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'tif', 'tiff', //
  };

  @override
  bool supportsExtension(String extension) => _supported.contains(extension);

  @override
  Future<Thumbnail?> decode(Uint8List bytes, int size) => useIsolates
      ? Isolate.run(() => decodeSync(bytes, size))
      : Future.value(decodeSync(bytes, size));

  static Thumbnail? decodeSync(Uint8List bytes, int size) {
    final img.Image? image;
    try {
      image = img.decodeImage(bytes);
    } catch (_) {
      // Corrupt data makes the decoders throw all sorts of errors.
      return null;
    }
    if (image == null) return null;

    final small = img.copyResize(image,
        width: size, height: size, interpolation: img.Interpolation.average);
    final luma = Uint8List(size * size);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final p = small.getPixel(x, y);
        luma[y * size + x] = (255 *
                (0.299 * p.rNormalized +
                    0.587 * p.gNormalized +
                    0.114 * p.bNormalized))
            .round()
            .clamp(0, 255);
      }
    }
    return Thumbnail(
      size: size,
      luma: luma,
      sourceWidth: image.width,
      sourceHeight: image.height,
    );
  }
}
