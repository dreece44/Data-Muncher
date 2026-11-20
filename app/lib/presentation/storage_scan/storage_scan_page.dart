import 'package:flutter/material.dart';
import 'package:scan_engine_flutter/scan_engine_flutter.dart' as engine;

import '../../application/storage_scan/storage_scan.dart';
import '../../application/storage_scan/team_views.dart';
import '../../core.dart';
import '../../data/garbage_bin/bin_entry.dart';
import '../../pages.dart' show darkGreen, green, mono;
import '../garbage_bin/format.dart';
import '../team_pages.dart';

enum _Stage { scanning, needsPermission, failed, done }

/// Storage scan (DAT-1): runs the scan engine over the phone's shared
/// storage, lists what it found with everything ticked, and moves the ticked
/// files to the Garbage Bin.
class StorageScanPage extends StatefulWidget {
  const StorageScanPage(this.state, {super.key});

  final MunchState state;

  @override
  State<StorageScanPage> createState() => _StorageScanPageState();
}

class _StorageScanPageState extends State<StorageScanPage> {
  engine.DeviceAdapter? _device;
  _Stage _stage = _Stage.scanning;
  String _status = 'Starting';
  Object? _error;
  engine.ScanReport? _report;
  List<ScanCandidate> _candidates = const [];
  List<engine.InstalledApp> _apps = const [];
  final Set<String> _selected = {};
  bool _moving = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<engine.DeviceAdapter> _deviceAdapter() async => _device ??= await engine.currentDevice();

  Future<void> _scan() async {
    setState(() {
      _stage = _Stage.scanning;
      _status = 'Checking permissions';
    });
    try {
      final device = await _deviceAdapter();
      for (final permission in device.storagePermissions) {
        if (!(await device.permissions.check(permission)).allowsAccess) {
          if (mounted) setState(() => _stage = _Stage.needsPermission);
          return;
        }
      }
      final report = await engine.ScanEngine(device: device).scan(onProgress: (p) {
        if (mounted) setState(() => _status = _describe(p));
      });
      final candidates = candidatesFrom(report, skip: widget.state.isExcludedPath);
      if (!mounted) return;
      setState(() {
        _report = report;
        _candidates = candidates;
        _apps = unusedAppsFrom(report);
        _selected
          ..clear()
          ..addAll(candidates.map((c) => c.item.id));
        _stage = _Stage.done;
      });
    } on engine.PermissionDeniedException {
      if (mounted) setState(() => _stage = _Stage.needsPermission);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _stage = _Stage.failed;
        });
      }
    }
  }

  /// On Android 11+ this opens the "All files access" screen; the scan
  /// starts again when the user comes back.
  Future<void> _grantAccess() async {
    final device = await _deviceAdapter();
    for (final permission in device.storagePermissions) {
      await device.permissions.request(permission);
    }
    if (mounted) await _scan();
  }

  Future<void> _moveToBin() async {
    final chosen = [for (final c in _candidates) if (_selected.contains(c.item.id)) c];
    setState(() => _moving = true);
    final result = await widget.state.collectFiles(chosen);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final failed = result.failed.isEmpty ? '' : " ${result.failed.length} couldn't be moved.";
    messenger.showSnackBar(SnackBar(
      content: Text('Moved ${result.moved} ${result.moved == 1 ? 'item' : 'items'} '
          '(${formatBytes(result.bytes)}) to the Garbage Bin.$failed'),
    ));
    Navigator.pop(context);
  }

  /// The garbage collection page, one row per category. What it sends to
  /// the bin also leaves this list.
  Future<void> _openGarbageCollection() {
    final groups = collectionGroupsFrom(_candidates);
    return openGarbageCollection(context, groups.keys.toList(), (chosen) async {
      final picked = [for (final row in chosen) ...groups[row]!];
      final result = await widget.state.collectFiles(picked);
      final failed = result.failed.toSet();
      final moved = {for (final c in picked) if (!failed.contains(c.path)) c.item.id};
      if (!mounted) return;
      setState(() {
        _candidates = [for (final c in _candidates) if (!moved.contains(c.item.id)) c];
        _selected.removeAll(moved);
      });
      if (failed.isNotEmpty) {
        // They stay in this page's list to try again.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("${failed.length} couldn't be moved.")));
      }
    });
  }

  static String _describe(engine.ScanProgress p) => switch (p.phase) {
        engine.ScanPhase.checkingPermissions => 'Checking permissions',
        engine.ScanPhase.listing => 'Listing files (${p.done})',
        engine.ScanPhase.detecting => p.total > 0
            ? 'Checking ${p.category?.label.toLowerCase() ?? 'files'} (${p.done}/${p.total})'
            : 'Checking ${p.category?.label.toLowerCase() ?? 'files'}',
        engine.ScanPhase.finishing => 'Finishing up',
      };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('STORAGE SCAN', style: mono), backgroundColor: Colors.transparent),
        body: switch (_stage) {
          _Stage.scanning => _centered([
              const CircularProgressIndicator(color: green),
              const SizedBox(height: 20),
              Text(_status.toUpperCase(), style: mono, textAlign: TextAlign.center),
            ]),
          _Stage.needsPermission => _centered([
              const Icon(Icons.folder_off_outlined, size: 48),
              const SizedBox(height: 16),
              const Text('DataMuncher needs access to your files to scan storage.', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _grantAccess,
                style: FilledButton.styleFrom(backgroundColor: darkGreen),
                child: const Text('ALLOW FILE ACCESS', style: mono),
              ),
            ]),
          _Stage.failed => _centered([
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              Text('The scan stopped: $_error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _scan, child: const Text('Try again')),
            ]),
          _Stage.done => _results(),
        },
        bottomNavigationBar: _stage == _Stage.done && _candidates.isNotEmpty
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: darkGreen, padding: const EdgeInsets.all(16)),
                    onPressed: _selected.isEmpty || _moving ? null : _moveToBin,
                    child: Text(
                      _moving ? 'MOVING…' : 'MOVE ${_selected.length} TO GARBAGE BIN',
                      style: mono,
                    ),
                  ),
                ),
              )
            : null,
      );

  Widget _centered(List<Widget> children) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      );

  Widget _results() {
    final report = _report!;
    final selectedBytes = _candidates
        .where((c) => _selected.contains(c.item.id))
        .fold<int>(0, (sum, c) => sum + c.item.sizeBytes);
    final groups = <CollectionReason, List<ScanCandidate>>{};
    for (final c in _candidates) {
      groups.putIfAbsent(c.reason, () => []).add(c);
    }

    return ListView(padding: const EdgeInsets.only(bottom: 16), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            _candidates.isEmpty ? 'NOTHING TO MUNCH' : '${_candidates.length} ITEMS FOUND',
            style: mono.copyWith(fontSize: 26, color: green),
          ),
          const SizedBox(height: 4),
          Text('Scanned ${report.itemsScanned} files (${formatBytes(report.bytesScanned)}) '
              'in ${(report.duration.inMilliseconds / 1000).toStringAsFixed(1)} s.'),
          if (_candidates.isNotEmpty) Text('${formatBytes(selectedBytes)} selected to move to the Garbage Bin.'),
          for (final note in report.notes)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(note, style: const TextStyle(fontSize: 12, color: Colors.white60)),
            ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: () => openStorageResults(context, scanResultsFrom(report, _candidates, _apps)),
              icon: const Icon(Icons.pie_chart_outline),
              label: const Text('Summary'),
            ),
            if (_candidates.isNotEmpty)
              OutlinedButton.icon(
                onPressed: _moving ? null : _openGarbageCollection,
                icon: const Icon(Icons.checklist),
                label: const Text('By category'),
              ),
          ]),
        ]),
      ),
      for (final MapEntry(key: reason, value: items) in groups.entries) ...[
        _header('${reason.label} (${items.length})'),
        for (final c in items)
          CheckboxListTile(
            value: _selected.contains(c.item.id),
            onChanged: _moving
                ? null
                : (on) => setState(() => on == true ? _selected.add(c.item.id) : _selected.remove(c.item.id)),
            activeColor: green,
            title: Text(c.item.displayName, overflow: TextOverflow.ellipsis),
            subtitle: Text('${_folderOf(c.path)} · ${formatBytes(c.item.sizeBytes)}\n${c.explanation}'),
            isThreeLine: true,
          ),
      ],
      if (_apps.isNotEmpty) ...[
        _header('Unused apps (${_apps.length})'),
        for (final app in _apps)
          ListTile(
            leading: const Icon(Icons.apps),
            title: Text(app.label),
            subtitle: Text('${formatBytes(app.sizeBytes)} · uninstall it from Settings to free this space'),
          ),
      ],
    ]);
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text.toUpperCase(), style: mono.copyWith(fontSize: 18)),
      );

  /// `/storage/emulated/0/Download/x.pdf` → `/Download`.
  static String _folderOf(String path) {
    final slash = path.lastIndexOf('/');
    var folder = slash <= 0 ? '' : path.substring(0, slash);
    const internal = '/storage/emulated/0';
    if (folder.startsWith(internal)) folder = folder.substring(internal.length);
    return folder.isEmpty ? '/' : folder;
  }
}
