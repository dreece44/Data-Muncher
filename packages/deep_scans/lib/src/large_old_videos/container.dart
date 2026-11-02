import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:scan_engine/scan_engine.dart';

import '../empty_unreadable/bytes.dart';
import 'rules.dart';

/// A problem in a video's container: what V01–V04 report.
final class VideoProblem {
  const VideoProblem(this.rule, this.reason, this.evidence);

  final VideoRule rule;

  /// Shown to the user.
  final String reason;

  /// What the parser saw.
  final String evidence;
}

/// What a video's container says about it. Filled in by [readVideoInfo];
/// any field can be missing.
final class VideoInfo {
  VideoInfo(this.container);

  /// `MP4`, `QuickTime`, `Matroska`, `WebM` or `AVI`.
  final String container;
  Duration? duration;
  int? width;
  int? height;
  double? frameRate;

  /// Video frames (samples) the index lists.
  int? frames;

  /// Video codec: a four-character code (`avc1`, `apcn`) or a Matroska
  /// codec id (`v_mpeg4/iso/avc`), lower case.
  String? codec;
  bool hasVideo = false;
  bool hasAudio = false;

  /// When the container says it was made. Not checked for sense; the
  /// analyzer decides whether to trust it.
  DateTime? created;

  /// The app that wrote it (Matroska's WritingApp / MuxingApp).
  String? writingApp;

  /// The first problem found, by V01 → V02 → V03 → V04.
  VideoProblem? problem;

  /// MP4/MOV index larger than `maxIndexBytes`: not read (X06).
  bool indexSkipped = false;

  /// MP4 split into fragments (no single index).
  bool fragmented = false;

  bool get hasPicture =>
      width != null && height != null && width! > 0 && height! > 0;

  Map<String, Object?> toJson() => {
        'container': container,
        if (duration != null)
          'durationSeconds': duration!.inMilliseconds / 1000,
        if (hasPicture) 'width': width,
        if (hasPicture) 'height': height,
        if (frameRate != null)
          'frameRate': double.parse(frameRate!.toStringAsFixed(3)),
        if (frames != null) 'frames': frames,
        if (codec != null) 'codec': codec,
        'hasVideo': hasVideo,
        'hasAudio': hasAudio,
        if (created != null) 'created': created!.toIso8601String(),
        if (writingApp != null) 'writingApp': writingApp,
        if (indexSkipped) 'indexSkipped': true,
        if (fragmented) 'fragmented': true,
        if (problem != null) 'problem': problem!.evidence,
      };

  /// One line for `--evidence`.
  String get evidence => [
        container,
        if (hasPicture) '$width×$height',
        if (frameRate != null) '${frameRate!.toStringAsFixed(2)} fps',
        if (duration != null) formatDuration(duration!),
        if (codec != null) codec!,
        if (frames != null) '$frames frames',
        if (!hasAudio) 'no sound',
        if (created != null) 'created ${created!.toIso8601String()}',
        if (writingApp != null) 'by $writingApp',
      ].join(', ');
}

/// Reads the container of [item] and returns what it says, or null if it
/// isn't MP4/MOV/3GP, Matroska/WebM or AVI. [onRead] is told how many bytes
/// each read returned. Throws [StorageReadException] if the file can't be
/// read.
Future<VideoInfo?> readVideoInfo(StorageSource source, StorageItem item,
    LargeOldVideoRules rules, void Function(int bytes) onRead) async {
  final r = _Reader(source, item, onRead);
  final head = await r.read(0, rules.headBytes);
  if (head.length < 12) return null;
  if (asciiAt(head, 4, 'ftyp')) {
    final brand = String.fromCharCodes(head, 8, 12);
    return _iso(r, rules, brand == 'qt  ' ? 'QuickTime' : 'MP4');
  }
  if (const ['moov', 'mdat', 'wide', 'free', 'skip']
      .any((t) => asciiAt(head, 4, t))) {
    return _iso(r, rules, 'QuickTime');
  }
  if (bytesAt(head, 0, const [0x1A, 0x45, 0xDF, 0xA3])) {
    return _matroska(r, head, rules);
  }
  if (asciiAt(head, 0, 'RIFF') && asciiAt(head, 8, 'AVI ')) {
    return _avi(r, head, rules);
  }
  return null;
}

final class _Reader {
  _Reader(this.source, this.item, this.onRead);

  final StorageSource source;
  final StorageItem item;
  final void Function(int) onRead;

  int get size => item.sizeBytes;

  Future<Uint8List> read(int start, int length) async {
    final bytes = await source.readRange(item, start, start + length);
    onRead(bytes.length);
    return bytes;
  }
}

/// Thrown inside a parsed buffer whose structure doesn't add up.
final class _Damaged implements Exception {
  const _Damaged(this.detail);
  final String detail;
}

String _missing(int have, int need) {
  final share = need <= 0 ? 0.0 : (need - have) / need;
  return share >= 0.995 ? 'almost all' : '${(share * 100).round()}%';
}

VideoProblem _cutOff(String evidence, int have, int need, String why) =>
    VideoProblem(
        VideoRule.v02CutOff,
        'Video is cut off: ${_missing(have, need)} of it is missing '
        '($why)',
        evidence);

const _noFrames = 'Video contains no frames: the recording stopped before '
    'anything was saved';

// --- MP4 / MOV / 3GP (ISO base media) --------------------------------------

final class _Track {
  String handler = '?';
  int timescale = 0;
  int duration = 0;
  int sttsSamples = 0;
  int? stszSamples;
  int sampleBytes = 0;
  int chunks = 0;
  int maxChunkOffset = -1;
  bool hasChunkTable = false;
  String? codec;
  int width = 0;
  int height = 0;

  int get samples => stszSamples ?? sttsSamples;
  double? get seconds =>
      timescale > 0 && duration > 0 ? duration / timescale : null;
}

Future<VideoInfo> _iso(_Reader r, LargeOldVideoRules rules, String name) async {
  final info = VideoInfo(name);
  var pos = 0;
  int? moovStart, moovEnd;
  var payload = 0;
  (String, int, int)? cut;
  for (var n = 0; pos + 8 <= r.size && n < rules.maxElements; n++) {
    final h = await r.read(pos, 16);
    var size = u32be(h, 0);
    final type = String.fromCharCodes(h, 4, 8);
    var header = 8;
    if (size == 1) {
      if (h.length < 16) break;
      size = u32be(h, 8) * 0x100000000 + u32be(h, 12);
      header = 16;
    } else if (size == 0) {
      size = r.size - pos; // "Runs to the end of the file."
    }
    if (size < header) {
      info.problem = VideoProblem(
          VideoRule.v03Damaged,
          'Video file structure is damaged',
          'box "$type" at $pos has size $size');
      return info;
    }
    final end = pos + size;
    if (type == 'moov') {
      moovStart = pos + header;
      moovEnd = end;
    }
    if (type == 'moof') info.fragmented = true;
    if (type == 'mdat') payload += math.min(end, r.size) - pos - header;
    if (end > r.size) {
      cut = (type, pos, size);
      break;
    }
    pos = end;
  }

  if (cut != null && (cut.$1 != 'mdat' || moovStart == null)) {
    final (type, at, size) = cut;
    info.problem = _cutOff(
        'box "$type" at $at needs $size bytes, ${r.size - at} remain',
        r.size,
        at + size,
        'a copy, download or recording stopped part-way');
    return info;
  }
  if (moovStart == null || moovEnd == null) {
    if (!info.fragmented) {
      info.problem = const VideoProblem(
          VideoRule.v02CutOff,
          "Video is missing its index and can't be played (the recording or "
              'copy was interrupted)',
          'no moov box');
    }
    return info;
  }
  if (moovEnd - moovStart > rules.maxIndexBytes) {
    info.indexSkipped = true;
    return info;
  }

  final moov = await r.read(moovStart, moovEnd - moovStart);
  final tracks = <_Track>[];
  var timescale = 0, duration = 0, created = 0;
  try {
    for (final (type, s, e) in _boxes(moov, 0, moov.length)) {
      if (type == 'mvhd' && e - s >= 32) {
        final v1 = moov[s] == 1;
        created = v1 ? _u64be(moov, s + 4) : u32be(moov, s + 4);
        timescale = u32be(moov, s + (v1 ? 20 : 12));
        duration = v1 ? _u64be(moov, s + 24) : u32be(moov, s + 16);
      } else if (type == 'trak') {
        tracks.add(_track(moov, s, e));
      }
    }
  } on _Damaged catch (e) {
    info.problem = VideoProblem(
        VideoRule.v03Damaged,
        "Video's index is damaged, so players stop or refuse to open it",
        e.detail);
    return info;
  }

  if (created > 0) {
    info.created = DateTime.utc(1904).add(Duration(seconds: created));
  }
  final video = tracks.where((t) => t.handler == 'vide').firstOrNull;
  info.hasVideo = video != null && video.samples > 0;
  info.hasAudio = tracks.any((t) => t.handler == 'soun' && t.samples > 0);
  if (timescale > 0 && duration > 0) {
    info.duration =
        Duration(microseconds: (duration * 1e6 / timescale).round());
  } else if (video?.seconds != null) {
    info.duration = Duration(microseconds: (video!.seconds! * 1e6).round());
  }
  if (video != null) {
    info
      ..codec = video.codec?.toLowerCase()
      ..width = video.width
      ..height = video.height
      ..frames = video.samples;
    final secs = video.seconds;
    if (secs != null && video.samples > 0) {
      info.frameRate = video.samples / secs;
    }
  }

  // V01: nothing to play.
  if (tracks.every((t) => t.samples == 0)) {
    info.problem = VideoProblem(VideoRule.v01Empty, _noFrames,
        '${tracks.length} track${tracks.length == 1 ? '' : 's'}, 0 samples');
    return info;
  }
  // V02: the index points past the data.
  for (final t in tracks) {
    if (t.maxChunkOffset >= r.size) {
      info.problem = _cutOff(
          '${t.handler} chunk at ${t.maxChunkOffset}, file has ${r.size} bytes',
          payload,
          tracks.fold(0, (s, t) => s + t.sampleBytes),
          'a copy or download stopped part-way');
      return info;
    }
  }
  final sampleBytes = tracks.fold(0, (s, t) => s + t.sampleBytes);
  if (sampleBytes > payload * (1 + rules.cutOffTolerance)) {
    info.problem = _cutOff(
        'index lists $sampleBytes bytes of frames, file holds $payload',
        payload,
        sampleBytes,
        'a copy or download stopped part-way');
    return info;
  }
  // V03: tables that contradict each other.
  for (final t in tracks) {
    if (t.stszSamples != null &&
        t.sttsSamples > 0 &&
        t.stszSamples != t.sttsSamples) {
      info.problem = VideoProblem(
          VideoRule.v03Damaged,
          "Video's frame tables don't agree, so players stop or refuse to "
              'open it',
          '${t.handler} track: stsz ${t.stszSamples} samples, stts '
              '${t.sttsSamples}');
      return info;
    }
    if (t.samples > 0 && !t.hasChunkTable) {
      info.problem = VideoProblem(
          VideoRule.v03Damaged,
          "Video's index doesn't say where its frames are",
          '${t.handler} track: ${t.samples} samples, no stco/co64');
      return info;
    }
  }
  return info;
}

_Track _track(Uint8List b, int start, int end) {
  final t = _Track();
  void walk(int s, int e) {
    for (final (type, cs, ce) in _boxes(b, s, e)) {
      switch (type) {
        case 'mdia' || 'minf' || 'stbl':
          walk(cs, ce);
        case 'tkhd' when ce - cs >= 84:
          final v1 = b[cs] == 1;
          final at = cs + (v1 ? 88 : 76);
          if (at + 8 <= ce && t.width == 0) {
            t.width = u32be(b, at) >> 16;
            t.height = u32be(b, at + 4) >> 16;
          }
        case 'mdhd' when ce - cs >= 24:
          final v1 = b[cs] == 1;
          t.timescale = u32be(b, cs + (v1 ? 20 : 12));
          t.duration = v1 ? _u64be(b, cs + 24) : u32be(b, cs + 16);
        case 'hdlr' when ce - cs >= 12:
          t.handler = String.fromCharCodes(b, cs + 8, cs + 12);
        case 'stsd' when ce - cs >= 16:
          final entry = cs + 8;
          t.codec = String.fromCharCodes(b, entry + 4, entry + 8);
          if (entry + 36 <= ce) {
            final w = u16be(b, entry + 32), h = u16be(b, entry + 34);
            if (w > 0 && h > 0 && t.handler != 'soun') {
              t.width = w;
              t.height = h;
            }
          }
        case 'stts' when ce - cs >= 8:
          final n = u32be(b, cs + 4);
          if (cs + 8 + n * 8 > ce) throw _Damaged('stts lists $n entries');
          for (var i = 0; i < n; i++) {
            t.sttsSamples += u32be(b, cs + 8 + i * 8);
          }
        case 'stsz' when ce - cs >= 12:
          final fixed = u32be(b, cs + 4), n = u32be(b, cs + 8);
          t.stszSamples = n;
          if (fixed != 0) {
            t.sampleBytes = fixed * n;
          } else {
            if (cs + 12 + n * 4 > ce) {
              throw _Damaged('stsz lists $n sizes in ${ce - cs - 12} bytes');
            }
            for (var i = 0; i < n; i++) {
              t.sampleBytes += u32be(b, cs + 12 + i * 4);
            }
          }
        case 'stco' || 'co64' when ce - cs >= 8:
          final wide = type == 'co64';
          final n = u32be(b, cs + 4);
          if (cs + 8 + n * (wide ? 8 : 4) > ce) {
            throw _Damaged('$type lists $n offsets');
          }
          t
            ..hasChunkTable = true
            ..chunks = n;
          for (var i = 0; i < n; i++) {
            final o =
                wide ? _u64be(b, cs + 8 + i * 8) : u32be(b, cs + 8 + i * 4);
            if (o > t.maxChunkOffset) t.maxChunkOffset = o;
          }
      }
    }
  }

  walk(start, end);
  return t;
}

/// Child boxes of `b[start..end)`: (type, payload start, end).
Iterable<(String, int, int)> _boxes(Uint8List b, int start, int end) sync* {
  var p = start;
  while (p + 8 <= end) {
    var size = u32be(b, p);
    final type = String.fromCharCodes(b, p + 4, p + 8);
    var header = 8;
    if (size == 1) {
      if (p + 16 > end) throw _Damaged('box "$type" at $p cut short');
      size = _u64be(b, p + 8);
      header = 16;
    } else if (size == 0) {
      size = end - p;
    }
    if (size < header || p + size > end) {
      throw _Damaged('box "$type" at $p has size $size, parent ends at $end');
    }
    yield (type, p + header, p + size);
    p += size;
  }
}

int u16be(List<int> b, int o) => b[o] << 8 | b[o + 1];
int _u64be(List<int> b, int o) => u32be(b, o) * 0x100000000 + u32be(b, o + 4);

// --- Matroska / WebM --------------------------------------------------------

const _idEbml = 0x1A45DFA3,
    _idDocType = 0x4282,
    _idSegment = 0x18538067,
    _idInfo = 0x1549A966,
    _idTracks = 0x1654AE6B,
    _idCluster = 0x1F43B675,
    _idTimecodeScale = 0x2AD7B1,
    _idDuration = 0x4489,
    _idDateUtc = 0x4461,
    _idMuxingApp = 0x4D80,
    _idWritingApp = 0x5741,
    _idTrackEntry = 0xAE,
    _idTrackType = 0x83,
    _idCodecId = 0x86,
    _idCodecPrivate = 0x63A2,
    _idDefaultDuration = 0x23E383,
    _idVideo = 0xE0,
    _idPixelWidth = 0xB0,
    _idPixelHeight = 0xBA;

/// An EBML variable-length integer: its value, its length in bytes, and
/// whether it is the reserved "unknown size".
typedef _Vint = ({int value, int length, bool unknown});

_Vint? _vint(List<int> b, int o, {bool id = false}) {
  if (o >= b.length || b[o] == 0) return null;
  final first = b[o];
  var length = 1;
  while ((first & (0x80 >> (length - 1))) == 0) {
    length++;
  }
  if (o + length > b.length) return null;
  final marker = 0x80 >> (length - 1);
  var value = id ? first : first & (marker - 1);
  var allOnes = (first & (marker - 1)) == marker - 1;
  for (var i = 1; i < length; i++) {
    value = value * 256 + b[o + i];
    if (b[o + i] != 0xFF) allOnes = false;
  }
  return (value: value, length: length, unknown: !id && allOnes);
}

/// An element header: id, where its data starts, its size (-1 = unknown).
typedef _Element = ({int id, int data, int size});

_Element? _element(List<int> b, int o) {
  final id = _vint(b, o, id: true);
  if (id == null) return null;
  final size = _vint(b, o + id.length);
  if (size == null) return null;
  return (
    id: id.value,
    data: o + id.length + size.length,
    size: size.unknown ? -1 : size.value
  );
}

/// Children of `b[start..end)`: (id, data start, data end).
Iterable<(int, int, int)> _ebmlChildren(Uint8List b, int start, int end) sync* {
  var p = start;
  while (p < end) {
    final e = _element(b, p);
    if (e == null) throw _Damaged('invalid element header at $p');
    final de = e.size < 0 ? end : e.data + e.size;
    if (de > end) {
      throw _Damaged('element 0x${e.id.toRadixString(16)} at $p runs past '
          'its parent');
    }
    yield (e.id, e.data, de);
    p = de;
  }
}

int _uint(Uint8List b, int s, int e) {
  var v = 0;
  for (var i = s; i < e; i++) {
    v = v * 256 + b[i];
  }
  return v;
}

String _string(Uint8List b, int s, int e) => utf8
    .decode(b.sublist(s, e), allowMalformed: true)
    .replaceAll('\u0000', '')
    .trim();

Future<VideoInfo> _matroska(
    _Reader r, Uint8List head, LargeOldVideoRules rules) async {
  var info = VideoInfo('Matroska');
  Future<_Element?> elementAt(int pos) async {
    if (pos + 12 <= head.length) return _element(head, pos);
    final e = _element(await r.read(pos, 12), 0);
    return e == null ? null : (id: e.id, data: pos + e.data, size: e.size);
  }

  final ebml = _element(head, 0);
  if (ebml == null || ebml.id != _idEbml || ebml.size < 0) {
    info.problem = const VideoProblem(VideoRule.v03Damaged,
        'Video file structure is damaged', 'invalid EBML header');
    return info;
  }
  final ebmlEnd = ebml.data + ebml.size;
  if (ebmlEnd <= head.length) {
    try {
      for (final (id, s, e) in _ebmlChildren(head, ebml.data, ebmlEnd)) {
        if (id == _idDocType && _string(head, s, e) == 'webm') {
          info = VideoInfo('WebM');
        }
      }
    } on _Damaged {
      // The doc type is cosmetic; the segment check below decides.
    }
  }

  final seg = await elementAt(ebmlEnd);
  if (seg == null || seg.id != _idSegment) {
    info.problem = VideoProblem(
        ebmlEnd >= r.size ? VideoRule.v01Empty : VideoRule.v03Damaged,
        ebmlEnd >= r.size ? _noFrames : 'Video file structure is damaged',
        'no Segment after the EBML header at $ebmlEnd');
    return info;
  }
  final segEnd = seg.size < 0 ? null : seg.data + seg.size;
  final limit = math.min(segEnd ?? r.size, r.size);

  var clusters = 0;
  var info0 = false, tracks0 = false;
  String? cutAt, damagedAt;
  var pos = seg.data;
  for (var n = 0; pos < limit && n < rules.maxElements; n++) {
    final e = await elementAt(pos);
    if (e == null) {
      if (r.size - pos < 12 && segEnd == null) {
        cutAt = 'partial element header at $pos';
      } else {
        damagedAt = 'invalid element header at $pos';
      }
      break;
    }
    if (e.size < 0) {
      // Live-written element: its end is only known by parsing inside.
      if (e.id == _idCluster) clusters++;
      break;
    }
    final end = e.data + e.size;
    if (end > limit) {
      final what = e.id == _idCluster ? 'cluster' : 'element';
      final detail = '$what at $pos needs ${end - pos} bytes, '
          '${limit - pos} remain';
      if (segEnd == null || segEnd > r.size) {
        cutAt = detail;
      } else {
        damagedAt = '$detail in its segment';
      }
      if (e.id == _idCluster) clusters++;
      break;
    }
    if ((e.id == _idInfo || e.id == _idTracks) && e.size <= 1024 * 1024) {
      final bytes = end <= head.length
          ? Uint8List.sublistView(head, e.data, end)
          : await r.read(e.data, e.size);
      try {
        if (e.id == _idInfo) {
          _matroskaInfo(info, bytes);
          info0 = true;
        } else {
          _matroskaTracks(info, bytes);
          tracks0 = true;
        }
      } on _Damaged catch (d) {
        damagedAt = d.detail;
        break;
      }
    }
    if (e.id == _idCluster) {
      clusters++;
      // A finished file needs no more walking once the headers and the
      // first cluster are seen.
      if (segEnd != null && segEnd <= r.size && info0 && tracks0) break;
    }
    pos = end;
  }

  if (segEnd != null && segEnd > r.size) {
    info.problem = _cutOff('segment ends at $segEnd, file has ${r.size} bytes',
        r.size, segEnd, 'a copy or download stopped part-way');
  } else if (clusters == 0 && cutAt == null && damagedAt == null) {
    info.problem = VideoProblem(VideoRule.v01Empty, _noFrames,
        'no Cluster in the segment${segEnd == null ? ' (size unknown)' : ''}');
  } else if (damagedAt != null) {
    info.problem = VideoProblem(
        VideoRule.v03Damaged,
        'Video file structure is damaged; players may stop part-way',
        damagedAt);
  } else if (segEnd == null) {
    info.problem = VideoProblem(
        VideoRule.v04Interrupted,
        cutAt != null
            ? 'Recording was interrupted (often because storage ran out): '
                'it plays up to where it stopped, but the end is cut off '
                'and its length was never saved'
            : 'Recording was never finished: it plays, but its length was '
                'never saved, so seeking may not work',
        'segment size unknown${cutAt != null ? '; $cutAt' : ''}');
  }
  return info;
}

void _matroskaInfo(VideoInfo info, Uint8List b) {
  var scale = 1000000;
  double? duration;
  for (final (id, s, e) in _ebmlChildren(b, 0, b.length)) {
    switch (id) {
      case _idTimecodeScale:
        scale = _uint(b, s, e);
      case _idDuration when e - s == 4 || e - s == 8:
        final data = ByteData.sublistView(b, s, e);
        duration = e - s == 4 ? data.getFloat32(0) : data.getFloat64(0);
      case _idDateUtc when e - s == 8:
        final ns = ByteData.sublistView(b, s, e).getInt64(0);
        info.created =
            DateTime.utc(2001).add(Duration(microseconds: ns ~/ 1000));
      case _idWritingApp:
        info.writingApp = _string(b, s, e);
      case _idMuxingApp:
        info.writingApp ??= _string(b, s, e);
    }
  }
  if (duration != null && duration > 0 && duration.isFinite) {
    info.duration = Duration(microseconds: (duration * scale / 1000).round());
  }
}

void _matroskaTracks(VideoInfo info, Uint8List b) {
  for (final (id, s, e) in _ebmlChildren(b, 0, b.length)) {
    if (id != _idTrackEntry) continue;
    int? type, w, h, frameNs;
    String? codec;
    Uint8List? private;
    for (final (cid, cs, ce) in _ebmlChildren(b, s, e)) {
      switch (cid) {
        case _idTrackType:
          type = _uint(b, cs, ce);
        case _idCodecId:
          codec = _string(b, cs, ce).toLowerCase();
        case _idCodecPrivate:
          private = Uint8List.sublistView(b, cs, ce);
        case _idDefaultDuration:
          frameNs = _uint(b, cs, ce);
        case _idVideo:
          for (final (vid, vs, ve) in _ebmlChildren(b, cs, ce)) {
            if (vid == _idPixelWidth) w = _uint(b, vs, ve);
            if (vid == _idPixelHeight) h = _uint(b, vs, ve);
          }
      }
    }
    if (type == 2) info.hasAudio = true;
    if (type == 1 && !info.hasVideo) {
      info
        ..hasVideo = true
        ..width = w
        ..height = h
        ..codec = codec;
      // Video for Windows codecs keep their four-character code in a
      // BITMAPINFOHEADER.
      if (codec == 'v_ms/vfw/fourcc' &&
          private != null &&
          private.length >= 20) {
        info.codec = String.fromCharCodes(private, 16, 20).toLowerCase();
      }
      if (frameNs != null && frameNs > 0) info.frameRate = 1e9 / frameNs;
    }
  }
}

// --- AVI --------------------------------------------------------------------

Future<VideoInfo> _avi(
    _Reader r, Uint8List head, LargeOldVideoRules rules) async {
  final info = VideoInfo('AVI');
  final riffEnd = math.min(8 + u32le(head, 4), r.size);
  var pos = 12;
  var totalFrames = 0, usPerFrame = 0;
  int? moviSize;
  for (var n = 0; pos + 8 <= riffEnd && n < rules.maxElements; n++) {
    final h = pos + 12 <= head.length
        ? Uint8List.sublistView(head, pos, pos + 12)
        : await r.read(pos, 12);
    if (h.length < 8) break;
    final id = String.fromCharCodes(h, 0, 4);
    final size = u32le(h, 4);
    final list =
        id == 'LIST' && h.length >= 12 ? String.fromCharCodes(h, 8, 12) : null;
    final end = pos + 8 + size;
    if (list == 'movi') {
      moviSize = size - 4;
      if (end > r.size) {
        info.problem = _cutOff(
            'movi list needs $size bytes, ${r.size - pos - 8} remain',
            r.size,
            end,
            'a copy or recording stopped part-way');
      }
    }
    if (list == 'hdrl' && size <= 1024 * 1024) {
      final bytes = end <= head.length
          ? Uint8List.sublistView(head, pos + 12, end)
          : await r.read(pos + 12, size - 4);
      final hdr = _aviHeader(info, bytes);
      totalFrames = hdr.$1;
      usPerFrame = hdr.$2;
    }
    pos = end + (size & 1);
  }
  if (usPerFrame > 0) {
    info.frameRate = 1e6 / usPerFrame;
    if (totalFrames > 0) {
      info.duration = Duration(microseconds: totalFrames * usPerFrame);
    }
  }
  info.frames = totalFrames;
  if (info.problem != null) return info;
  if (moviSize == null) {
    info.problem = totalFrames > 0
        ? VideoProblem(
            VideoRule.v03Damaged,
            "Video has no picture data section, so it can't be played",
            'avih lists $totalFrames frames; no movi list')
        : const VideoProblem(
            VideoRule.v01Empty, _noFrames, 'no frames and no movi list');
  } else if (moviSize <= 0) {
    info.problem = VideoProblem(VideoRule.v01Empty, _noFrames,
        'movi list is empty; avih lists $totalFrames frames');
  }
  return info;
}

/// Reads avih and the stream headers from an hdrl list's contents. Returns
/// (total frames, microseconds per frame).
(int, int) _aviHeader(VideoInfo info, Uint8List b) {
  var frames = 0, usPerFrame = 0;
  var p = 0;
  while (p + 8 <= b.length) {
    final id = String.fromCharCodes(b, p, p + 4);
    final size = u32le(b, p + 4);
    final s = p + 8, e = math.min(s + size, b.length);
    if (id == 'avih' && e - s >= 40) {
      usPerFrame = u32le(b, s);
      frames = u32le(b, s + 16);
      info
        ..width = u32le(b, s + 32)
        ..height = u32le(b, s + 36);
    } else if (id == 'LIST' && e - s >= 4 && asciiAt(b, s, 'strl')) {
      var q = s + 4;
      String? type, handler;
      while (q + 8 <= e) {
        final cid = String.fromCharCodes(b, q, q + 4);
        final csize = u32le(b, q + 4);
        if (cid == 'strh' && q + 16 <= e) {
          type = String.fromCharCodes(b, q + 8, q + 12);
          handler = String.fromCharCodes(b, q + 12, q + 16);
        } else if (cid == 'strf' &&
            type == 'vids' &&
            q + 28 <= e &&
            (handler == null || handler.codeUnits.every((c) => c == 0))) {
          handler = String.fromCharCodes(b, q + 24, q + 28);
        }
        q += 8 + csize + (csize & 1);
      }
      if (type == 'vids' && !info.hasVideo) {
        info
          ..hasVideo = true
          ..codec = handler?.toLowerCase();
      }
      if (type == 'auds') info.hasAudio = true;
    }
    p = s + size + (size & 1);
  }
  return (frames, usPerFrame);
}

/// `1 h 10 min`, `25 min`, `42 s`.
String formatDuration(Duration d) {
  if (d.inHours >= 1) {
    final m = d.inMinutes % 60;
    return '${d.inHours} h${m == 0 ? '' : ' $m min'}';
  }
  if (d.inMinutes >= 1) return '${d.inMinutes} min';
  return '${math.max(0, d.inSeconds)} s';
}
