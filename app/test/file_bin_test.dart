import 'dart:io';

import 'package:datamuncher/data/garbage_bin/bin_entry.dart';
import 'package:datamuncher/data/garbage_bin/file_bin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late FileBin fileBin;

  File write(String rel, String content) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('file_bin_test_');
    fileBin = FileBin(binFolderFor: (path) => binFolderUnder([root.path], path));
  });

  tearDown(() => root.delete(recursive: true));

  test('collect moves the file into the hidden bin folder', () async {
    final file = write('Download/report.pdf', 'broken pdf');
    final record = await fileBin.collect(file.path, CollectionReason.unreadable);

    expect(file.existsSync(), isFalse);
    expect(File(record.storedPath).readAsStringSync(), 'broken pdf');
    expect(p.dirname(record.storedPath), p.join(root.path, fileBinFolderName));
    expect(File(p.join(root.path, fileBinFolderName, '.nomedia')).existsSync(), isTrue);
    expect(record.id, startsWith(fileBinIdPrefix));
    expect(record.fileName, 'report.pdf');
    expect(record.sizeBytes, 10);
    expect(fileBin.contains(record.id), isTrue);
    expect(await fileBin.isStored(record.id), isTrue);
  });

  test('two files with the same name are kept apart', () async {
    final a = await fileBin.collect(write('A/x.txt', 'a').path, CollectionReason.emptyFile);
    final b = await fileBin.collect(write('B/x.txt', 'b').path, CollectionReason.emptyFile);
    expect(a.id, isNot(b.id));
    expect(File(a.storedPath).readAsStringSync(), 'a');
    expect(File(b.storedPath).readAsStringSync(), 'b');
  });

  test('restore puts the file back, recreating its folder', () async {
    final file = write('Documents/sub/todo.txt', '  ');
    final record = await fileBin.collect(file.path, CollectionReason.emptyFile);
    Directory(p.join(root.path, 'Documents')).deleteSync(recursive: true);

    expect(await fileBin.restore(record.id), file.path);
    expect(file.readAsStringSync(), '  ');
    expect(fileBin.contains(record.id), isFalse);
  });

  test('restore never overwrites a file that took the name', () async {
    final file = write('DCIM/IMG_1.jpg', 'old');
    final record = await fileBin.collect(file.path, CollectionReason.duplicate);
    write('DCIM/IMG_1.jpg', 'new');

    final restored = await fileBin.restore(record.id);
    expect(p.basename(restored), 'IMG_1 (1).jpg');
    expect(File(restored).readAsStringSync(), 'old');
    expect(file.readAsStringSync(), 'new');
  });

  test('delete removes the stored file', () async {
    final record = await fileBin.collect(write('x.zip', 'z').path, CollectionReason.unreadable);
    await fileBin.delete(record.id);
    expect(File(record.storedPath).existsSync(), isFalse);
    expect(fileBin.isEmpty, isTrue);
  });

  test('isStored is false once the stored file is gone', () async {
    final record = await fileBin.collect(write('x.txt', 'x').path, CollectionReason.emptyFile);
    File(record.storedPath).deleteSync();
    expect(await fileBin.isStored(record.id), isFalse);
  });

  test('records survive encode and decode; junk is skipped', () async {
    final record = await fileBin.collect(write('a/b.mp4', 'v').path, CollectionReason.unreadable,
        now: DateTime.fromMillisecondsSinceEpoch(1790000000000));
    final decoded = FileBin.decode([...fileBin.encode(), 'not json', '{"id": 3}']);

    expect(decoded, hasLength(1));
    final copy = decoded.single;
    expect(copy.id, record.id);
    expect(copy.originalPath, record.originalPath);
    expect(copy.storedPath, record.storedPath);
    expect(copy.sizeBytes, 1);
    expect(copy.reason, CollectionReason.unreadable);
    expect(copy.collectedAt, record.collectedAt);
  });

  test('binFolderUnder picks the volume holding the file', () {
    final roots = ['/storage/emulated/0', '/storage/1A2B-3C4D'];
    expect(binFolderUnder(roots, '/storage/1A2B-3C4D/DCIM/a.jpg'),
        p.join('/storage/1A2B-3C4D', fileBinFolderName));
    expect(binFolderUnder(roots, '/storage/emulated/0/Download/a.pdf'),
        p.join('/storage/emulated/0', fileBinFolderName));
    expect(binFolderUnder(roots, '/elsewhere/a.pdf'), p.join('/storage/emulated/0', fileBinFolderName));
  });

  test('fileCategoryFor', () {
    expect(fileCategoryFor('IMG_1.JPG'), FileCategory.photo);
    expect(fileCategoryFor('clip.mp4'), FileCategory.video);
    expect(fileCategoryFor('song.mp3'), FileCategory.audio);
    expect(fileCategoryFor('lease.pdf'), FileCategory.document);
    expect(fileCategoryFor('Report.docx.crdownload'), FileCategory.other);
  });
}
