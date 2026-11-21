import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:scan_engine_flutter/scan_engine_flutter.dart' as engine;

import '../application/storage_scan/storage_scan.dart';
import '../core.dart';
import '../data/garbage_bin/bin_entry.dart';
import '../data/garbage_bin/file_bin.dart';
import '../models.dart' as dat16;
import '../pages.dart' show darkGreen, green, mono;
import 'folder_munch/main.dart' show MoveOutcome, MunchHome;
import 'garbage_bin/format.dart';
import 'garbage_collection/garbage_collection.dart' show GarbageCollectionPage, StorageItem;
import 'garbage_storage/garbage_collection_storage.dart' show GarbageStoragePage, GarbageStorageSource;
import 'storage_results/storage_results.dart' show ScanResults, StorageResultsPage;

// Teammates' pages, opened from the DataMuncher app. Each was built as its
// own app with a light theme, so it keeps that theme here rather than the
// app's dark one (their light cards would otherwise get white text).

Future<void> _push(BuildContext context, Color seed, Widget page) => Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Theme(
          data: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed), useMaterial3: true),
          child: page,
        ),
      ),
    );

/// coilehayden0's Storage Scan Results, with the wasted-space notice.
/// View Details goes back to the scan's file list, which opened this page.
Future<void> openStorageResults(BuildContext context, ScanResults results, {VoidCallback? onExport}) {
  final navigator = Navigator.of(context);
  return _push(
    context,
    Colors.deepPurple,
    StorageResultsPage(scanResults: results, onViewDetails: () => navigator.pop(), onExport: onExport),
  );
}

/// coilehayden0's Garbage Collection: tick categories and send them to the bin.
Future<void> openGarbageCollection(
  BuildContext context,
  List<StorageItem> items,
  Future<String?> Function(List<StorageItem> selected) onSend,
) =>
    _push(context, Colors.deepPurple, GarbageCollectionPage(items: items, onSend: onSend));

/// coilehayden0's Garbage Bin Storage (DAT-17): the bin's compressed file
/// storage.
Future<void> openGarbageStorage(BuildContext context, MunchState state) {
  unawaited(state.adoptStrandedFiles());
  return _push(context, Colors.green, GarbageStoragePage(source: MunchStorageSource(state)));
}

/// The Garbage Bin's storage files, for the Garbage Storage page.
class MunchStorageSource implements GarbageStorageSource {
  MunchStorageSource(this.state);

  final MunchState state;

  /// Newest first, like the Garbage Bin.
  @override
  List<FileBinRecord> get files =>
      state.fileBin.records.toList()..sort((a, b) => b.collectedAt.compareTo(a.collectedAt));

  @override
  Future<FileBinRecord?> compress(String id) => state.compressFile(id);

  /// Storage files have no trash; the page has already warned that this is
  /// for good.
  @override
  Future<Set<String>> deleteForGood(List<String> ids) async =>
      (await state.deleteFromBin(ids, allowPermanent: true)).removedIds;

  @override
  void addListener(VoidCallback listener) => state.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => state.removeListener(listener);
}

/// nathangh-ung's folder scan (DAT-16 classifier, DAT-18 one-tap munch).
Future<void> openFolderMunch(BuildContext context, MunchState state) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => FolderMunchPage(state)));

/// The Garbage Bin reason for a folder-scan finding.
CollectionReason reasonForFolderFinding(dat16.WasteCategory category) => switch (category) {
      dat16.WasteCategory.empty => CollectionReason.emptyFile,
      dat16.WasteCategory.unreadable => CollectionReason.unreadable,
      dat16.WasteCategory.duplicate => CollectionReason.duplicate,
      dat16.WasteCategory.blurry => CollectionReason.blurry,
    };

/// Folder-scan findings as storage-scan candidates, so they go into the
/// same Garbage Bin.
List<ScanCandidate> candidatesFromFolderScan(List<dat16.ClassificationResult> items) => [
      for (final r in items)
        ScanCandidate(
          item: engine.StorageItem(
            id: r.file.path,
            path: r.file.path,
            displayName: p.basename(r.file.path),
            sizeBytes: r.file.sizeBytes,
          ),
          reason: reasonForFolderFinding(r.category),
          explanation: r.reason,
        ),
    ];

/// Hosts [MunchHome]. It reads the picked folder with dart:io, which on
/// Android 11+ needs "All files access", so this asks for the same storage
/// access as the storage scan before showing it. What it finds can be moved
/// to the Garbage Bin like the storage scan's results.
class FolderMunchPage extends StatefulWidget {
  const FolderMunchPage(this.state, {super.key});

  final MunchState state;

  @override
  State<FolderMunchPage> createState() => _FolderMunchPageState();
}

class _FolderMunchPageState extends State<FolderMunchPage> {
  engine.DeviceAdapter? _device;

  /// Null while checking.
  bool? _allowed;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<engine.DeviceAdapter> _deviceAdapter() async => _device ??= await engine.currentDevice();

  Future<void> _check() async {
    var allowed = true;
    try {
      final device = await _deviceAdapter();
      for (final permission in device.storagePermissions) {
        if (!(await device.permissions.check(permission)).allowsAccess) allowed = false;
      }
    } catch (_) {
      allowed = false;
    }
    if (mounted) setState(() => _allowed = allowed);
  }

  Future<MoveOutcome> _moveToBin(List<dat16.ClassificationResult> items) async {
    final candidates = candidatesFromFolderScan(items);
    final result = await widget.state.collectFiles(candidates);
    final failed = result.failed.toSet();
    final moved = {for (final c in candidates) if (!failed.contains(c.path)) c.path};
    final tail = failed.isEmpty ? '' : " ${failed.length} couldn't be moved.";
    return (
      movedPaths: moved,
      message: 'Moved ${result.moved} ${result.moved == 1 ? 'file' : 'files'} '
          '(${formatBytes(result.bytes)}) to the Garbage Bin.$tail',
    );
  }

  Future<void> _grantAccess() async {
    final device = await _deviceAdapter();
    for (final permission in device.storagePermissions) {
      await device.permissions.request(permission);
    }
    await _check();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('FOLDER MUNCH', style: mono), backgroundColor: Colors.transparent),
        body: switch (_allowed) {
          null => const Center(child: CircularProgressIndicator(color: green)),
          true => MunchHome(onMoveToBin: _moveToBin, skip: widget.state.isExcludedPath),
          false => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.folder_off_outlined, size: 48),
                  const SizedBox(height: 16),
                  const Text('Scanning a folder needs access to your files.', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _grantAccess,
                    style: FilledButton.styleFrom(backgroundColor: darkGreen),
                    child: const Text('ALLOW FILE ACCESS', style: mono),
                  ),
                ]),
              ),
            ),
        },
      );
}
