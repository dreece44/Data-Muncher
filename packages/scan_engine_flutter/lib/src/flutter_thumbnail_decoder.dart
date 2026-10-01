import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:scan_engine/scan_engine.dart';

/// Decodes images with the phone's native decoder through Flutter's engine.
/// Much faster than pure Dart, because it scales down while decoding, and on
/// Android 9+ it also reads HEIC photos from iPhones.
final class FlutterThumbnailDecoder implements ThumbnailDecoder {
  const FlutterThumbnailDecoder({this.heicSupported = true});

  /// Android only gained HEIC decoding in Android 9 (API 28).
  final bool heicSupported;

  static const _formats = {'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'};

  @override
  bool supportsExtension(String extension) =>
      _formats.contains(extension) ||
      (heicSupported && (extension == 'heic' || extension == 'heif'));

  @override
  Future<Thumbnail?> decode(Uint8List bytes, int size) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      // Stretch to an exact square, like the other decoders, so hashes from
      // every platform are comparable.
      codec = await descriptor.instantiateCodec(
        targetWidth: size,
        targetHeight: size,
      );
      image = (await codec.getNextFrame()).image;
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) return null;
      return Thumbnail(
        size: size,
        luma: lumaFromRgba(rgba.buffer.asUint8List(), size * size),
        sourceWidth: descriptor.width,
        sourceHeight: descriptor.height,
      );
    } catch (_) {
      return null; // Not decodable: corrupt or not really an image.
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
