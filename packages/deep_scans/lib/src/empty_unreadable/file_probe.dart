import 'dart:math' as math;
import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart';

/// Counts what the deep scan reads, for the performance pass.
final class ReadStats {
  int bytesRead = 0;
  int reads = 0;

  void add(int bytes) {
    bytesRead += bytes;
    reads++;
  }
}

/// Thrown when a source returns fewer bytes than the file's listed size says
/// it has (U02).
final class ShortReadException implements Exception {
  const ShortReadException(this.expected, this.got, this.offset);
  final int expected;
  final int got;
  final int offset;
}

/// Reads one file for the checks, caching what it has read so the head,
/// tail and whole-file views are each fetched at most once. Small files are
/// read in one go and every view is served from that.
final class FileProbe {
  FileProbe(this.source, this.item, this.stats,
      {required this.headBytes,
      required this.tailBytes,
      required this.fullReadMaxBytes});

  final StorageSource source;
  final StorageItem item;
  final ReadStats stats;
  final int headBytes;
  final int tailBytes;
  final int fullReadMaxBytes;

  Uint8List? _head;
  Uint8List? _tail;
  Uint8List? _all;

  int get size => item.sizeBytes;

  /// Whether the whole file fits in a single head read.
  bool get _small => size <= math.max(headBytes, tailBytes);

  /// Bytes [start, end), throwing [ShortReadException] if fewer come back
  /// than the listed size promises.
  Future<Uint8List> range(int start, int end) async {
    final from = start.clamp(0, size);
    final to = end.clamp(from, size);
    final all = _all;
    if (all != null) return Uint8List.sublistView(all, from, to);
    final bytes = await source.readRange(item, from, to);
    stats.add(bytes.length);
    if (bytes.length < to - from) {
      throw ShortReadException(to - from, bytes.length, from);
    }
    return bytes;
  }

  /// The first [headBytes] bytes (fewer if the file is shorter).
  Future<Uint8List> head() async {
    if (_head != null) return _head!;
    if (_small) {
      final whole = (await all())!;
      return _head =
          Uint8List.sublistView(whole, 0, math.min(headBytes, whole.length));
    }
    return _head = await range(0, headBytes);
  }

  /// The last [length] bytes (at most [tailBytes]).
  Future<Uint8List> tail([int? length]) async {
    final want = math.min(length ?? tailBytes, tailBytes);
    if (_small) {
      final whole = (await all())!;
      return Uint8List.sublistView(whole, math.max(0, whole.length - want));
    }
    _tail ??= await range(size - tailBytes, size);
    return Uint8List.sublistView(_tail!, _tail!.length - want);
  }

  /// The whole file, or null if it's larger than [fullReadMaxBytes].
  Future<Uint8List?> all() async {
    if (_all != null) return _all;
    if (size > fullReadMaxBytes && !_small) return null;
    return _all = await range(0, size);
  }

  /// [length] bytes from the middle of the file.
  Future<Uint8List> middle(int length) {
    final start = math.max(0, size ~/ 2 - length ~/ 2);
    return range(start, start + length);
  }

  /// Bytes from [offset], up to [length], clamped to the file.
  Future<Uint8List> at(int offset, int length) =>
      range(offset, offset + length);
}
