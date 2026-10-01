import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:scan_engine/scan_engine.dart';

/// A phone made of in-memory files, with permissions the test controls.
class FakeDevice implements DeviceAdapter {
  FakeDevice(
    Map<String, List<int>> files, {
    Map<ScanPermission, PermissionState>? permissions,
    this.platform = DevicePlatform.android,
    this.apps,
    this.stats,
  })  : memory = MemoryStorageSource(files),
        permissions = StaticPermissionService(
            permissions ?? {ScanPermission.storage: PermissionState.granted});

  final MemoryStorageSource memory;
  final StorageStats? stats;

  @override
  final DevicePlatform platform;
  @override
  final StaticPermissionService permissions;
  @override
  final AppInventory? apps;

  @override
  StorageSource get storage => memory;

  @override
  Set<ScanPermission> get storagePermissions => platform == DevicePlatform.ios
      ? const {ScanPermission.photos}
      : const {ScanPermission.storage};

  @override
  Future<StorageStats?> storageStats() async => stats;

  @override
  List<String> get limitations => const [];
}

final class FakeApps implements AppInventory {
  FakeApps(this.apps);
  final List<InstalledApp> apps;
  @override
  Future<List<InstalledApp>> listApps() async => apps;
}

/// Rules for fast tests: no isolates are involved with MemoryStorageSource,
/// and test images are 256+ px so the default minimum size applies.
const testRules = ScanRules(imageConcurrency: 2);

Future<ScanReport> scan(FakeDevice device,
        {List<WasteDetector>? detectors, ScanRules rules = testRules}) =>
    ScanEngine(device: device, rules: rules, detectors: detectors).scan();

/// Random blocks and circles; each seed gives a clearly different picture.
img.Image scene(int seed, {int width = 320, int height = 240}) {
  final r = Random(seed);
  final image = img.Image(width: width, height: height);
  img.fill(image,
      color: img.ColorRgb8(r.nextInt(256), r.nextInt(256), r.nextInt(256)));
  img.Color color() =>
      img.ColorRgb8(r.nextInt(256), r.nextInt(256), r.nextInt(256));
  for (var i = 0; i < 8; i++) {
    final x = r.nextInt(width), y = r.nextInt(height);
    img.fillRect(image,
        x1: x,
        y1: y,
        x2: x + 20 + r.nextInt(100),
        y2: y + 20 + r.nextInt(100),
        color: color());
  }
  for (var i = 0; i < 8; i++) {
    img.fillCircle(image,
        x: r.nextInt(width),
        y: r.nextInt(height),
        radius: 10 + r.nextInt(50),
        color: color());
  }
  return image;
}

/// White page with dark "text" bars; different seeds = different text in
/// the same layout.
img.Image receipt(int seed) {
  final r = Random(seed);
  final image = img.Image(width: 300, height: 400);
  img.fill(image, color: img.ColorRgb8(140, 95, 60));
  img.fillRect(image,
      x1: 75, y1: 30, x2: 225, y2: 370, color: img.ColorRgb8(245, 245, 240));
  for (var y = 50; y < 350; y += 12) {
    var x = 85;
    while (x < 215) {
      final word = 5 + r.nextInt(25);
      if (x + word > 215) break;
      img.fillRect(image,
          x1: x,
          y1: y,
          x2: x + word,
          y2: y + 4,
          color: img.ColorRgb8(30, 30, 30));
      x += word + 4;
    }
  }
  return image;
}

img.Image flat(int value, {int width = 320, int height = 240}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(value, value, value));
  return image;
}

img.Image jitter(img.Image source,
    {int seed = 1, int noise = 3, int brightness = 0}) {
  final r = Random(seed);
  final out = img.Image.from(source);
  for (var y = 0; y < out.height; y++) {
    for (var x = 0; x < out.width; x++) {
      final px = out.getPixel(x, y);
      int v(num c) =>
          (c.toInt() + brightness + r.nextInt(2 * noise + 1) - noise)
              .clamp(0, 255);
      out.setPixelRgb(x, y, v(px.r), v(px.g), v(px.b));
    }
  }
  return out;
}

Uint8List jpg(img.Image image, {int quality = 90}) =>
    img.encodeJpg(image, quality: quality);
Uint8List png(img.Image image) => img.encodePng(image);

/// An ISO media box (MP4/MOV/HEIC building block).
List<int> box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return [
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...payload
  ];
}

final ftyp = box('ftyp', 'isom\x00\x00\x02\x00isommp41'.codeUnits);

List<int> ascii(String s) => s.codeUnits;

Set<String> ids(Iterable<Finding> findings) => {
      for (final f in findings)
        for (final i in f.items) i.id
    };
