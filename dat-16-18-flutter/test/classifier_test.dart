import 'package:flutter_test/flutter_test.dart';
import 'package:datamuncher/models.dart';
import 'package:datamuncher/classifier.dart';

void main() {
  test('flags empty files', () {
    final results = classifyFiles([FileRecord(path: 'a.txt', sizeBytes: 0)]);
    expect(results.length, 1);
    expect(results.first.category, WasteCategory.empty);
  });

  test('flags unreadable files', () {
    final results = classifyFiles([
      FileRecord(path: 'a.txt', sizeBytes: 10, isReadable: false),
    ]);
    expect(results.first.category, WasteCategory.unreadable);
  });

  test('flags duplicates and keeps the first path seen', () {
    final results = classifyFiles([
      FileRecord(path: 'a.jpg', sizeBytes: 500, contentHash: 'h1'),
      FileRecord(path: 'b.jpg', sizeBytes: 500, contentHash: 'h1'),
    ]);
    expect(results.length, 1);
    expect(results.first.file.path, 'b.jpg');
    expect(results.first.category, WasteCategory.duplicate);
  });

  test('each file is flagged at most once', () {
    final results = classifyFiles([FileRecord(path: 'a.txt', sizeBytes: 0)]);
    expect(results.length, 1);
  });

  test('summary totals bytes and counts per category', () {
    final summary = summarize(classifyFiles([
      FileRecord(path: 'a.txt', sizeBytes: 0),
      FileRecord(path: 'b.jpg', sizeBytes: 500, contentHash: 'h1'),
      FileRecord(path: 'c.jpg', sizeBytes: 500, contentHash: 'h1'),
    ]));
    expect(summary.totalFlagged, 2);
    expect(summary.totalBytesReclaimable, 500);
    expect(summary.countsByCategory[WasteCategory.empty], 1);
    expect(summary.countsByCategory[WasteCategory.duplicate], 1);
  });
}
