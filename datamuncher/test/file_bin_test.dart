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

  group('compression (DAT-17)', () {
    final text = List.filled(2000, 'the same line of text\n').join();

    test('text is kept gzipped in the bin and unpacked on recovery', () async {
      final file = write('Documents/log.txt', text);
      final record = await fileBin.collect(file.path, CollectionReason.other);

      expect(record.compressed, isTrue);
      expect(record.storedPath, endsWith(compressedSuffix));
      expect(record.sizeBytes, text.length);
      expect(record.storedSizeBytes, File(record.storedPath).lengthSync());
      expect(record.storedSizeBytes, lessThan(text.length ~/ 10));
      expect(record.bytesSaved, text.length - record.storedSizeBytes);
      expect(fileBin.bytesSaved, record.bytesSaved);

      expect(await fileBin.restore(record.id), file.path);
      expect(file.readAsStringSync(), text);
      expect(File(record.storedPath).existsSync(), isFalse);
    });

    test('photos and archives are not compressed on the way in', () async {
      final photo = await fileBin.collect(write('DCIM/a.jpg', text).path, CollectionReason.duplicate);
      final zip = await fileBin.collect(write('Download/b.zip', text).path, CollectionReason.unreadable);
      expect(photo.compressed, isFalse);
      expect(zip.compressed, isFalse);
    });

    test('compress by hand keeps the copy only when it is smaller', () async {
      final photo = await fileBin.collect(write('DCIM/a.jpg', text).path, CollectionReason.duplicate);
      final packed = await fileBin.compress(photo.id);
      expect(packed?.compressed, isTrue);
      expect(await fileBin.compress(photo.id), isNull, reason: 'already compressed');

      final tiny = await fileBin.collect(write('t.txt', 'x').path, CollectionReason.emptyFile);
      expect(await fileBin.compress(tiny.id), isNull, reason: 'gzip would make it bigger');
      expect(File(tiny.storedPath).readAsStringSync(), 'x');
      expect(fileBin[tiny.id]!.compressed, isFalse);
    });

    test('compressed records survive encode and decode', () async {
      final record = await fileBin.collect(write('a.txt', text).path, CollectionReason.other);
      final copy = FileBin.decode(fileBin.encode()).single;
      expect(copy.compressed, isTrue);
      expect(copy.storedSizeBytes, record.storedSizeBytes);
      expect(copy.sizeBytes, text.length);
    });
  });

  group('finding files again after the app lost its list', () {
    String binFolder() => p.join(root.path, fileBinFolderName);
    String recoverTo() => p.join(root.path, unknownOriginFolder);

    test('the index next to the files restores every record', () async {
      final kept = await fileBin.collect(write('Documents/todo.txt', ' ').path, CollectionReason.emptyFile);
      final gone = await fileBin.collect(write('Download/x.pdf', 'pdf').path, CollectionReason.unreadable);
      await fileBin.delete(gone.id);
      await fileBin.saveIndexes();
      expect(File(p.join(binFolder(), fileBinIndexName)).existsSync(), isTrue);

      // App data cleared: a new, empty bin.
      final fresh = FileBin(binFolderFor: fileBin.binFolderFor);
      expect(await fresh.adopt(binFolder(), recoverTo: recoverTo()), 1);
      final r = fresh[kept.id]!;
      expect(r.originalPath, kept.originalPath);
      expect(r.reason, CollectionReason.emptyFile);
      expect(r.collectedAt.millisecondsSinceEpoch, kept.collectedAt.millisecondsSinceEpoch);
      expect(fresh.contains(gone.id), isFalse);

      expect(await fresh.adopt(binFolder(), recoverTo: recoverTo()), 0, reason: 'nothing twice');
      expect(await fresh.restore(kept.id), kept.originalPath);
    });

    test('files with no index entry are recovered to Download under their own name', () async {
      Directory(binFolder()).createSync(recursive: true);
      File(p.join(binFolder(), '1792435450986941-41_todo.txt')).writeAsStringSync('todo');
      File(p.join(binFolder(), '.nomedia')).createSync();

      final fresh = FileBin(binFolderFor: fileBin.binFolderFor);
      expect(await fresh.adopt(binFolder(), recoverTo: recoverTo()), 1);
      final r = fresh.records.single;
      expect(r.id, '${fileBinIdPrefix}1792435450986941-41');
      expect(r.fileName, 'todo.txt');
      expect(r.originalPath, p.join(recoverTo(), 'todo.txt'));
      expect(r.collectedAt, DateTime.fromMicrosecondsSinceEpoch(1792435450986941));
      expect(r.reason, CollectionReason.other);

      expect(await fresh.restore(r.id), p.join(recoverTo(), 'todo.txt'));
      expect(File(p.join(recoverTo(), 'todo.txt')).readAsStringSync(), 'todo');
    });

    test('files the bin already knows are left alone', () async {
      await fileBin.collect(write('a.txt', 'a').path, CollectionReason.emptyFile);
      expect(await fileBin.adopt(binFolder(), recoverTo: recoverTo()), 0);
      expect(fileBin.length, 1);
    });

    test('a missing bin folder adopts nothing', () async {
      expect(await fileBin.adopt(p.join(root.path, 'nope'), recoverTo: recoverTo()), 0);
    });
  });

  test('worthCompressing skips formats that are already compressed', () {
    expect(worthCompressing('notes.txt'), isTrue);
    expect(worthCompressing('report.pdf'), isTrue);
    expect(worthCompressing('Report.docx.crdownload'), isTrue);
    expect(worthCompressing('IMG_1.jpg'), isFalse);
    expect(worthCompressing('clip.mp4'), isFalse);
    expect(worthCompressing('song.mp3'), isFalse);
    expect(worthCompressing('backup.zip'), isFalse);
    expect(worthCompressing('slides.pptx'), isFalse);
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
