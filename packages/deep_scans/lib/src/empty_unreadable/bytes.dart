import 'dart:typed_data';

bool bytesAt(List<int> h, int offset, List<int> expected) {
  if (offset < 0 || h.length < offset + expected.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (h[offset + i] != expected[i]) return false;
  }
  return true;
}

bool asciiAt(List<int> h, int offset, String text) =>
    bytesAt(h, offset, text.codeUnits);

int indexOf(List<int> haystack, List<int> needle, [int start = 0]) {
  outer:
  for (var i = start; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

int lastIndexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = haystack.length - needle.length; i >= 0; i--) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

bool allZero(List<int> bytes) {
  for (final b in bytes) {
    if (b != 0) return false;
  }
  return true;
}

/// Length of the run of zero bytes at the end of [bytes].
int trailingZeros(List<int> bytes) {
  var n = 0;
  for (var i = bytes.length - 1; i >= 0 && bytes[i] == 0; i--) {
    n++;
  }
  return n;
}

int u16le(List<int> b, int o) => b[o] | b[o + 1] << 8;
int u32le(List<int> b, int o) =>
    b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;
int u32be(List<int> b, int o) =>
    b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];
int u64le(List<int> b, int o) => u32le(b, o) + u32le(b, o + 4) * 0x100000000;

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

/// CRC-32 (ISO-HDLC), as used by PNG, ZIP and gzip.
int crc32(List<int> bytes, [int start = 0, int? end]) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < (end ?? bytes.length); i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

String hex32(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';

String kb(int bytes) => bytes < 1024
    ? '$bytes bytes'
    : '${(bytes / 1024).toStringAsFixed(bytes < 10240 ? 1 : 0)} KB';
