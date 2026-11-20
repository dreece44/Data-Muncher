import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Synthetic video files for the large & old video tests: real container
/// structure (MP4/MOV boxes with sample tables, Matroska elements, AVI
/// chunks) around noise in place of picture data. Players can't show them,
/// but every field the scan reads (duration, size, frame rate, codec,
/// creation time, index offsets) is real, and the empty & unreadable checks
/// accept the healthy ones.

/// [length] bytes of fast pseudo-random noise: tens of MB in milliseconds.
Uint8List noise(int length, [int seed = 1]) {
  final words = Uint32List((length + 3) ~/ 4);
  var x = 0x9E3779B9 ^ (seed * 0x85EBCA6B) & 0xFFFFFFFF;
  if (x == 0) x = 1;
  for (var i = 0; i < words.length; i++) {
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    words[i] = x;
  }
  return Uint8List.sublistView(words.buffer.asUint8List(), 0, length);
}

// --- MP4 / MOV --------------------------------------------------------------

/// An MP4 (or QuickTime, [quickTime]) file of exactly [bytes] bytes (before
/// [keep] truncates it): `ftyp`, `moov` with a video track (and an audio
/// track unless [audio] is false), and `mdat`.
///
/// - [created]: the creation time in `mvhd`; null writes 0 (unset).
/// - [indexFirst]: `moov` before `mdat` ("fast start"), as cameras and
///   phones write it; otherwise after, as most recorders do.
/// - [noSamples]: tracks with empty sample tables (V01).
/// - [sttsExtra]: the time table lists this many more samples than the size
///   table (V03).
/// - [mdatToEnd]: `mdat` size field 0, "to the end of the file", as
///   recorders that can't seek back write it. With [keep] this makes a
///   cut-off copy the box walk can't see (V02).
/// - [index]: false leaves `moov` out entirely: a recording interrupted
///   before its index was written.
Uint8List mp4Video({
  required int bytes,
  required Duration duration,
  int width = 1920,
  int height = 1080,
  double fps = 30,
  String codec = 'avc1',
  DateTime? created,
  bool quickTime = false,
  bool indexFirst = false,
  bool audio = true,
  bool noSamples = false,
  int sttsExtra = 0,
  bool mdatToEnd = false,
  bool index = true,
  int? keep,
  int seed = 1,
}) {
  final secs = duration.inMicroseconds / 1e6;
  final videoSamples = noSamples ? 0 : math.max(1, (fps * secs).round());
  final audioSamples = noSamples || !audio ? 0 : math.max(1, secs.round());
  final ftyp = _box(
      'ftyp',
      quickTime
          ? [...ascii.encode('qt  '), 0, 0, 2, 0, ...ascii.encode('qt  ')]
          : [
              ...ascii.encode('isom'),
              0,
              0,
              2,
              0,
              ...ascii.encode('isomiso2avc1mp41')
            ]);
  final creation = created == null
      ? 0
      : created.toUtc().difference(DateTime.utc(1904)).inSeconds;

  Uint8List moovFor(List<int> vSizes, List<int> aSizes, int dataStart) {
    final vOffsets = <int>[], aOffsets = <int>[];
    var o = dataStart;
    for (var i = 0; i < vSizes.length; i += 30) {
      vOffsets.add(o);
      for (var j = i; j < math.min(i + 30, vSizes.length); j++) {
        o += vSizes[j];
      }
    }
    for (var i = 0; i < aSizes.length; i += 10) {
      aOffsets.add(o);
      for (var j = i; j < math.min(i + 10, aSizes.length); j++) {
        o += aSizes[j];
      }
    }
    final ms = (secs * 1000).round();
    final vDelta = (90000 / fps).round();
    return _box('moov', [
      ..._box('mvhd', [
        ..._u32(0), ..._u32(creation), ..._u32(creation), ..._u32(1000), //
        ..._u32(ms), ..._u32(0x00010000), 1, 0, ...List.filled(10, 0),
        ..._matrix, ...List.filled(24, 0), ..._u32(audio ? 3 : 2),
      ]),
      ..._trak(
          id: 1,
          handler: 'vide',
          timescale: 90000,
          delta: vDelta,
          sizes: vSizes,
          sttsCount: vSizes.length + sttsExtra,
          perChunk: 30,
          offsets: vOffsets,
          ms: ms,
          entry: _visualEntry(codec, width, height),
          width: width,
          height: height),
      if (audio)
        ..._trak(
            id: 2,
            handler: 'soun',
            timescale: 1000,
            delta: 1000,
            sizes: aSizes,
            sttsCount: aSizes.length,
            perChunk: 10,
            offsets: aOffsets,
            ms: ms,
            entry: _box('mp4a', [
              ...List.filled(6, 0), 0, 1, ...List.filled(8, 0), 0, 2, 0, 16, //
              0, 0, 0, 0, ..._u32(44100 << 16),
            ])),
    ]);
  }

  List<int> split(int total, int n) {
    if (n == 0) return const [];
    final each = total ~/ n;
    return [
      for (var i = 0; i < n; i++) i == n - 1 ? total - each * (n - 1) : each
    ];
  }

  // The index's size depends only on the sample counts, so build it once
  // with placeholder sizes to learn how much room the data gets.
  final placeholder =
      moovFor(List.filled(videoSamples, 0), List.filled(audioSamples, 0), 0);
  final mdatHeader = 8;
  final payload =
      bytes - ftyp.length - mdatHeader - (index ? placeholder.length : 0);
  if (payload < videoSamples + audioSamples) {
    throw ArgumentError('$bytes bytes is too small for $videoSamples frames');
  }
  final audioShare = audioSamples == 0 ? 0 : payload ~/ 20;
  final vSizes = split(payload - audioShare, videoSamples);
  final aSizes = split(audioShare, audioSamples);
  final dataStart =
      ftyp.length + (indexFirst && index ? placeholder.length : 0) + mdatHeader;
  final moov = index ? moovFor(vSizes, aSizes, dataStart) : Uint8List(0);
  final mdat = BytesBuilder(copy: false)
    ..add(_u32(mdatToEnd ? 0 : mdatHeader + payload))
    ..add(ascii.encode('mdat'))
    ..add(noise(payload, seed));
  final out = BytesBuilder(copy: false)..add(ftyp);
  if (indexFirst) {
    out
      ..add(moov)
      ..add(mdat.takeBytes());
  } else {
    out
      ..add(mdat.takeBytes())
      ..add(moov);
  }
  final file = out.takeBytes();
  return keep == null ? file : Uint8List.sublistView(file, 0, keep);
}

const _matrix = [
  0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0,
];

List<int> _visualEntry(String codec, int width, int height) => _box(codec, [
      ...List.filled(6, 0), 0, 1, ...List.filled(16, 0), //
      ..._u16(width), ..._u16(height), 0, 0x48, 0, 0, 0, 0x48, 0, 0,
      ...List.filled(4, 0), 0, 1, ...List.filled(32, 0), 0, 0x18, 0xFF, 0xFF,
    ]);

List<int> _trak({
  required int id,
  required String handler,
  required int timescale,
  required int delta,
  required List<int> sizes,
  required int sttsCount,
  required int perChunk,
  required List<int> offsets,
  required int ms,
  required List<int> entry,
  int width = 0,
  int height = 0,
}) =>
    _box('trak', [
      ..._box('tkhd', [
        0, 0, 0, 3, ..._u32(0), ..._u32(0), ..._u32(id), ..._u32(0), //
        ..._u32(ms), ...List.filled(8, 0), 0, 0, 0, 0,
        if (handler == 'soun') ...[1, 0] else ...[0, 0], 0, 0,
        ..._matrix, ..._u32(width << 16), ..._u32(height << 16),
      ]),
      ..._box('mdia', [
        ..._box('mdhd', [
          ..._u32(0), ..._u32(0), ..._u32(0), ..._u32(timescale), //
          ..._u32(sizes.length * delta), 0x55, 0xC4, 0, 0,
        ]),
        ..._box('hdlr', [
          ..._u32(0), ..._u32(0), ...ascii.encode(handler), //
          ...List.filled(12, 0), ...ascii.encode('${handler}Handler'), 0,
        ]),
        ..._box('minf', [
          ..._box('stbl', [
            ..._box('stsd', [..._u32(0), ..._u32(1), ...entry]),
            ..._box('stts', [
              ..._u32(0), ..._u32(sttsCount == 0 ? 0 : 1), //
              if (sttsCount > 0) ...[..._u32(sttsCount), ..._u32(delta)],
            ]),
            ..._box('stsc', [
              ..._u32(0), ..._u32(sizes.isEmpty ? 0 : 1), //
              if (sizes.isNotEmpty) ...[
                ..._u32(1),
                ..._u32(perChunk),
                ..._u32(1)
              ],
            ]),
            ..._box('stsz', [
              ..._u32(0), ..._u32(0), ..._u32(sizes.length), //
              for (final s in sizes) ..._u32(s),
            ]),
            ..._box('stco', [
              ..._u32(0), ..._u32(offsets.length), //
              for (final o in offsets) ..._u32(o),
            ]),
          ]),
        ]),
      ]),
    ]);

/// A HEIF still (`ftyp heic`, `meta`, `mdat`): the photo half of a Live
/// Photo. Well-formed boxes; the picture data is noise.
Uint8List heifStill({int bytes = 2400, int seed = 7}) => Uint8List.fromList([
      ..._box('ftyp',
          [...ascii.encode('heic'), 0, 0, 0, 0, ...ascii.encode('mif1heic')]),
      ..._box('meta', [0, 0, 0, 0, ...List.filled(56, 0)]),
      ..._box('mdat', noise(bytes - 24 - 68 - 8, seed)),
    ]);

Uint8List _box(String type, List<int> payload) {
  final out = Uint8List(8 + payload.length);
  out.setRange(0, 4, _u32(8 + payload.length));
  out.setRange(4, 8, ascii.encode(type));
  out.setRange(8, out.length, payload);
  return out;
}

List<int> _u32(int v) =>
    [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];
List<int> _u16(int v) => [v >> 8 & 0xFF, v & 0xFF];

// --- Matroska / WebM --------------------------------------------------------

/// A Matroska (or WebM, [webm]) file of exactly [bytes] bytes (before [keep]
/// truncates it): EBML header, then a Segment with Info, Tracks and
/// Clusters of noise.
///
/// - [finalized]: false leaves the Segment size "unknown" and Info without
///   a Duration, as a recorder that was stopped before finishing does.
/// - [clusters]: false writes the headers only (V01).
/// - [fourcc]: write the codec as Video-for-Windows with this code in
///   CodecPrivate (lossless capture codecs), instead of [codecId].
Uint8List mkvVideo({
  required int bytes,
  required Duration duration,
  int width = 1920,
  int height = 1080,
  double fps = 60,
  String codecId = 'V_MPEG4/ISO/AVC',
  String? fourcc,
  DateTime? created,
  String writingApp = 'OBS Studio (30.2.3)',
  String muxingApp = 'libobs 30.2.3',
  bool webm = false,
  bool finalized = true,
  bool clusters = true,
  int? keep,
  int seed = 1,
}) {
  final header = _el(0x1A45DFA3, [
    ..._el(0x4286, _uint(1)), ..._el(0x42F7, _uint(1)), //
    ..._el(0x42F2, _uint(4)), ..._el(0x42F3, _uint(8)),
    ..._el(0x4282, ascii.encode(webm ? 'webm' : 'matroska')),
    ..._el(0x4287, _uint(4)), ..._el(0x4285, _uint(2)),
  ]);
  final info = _el(0x1549A966, [
    ..._el(0x2AD7B1, _uint(1000000)),
    if (finalized)
      ..._el(
          0x4489,
          (ByteData(8)..setFloat64(0, duration.inMicroseconds / 1000))
              .buffer
              .asUint8List()),
    if (created != null)
      ..._el(
          0x4461,
          (ByteData(8)
                ..setInt64(
                    0,
                    created
                            .toUtc()
                            .difference(DateTime.utc(2001))
                            .inMicroseconds *
                        1000))
              .buffer
              .asUint8List()),
    ..._el(0x4D80, utf8.encode(muxingApp)),
    ..._el(0x5741, utf8.encode(writingApp)),
  ]);
  final tracks = _el(0x1654AE6B, [
    ..._el(0xAE, [
      ..._el(0xD7, _uint(1)), ..._el(0x83, _uint(1)), //
      ..._el(0x86, ascii.encode(fourcc == null ? codecId : 'V_MS/VFW/FOURCC')),
      if (fourcc != null)
        ..._el(0x63A2, [
          40, 0, 0, 0, ..._le32(width), ..._le32(height), 1, 0, 24, 0, //
          ...ascii.encode(fourcc), ...List.filled(20, 0),
        ]),
      ..._el(0x23E383, _uint((1e9 / fps).round())),
      ..._el(0xE0, [..._el(0xB0, _uint(width)), ..._el(0xBA, _uint(height))]),
    ]),
    ..._el(0xAE, [
      ..._el(0xD7, _uint(2)), ..._el(0x83, _uint(2)), //
      ..._el(0x86, ascii.encode(webm ? 'A_OPUS' : 'A_AAC')),
    ]),
  ]);

  final body = BytesBuilder(copy: false)
    ..add(info)
    ..add(tracks);
  if (clusters) {
    // Each cluster: ID (4) + size (8) + Timecode (1 + 8 + 3) + SimpleBlock
    // header (1 + 8 + 4) around its share of the noise.
    const overhead = 4 + 8 + 12 + 13;
    final room = bytes - header.length - 12 - body.length;
    final count = math.max(1, math.min(400, room ~/ (16 * 1024)));
    final data = noise(room - count * overhead, seed);
    var at = 0;
    for (var i = 0; i < count; i++) {
      final n =
          i == count - 1 ? data.length - at : (data.length - at) ~/ (count - i);
      final timecode =
          _uint((duration.inMilliseconds * i / count).round(), width: 3);
      body.add(_el(0x1F43B675, [
        ..._el(0xE7, timecode),
        ..._el(0xA3,
            [0x81, 0, 0, 0x80, ...Uint8List.sublistView(data, at, at + n)]),
      ]));
      at += n;
    }
  }
  final payload = body.takeBytes();
  final file = BytesBuilder(copy: false)
    ..add(header)
    ..add(_idBytes(0x18538067))
    ..add(finalized
        ? _size(payload.length)
        : const [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    ..add(payload);
  final out = file.takeBytes();
  return keep == null ? out : Uint8List.sublistView(out, 0, keep);
}

List<int> _el(int id, List<int> data) =>
    [..._idBytes(id), ..._size(data.length), ...data];

List<int> _idBytes(int id) {
  final out = <int>[];
  for (var v = id; v > 0; v >>= 8) {
    out.insert(0, v & 0xFF);
  }
  return out;
}

/// An 8-byte EBML size: always fits, and keeps cluster overhead fixed.
List<int> _size(int n) =>
    [0x01, for (var i = 6; i >= 0; i--) n >> (8 * i) & 0xFF];

List<int> _uint(int v, {int? width}) {
  final out = <int>[];
  for (var x = v; x > 0; x >>= 8) {
    out.insert(0, x & 0xFF);
  }
  while (out.length < (width ?? 1)) {
    out.insert(0, 0);
  }
  return out;
}

List<int> _le32(int v) =>
    [v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF];

// --- AVI --------------------------------------------------------------------

/// An AVI file of about [bytes] bytes: `hdrl` (avih, one video stream with
/// codec [fourcc]), `movi` with [frames] frames of noise, and `idx1`.
/// [emptyMovi] writes no frames and a frame count of 0 (V01).
Uint8List aviVideo({
  required int bytes,
  required int frames,
  required double fps,
  int width = 1280,
  int height = 720,
  String fourcc = 'FPS1',
  bool emptyMovi = false,
  int seed = 1,
}) {
  final count = emptyMovi ? 0 : frames;
  final usPerFrame = (1e6 / fps).round();
  final strl = _list('strl', [
    ..._chunk('strh', [
      ...ascii.encode('vids'), ...ascii.encode(fourcc), //
      ...List.filled(12, 0), ..._le32(1000), ..._le32((fps * 1000).round()),
      ..._le32(0), ..._le32(count), ..._le32(0), ..._le32(0xFFFFFFFF),
      ..._le32(0), ...List.filled(8, 0),
    ]),
    ..._chunk('strf', [
      ..._le32(40), ..._le32(width), ..._le32(height), 1, 0, 24, 0, //
      ...ascii.encode(fourcc), ..._le32(width * height * 3),
      ...List.filled(16, 0),
    ]),
  ]);
  final hdrl = _list('hdrl', [
    ..._chunk('avih', [
      ..._le32(usPerFrame), ..._le32(0), ..._le32(0), ..._le32(0x10), //
      ..._le32(count), ..._le32(0), ..._le32(1), ..._le32(0),
      ..._le32(width), ..._le32(height), ...List.filled(16, 0),
    ]),
    ...strl,
  ]);
  final indexBytes = 8 + count * 16;
  final room = bytes - 12 - hdrl.length - 12 - indexBytes;
  final each = count == 0 ? 0 : (room ~/ count - 8) & ~1;
  final data = noise(math.max(0, each), seed);
  final movi = BytesBuilder(copy: false)..add(ascii.encode('movi'));
  final idx = BytesBuilder(copy: false);
  var offset = 4;
  for (var i = 0; i < count; i++) {
    movi
      ..add(ascii.encode('00dc'))
      ..add(_le32(each))
      ..add(data);
    idx
      ..add(ascii.encode('00dc'))
      ..add(_le32(0x10))
      ..add(_le32(offset))
      ..add(_le32(each));
    offset += 8 + each;
  }
  final moviBytes = movi.takeBytes();
  final body = BytesBuilder(copy: false)
    ..add(ascii.encode('AVI '))
    ..add(hdrl)
    ..add(ascii.encode('LIST'))
    ..add(_le32(moviBytes.length))
    ..add(moviBytes)
    ..add(_chunk('idx1', idx.takeBytes()));
  final riff = body.takeBytes();
  return (BytesBuilder(copy: false)
        ..add(ascii.encode('RIFF'))
        ..add(_le32(riff.length))
        ..add(riff))
      .takeBytes();
}

List<int> _chunk(String id, List<int> data) => [
      ...ascii.encode(id), ..._le32(data.length), ...data, //
      if (data.length.isOdd) 0,
    ];

List<int> _list(String type, List<int> data) =>
    _chunk('LIST', [...ascii.encode(type), ...data]);

// --- Other containers -------------------------------------------------------

/// An MPEG transport stream (`.mts` from a camcorder): 188-byte packets
/// starting with the 0x47 sync byte. Not opened by the scan.
Uint8List mpegTs(int bytes, {int seed = 1}) {
  final out = noise(bytes, seed);
  for (var i = 0; i < out.length; i += 188) {
    out[i] = 0x47;
  }
  return out;
}

/// A Windows Media (ASF) file: its header GUID, then noise. Not opened by
/// the scan.
Uint8List asfVideo(int bytes, {int seed = 1}) {
  final out = noise(bytes, seed);
  out.setAll(0, const [
    0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, //
    0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
  ]);
  return out;
}
