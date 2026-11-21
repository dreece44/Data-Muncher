import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Builds a fake phone storage folder with known waste in it, plus an app
/// list, so the scanner can be tested on a computer (or pushed to an Android
/// emulator with `adb push`).
///
///   dart run tool/make_sample_storage.dart [output-folder]
///
/// Defaults to `sample_phone` and `sample_phone_apps.json` in the current
/// folder. The expected scan results are listed in README.md.
Future<void> main(List<String> args) async {
  final root = p.absolute(args.isEmpty ? 'sample_phone' : args.first);
  final appsFile = '${root}_apps.json';
  const marker = '.datamuncher_sample';
  final dir = Directory(root);
  if (dir.existsSync() && dir.listSync().isNotEmpty) {
    // Only ever replace a folder this tool made, never a real one.
    if (!File(p.join(root, marker)).existsSync()) {
      stderr.writeln('$root already exists and was not made by this tool; '
          'choose another folder.');
      exitCode = 1;
      return;
    }
    dir.deleteSync(recursive: true);
  }

  void write(String relative, List<int> bytes) {
    final file = File(p.join(root, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  void text(String relative, String content) =>
      write(relative, utf8.encode(content));

  // --- Photos -------------------------------------------------------------
  final hike = _scene(1);
  final hikeJpg = img.encodeJpg(hike, quality: 90);
  write('DCIM/Camera/IMG_20260912_101500.jpg', hikeJpg);
  // Same shot a moment later: slightly brighter, sensor noise.
  write(
      'DCIM/Camera/IMG_20260912_101501.jpg',
      img.encodeJpg(_adjust(hike, seed: 7, noise: 4, brightness: 6),
          quality: 85));
  // Same shot, re-saved smaller (like a "sent" copy).
  write(
      'DCIM/Camera/IMG_20260912_101502.jpg',
      img.encodeJpg(img.copyResize(hike, width: 640, height: 480),
          quality: 80));
  // Byte-for-byte copy saved by a messaging app.
  write('Pictures/WhatsApp/IMG-20260913-WA0001.jpg', hikeJpg);

  // Two receipts shot twice each: identical pair and a genuinely different one.
  final receiptA = _receipt(11);
  write('DCIM/Camera/IMG_20260914_090000.jpg',
      img.encodeJpg(receiptA, quality: 90));
  write(
      'DCIM/Camera/IMG_20260914_090002.jpg',
      img.encodeJpg(_adjust(receiptA, seed: 3, noise: 3, brightness: -4),
          quality: 88));
  write('DCIM/Camera/IMG_20260914_091500.jpg',
      img.encodeJpg(_receipt(12), quality: 90));

  write('DCIM/Camera/IMG_20260914_120000.jpg',
      img.encodeJpg(_scene(2), quality: 90));
  write('DCIM/Camera/IMG_20260914_120500.jpg',
      img.encodeJpg(_scene(3), quality: 90));

  // Pocket shot: black with a little sensor noise.
  write(
      'DCIM/Camera/IMG_20260915_220000.jpg',
      img.encodeJpg(_adjust(_flat(800, 600, 8), seed: 5, noise: 3),
          quality: 90));
  // Blank white screenshot.
  write('Pictures/Screenshots/Screenshot_20260916-101010.png',
      img.encodePng(_flat(540, 960, 255)));
  // A small flat icon: too small to be a photo, so it must NOT be reported.
  write('Pictures/Stickers/red_dot.png', img.encodePng(_flat(96, 96, 200)));

  // A photo whose data was damaged partway through.
  final damaged = Uint8List.fromList(img.encodeJpg(_scene(4), quality: 90));
  final noise = Random(99);
  for (var i = damaged.length ~/ 3; i < damaged.length - 2; i++) {
    damaged[i] = noise.nextInt(256);
  }
  write('DCIM/Camera/IMG_20260917_080000.jpg', damaged);

  // --- Downloads and documents ---------------------------------------------
  final pdf = _minimalPdf('Invoice #0042');
  write('Download/invoice_0042.pdf', pdf);
  write('Download/invoice_0042 (1).pdf', pdf.sublist(0, pdf.length - 40));
  write('Download/lease_agreement.pdf',
      utf8.encode('<html><body><h1>404 Not Found</h1></body></html>'));
  write('Download/receipts_backup.zip',
      [0x50, 0x4B, 0x03, 0x04, ...List.generate(3000, (i) => (i * 31) % 256)]);
  write('Download/empty_archive.zip',
      [0x50, 0x4B, 0x05, 0x06, ...List.filled(18, 0)]);
  write('Download/Quarterly Report.docx.crdownload',
      List.generate(5000, (i) => i % 256));
  write('Download/podcast_episode.mp3', const []);
  text('Documents/notes.txt',
      'Pick up flour, butter, vanilla.\nCall Grandpa Sunday.\n');
  text('Documents/todo.txt', '   \n\n\t  \n');
  write('Documents/scan_copy.jpg', List.filled(50 * 1024, 0));

  // --- Videos ---------------------------------------------------------------
  write('Movies/VID_20260920_183000.mp4', [
    ..._box('ftyp', 'isom\x00\x00\x02\x00isommp41'.codeUnits),
    ..._box('moov', List.filled(100, 1)),
    ..._box('mdat', List.filled(4000, 2))
  ]);
  write('Movies/VID_20260921_090000.mp4', [
    ..._box('ftyp', 'isom\x00\x00\x02\x00isommp41'.codeUnits),
    ..._box('mdat', List.filled(4000, 2))
  ]);
  final cutOff = [
    ..._box('ftyp', 'isom\x00\x00\x02\x00isommp41'.codeUnits),
    ..._box('moov', List.filled(100, 1)),
    ..._box('mdat', List.filled(4000, 2))
  ];
  write('Movies/VID_20260922_120000.mp4',
      cutOff.sublist(0, cutOff.length - 1500));

  // --- Things the scanner must ignore ---------------------------------------
  write(marker, const []);
  write('.nomedia', const []);
  write('Pictures/.thumbnails/thumb_101500.jpg', hikeJpg);

  // --- Installed apps (for unused-app detection) ----------------------------
  final now = DateTime.now();
  String ago(int days) => now.subtract(Duration(days: days)).toIso8601String();
  final apps = [
    {
      'packageName': 'com.example.puzzlequest',
      'label': 'Puzzle Quest',
      'sizeBytes': 412 << 20,
      'installedAt': ago(400),
      'lastUsedAt': ago(200)
    },
    {
      'packageName': 'com.example.linguaplus',
      'label': 'Lingua+ Language Course',
      'sizeBytes': 1126 << 20,
      'installedAt': ago(300)
    },
    {
      'packageName': 'com.example.maps',
      'label': 'Maps',
      'sizeBytes': 250 << 20,
      'installedAt': ago(700),
      'lastUsedAt': ago(3)
    },
    {
      'packageName': 'com.example.newgame',
      'label': 'Brand New Game',
      'sizeBytes': 300 << 20,
      'installedAt': ago(5)
    },
    {
      'packageName': 'com.example.sms',
      'label': 'Messages',
      'sizeBytes': 80 << 20,
      'installedAt': ago(700),
      'isEssential': true
    },
    {
      'packageName': 'com.android.camera',
      'label': 'Camera',
      'sizeBytes': 60 << 20,
      'installedAt': ago(700),
      'isSystem': true
    },
  ];
  File(appsFile)
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(apps));

  stdout
    ..writeln('Sample phone storage written to $root')
    ..writeln('Sample app list written to $appsFile');
}

/// A made-up outdoor scene: gradient sky plus random shapes.
img.Image _scene(int seed, {int width = 800, int height = 600}) {
  final r = Random(seed);
  final image = img.Image(width: width, height: height);
  final top = [r.nextInt(256), r.nextInt(256), r.nextInt(256)];
  final bottom = [r.nextInt(256), r.nextInt(256), r.nextInt(256)];
  for (var y = 0; y < height; y++) {
    final t = y / height;
    final c = [
      for (var i = 0; i < 3; i++) (top[i] * (1 - t) + bottom[i] * t).round()
    ];
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, c[0], c[1], c[2]);
    }
  }
  img.Color color() =>
      img.ColorRgb8(r.nextInt(256), r.nextInt(256), r.nextInt(256));
  for (var i = 0; i < 10; i++) {
    final x = r.nextInt(width), y = r.nextInt(height);
    img.fillRect(image,
        x1: x,
        y1: y,
        x2: x + 40 + r.nextInt(200),
        y2: y + 40 + r.nextInt(200),
        color: color());
  }
  for (var i = 0; i < 12; i++) {
    img.fillCircle(image,
        x: r.nextInt(width),
        y: r.nextInt(height),
        radius: 20 + r.nextInt(90),
        color: color());
  }
  return image;
}

/// A white receipt with lines of "text" (dark bars) on a wooden table.
/// Different seeds give the same layout with different text, which is the
/// case that must NOT be called a duplicate.
img.Image _receipt(int seed) {
  final r = Random(seed);
  final image = img.Image(width: 600, height: 800);
  img.fill(image, color: img.ColorRgb8(140, 95, 60));
  img.fillRect(image,
      x1: 150, y1: 60, x2: 450, y2: 740, color: img.ColorRgb8(245, 245, 240));
  for (var y = 100; y < 700; y += 24) {
    var x = 170;
    while (x < 430) {
      final word = 10 + r.nextInt(50);
      if (x + word > 430) break;
      img.fillRect(image,
          x1: x,
          y1: y,
          x2: x + word,
          y2: y + 9,
          color: img.ColorRgb8(30, 30, 30));
      x += word + 8;
    }
  }
  return image;
}

img.Image _flat(int width, int height, int value) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(value, value, value));
  return image;
}

img.Image _adjust(img.Image source,
    {required int seed, int noise = 0, int brightness = 0}) {
  final r = Random(seed);
  final out = img.Image.from(source);
  for (var y = 0; y < out.height; y++) {
    for (var x = 0; x < out.width; x++) {
      final px = out.getPixel(x, y);
      int v(num c) => (c.toInt() +
              brightness +
              (noise == 0 ? 0 : r.nextInt(2 * noise + 1) - noise))
          .clamp(0, 255);
      out.setPixelRgb(x, y, v(px.r), v(px.g), v(px.b));
    }
  }
  return out;
}

List<int> _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return [
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...payload,
  ];
}

List<int> _minimalPdf(String text) => utf8.encode('''%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 300 144] /Contents 4 0 R >> endobj
4 0 obj << /Length 44 >> stream
BT /F1 18 Tf 20 100 Td ($text) Tj ET
endstream endobj
trailer << /Root 1 0 R >>
%%EOF
''');
