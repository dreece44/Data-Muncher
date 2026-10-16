import 'dart:async';

import 'package:datamuncher/data/garbage_bin/bin_entry.dart';
import 'package:datamuncher/data/garbage_bin/garbage_bin_store.dart';

/// Fixed "now" for tests: Wednesday 7 Oct 2026, noon local time.
final DateTime testNow = DateTime(2026, 10, 7, 12);

BinEntry makeEntry({
  String id = 'id',
  String fileName = 'file.jpg',
  String originalPath = '/DCIM/Camera/file.jpg',
  FileCategory category = FileCategory.photo,
  CollectionReason reason = CollectionReason.duplicate,
  int originalSizeBytes = 1000,
  int? storedSizeBytes,
  DateTime? collectedAt,
  DateTime? expiresAt,
}) {
  return BinEntry(
    id: id,
    fileName: fileName,
    originalPath: originalPath,
    category: category,
    reason: reason,
    originalSizeBytes: originalSizeBytes,
    storedSizeBytes: storedSizeBytes ?? originalSizeBytes,
    collectedAt: collectedAt ?? testNow.subtract(const Duration(days: 1)),
    expiresAt: expiresAt,
  );
}

/// Three files used by the screen tests:
/// - beach_duplicate.jpg: photo, 4.2 MB, compressed, yesterday, leaves in 2 days
/// - old_gameplay.mp4: video, 900 MB, 3 days ago, leaves in 20 days
/// - receipt_scan (2).pdf: document, 350 KB, today, no time limit
List<BinEntry> sampleEntries() => [
      makeEntry(
        id: 'p1',
        fileName: 'beach_duplicate.jpg',
        originalPath: '/DCIM/Camera/beach_duplicate.jpg',
        category: FileCategory.photo,
        reason: CollectionReason.duplicate,
        originalSizeBytes: 4200000,
        storedSizeBytes: 3900000,
        collectedAt: testNow.subtract(const Duration(days: 1)),
        expiresAt: testNow.add(const Duration(days: 2)),
      ),
      makeEntry(
        id: 'v1',
        fileName: 'old_gameplay.mp4',
        originalPath: '/Videos/old_gameplay.mp4',
        category: FileCategory.video,
        reason: CollectionReason.oldFile,
        originalSizeBytes: 900000000,
        storedSizeBytes: 880000000,
        collectedAt: testNow.subtract(const Duration(days: 3)),
        expiresAt: testNow.add(const Duration(days: 20)),
      ),
      makeEntry(
        id: 'd1',
        fileName: 'receipt_scan (2).pdf',
        originalPath: '/Documents/receipt_scan (2).pdf',
        category: FileCategory.document,
        reason: CollectionReason.duplicate,
        originalSizeBytes: 350000,
        storedSizeBytes: 120000,
        collectedAt: testNow.subtract(const Duration(hours: 2)),
      ),
    ];

/// A store whose loads finish only when the test completes them.
class ScriptedGarbageBinStore implements GarbageBinStore {
  final List<Completer<List<BinEntry>>> pendingLoads = [];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Future<List<BinEntry>> listEntries() {
    final load = Completer<List<BinEntry>>();
    pendingLoads.add(load);
    return load.future;
  }

  @override
  Stream<void> get changes => _changes.stream;
}

/// Lets queued microtasks (stream events, async loads) run.
Future<void> settle() => Future<void>.delayed(Duration.zero);
