import 'package:flutter/material.dart';
import 'package:scan_engine_flutter/scan_engine_flutter.dart' as engine;

import '../pages.dart' show darkGreen, green, mono;
import 'folder_munch/main.dart' show MunchHome;
import 'garbage_collection/garbage_collection.dart' show GarbageCollectionPage, StorageItem;
import 'garbage_storage/garbage_collection_storage.dart' show GarbageStoragePage;
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
Future<void> openStorageResults(BuildContext context, ScanResults results) =>
    _push(context, Colors.deepPurple, StorageResultsPage(scanResults: results));

/// coilehayden0's Garbage Collection: tick categories and send them to the bin.
Future<void> openGarbageCollection(
  BuildContext context,
  List<StorageItem> items,
  Future<void> Function(List<StorageItem> selected) onSend,
) =>
    _push(context, Colors.deepPurple, GarbageCollectionPage(items: items, onSend: onSend));

/// coilehayden0's Garbage Bin Storage (DAT-17): compressed temporary storage.
Future<void> openGarbageStorage(BuildContext context) => _push(context, Colors.green, const GarbageStoragePage());

/// nathangh-ung's folder scan (DAT-16 classifier, DAT-18 one-tap munch).
Future<void> openFolderMunch(BuildContext context) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => const FolderMunchPage()));

/// Hosts [MunchHome]. It reads the picked folder with dart:io, which on
/// Android 11+ needs "All files access", so this asks for the same storage
/// access as the storage scan before showing it.
class FolderMunchPage extends StatefulWidget {
  const FolderMunchPage({super.key});

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
          true => const MunchHome(),
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
