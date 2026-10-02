import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:datamuncher/muncher.dart';

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
}
