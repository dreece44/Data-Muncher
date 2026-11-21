import 'dart:io';
import 'dart:typed_data';

import 'package:datamuncher/classifier.dart';
import 'package:datamuncher/models.dart';
import 'package:datamuncher/muncher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('munchMyData scans a real folder and classifies it', () {
    final dir = Directory.systemTemp.createTempSync('datamuncher_test_');
    File('${dir.path}/empty.txt').writeAsStringSync('');
    File('${dir.path}/a.txt').writeAsStringSync('same content');
    File('${dir.path}/b.txt').writeAsStringSync('same content');
    File('${dir.path}/unique.txt').writeAsStringSync('unique content');

    final result = munchMyData(dir.path);

    expect(result.totalScanned, 4);
    expect(result.summary.totalFlagged, 2); // empty.txt + one duplicate
    expect(result.humanSummary, contains('wasteful'));
    expect(result.files, hasLength(4));
    expect(result.skippedFolders, isEmpty);

    dir.deleteSync(recursive: true);
  });

  test('returns an empty result for a folder with nothing wasteful', () {
    final dir = Directory.systemTemp.createTempSync('datamuncher_test_');
    File('${dir.path}/unique.txt').writeAsStringSync('unique content');

    final result = munchMyData(dir.path);

    expect(result.totalScanned, 1);
    expect(result.summary.totalFlagged, 0);

    dir.deleteSync(recursive: true);
  });

  test('hidden folders such as the Garbage Bin are left out', () {
    final dir = Directory.systemTemp.createTempSync('datamuncher_test_');
    Directory('${dir.path}/.DataMuncherBin').createSync();
    File('${dir.path}/.DataMuncherBin/123-0_empty.txt').writeAsStringSync('');
    Directory('${dir.path}/Docs').createSync();
    File('${dir.path}/Docs/note.txt').writeAsStringSync('note');

    final result = munchMyData(dir.path);
    expect(result.totalScanned, 1);
    expect(result.summary.totalFlagged, 0);

    dir.deleteSync(recursive: true);
  });

  test('a folder that disappears mid-scan is skipped, not fatal', () {
    final skipped = <String>[];
    final files = scanFolder('${Directory.systemTemp.path}/no_such_folder_${DateTime.now().microsecondsSinceEpoch}',
        onSkip: skipped.add);
    expect(files, isEmpty);
  });

  test('munchMyDataInBackground gives the same answer off the main isolate', () async {
    final dir = Directory.systemTemp.createTempSync('datamuncher_test_');
    File('${dir.path}/empty.txt').writeAsStringSync('');
    final result = await munchMyDataInBackground(dir.path);
    expect(result.summary.countsByCategory, {WasteCategory.empty: 1});
    dir.deleteSync(recursive: true);
  });

  group('classifyPhoto', () {
    const size = 64;
    final photo = FileRecord(path: 'DCIM/a.jpg', sizeBytes: 1000);
    Uint8List luma(int Function(int x, int y) f) =>
        Uint8List.fromList([for (var y = 0; y < size; y++) for (var x = 0; x < size; x++) f(x, y)]);

    test('a black frame is empty', () {
      expect(classifyPhoto(photo, luma((_, __) => 3), size)?.category, WasteCategory.empty);
    });

    test('a soft, featureless photo is blurry', () {
      final r = classifyPhoto(photo, luma((x, _) => 100 + x ~/ 8), size);
      expect(r?.category, WasteCategory.blurry);
      expect(r?.reason, startsWith('Sharpness'));
    });

    test('a sharp photo passes', () {
      expect(classifyPhoto(photo, luma((x, y) => (x + y).isEven ? 30 : 220), size), isNull);
    });
  });

  test('isPhoto', () {
    expect(isPhoto('/DCIM/IMG_1.JPG'), isTrue);
    expect(isPhoto('/Download/a.pdf'), isFalse);
    expect(isPhoto('noext'), isFalse);
  });
}
