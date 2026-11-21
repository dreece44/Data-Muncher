import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:scan_engine_flutter/scan_engine_flutter.dart' as engine;

import '../../classifier.dart';
import '../../models.dart';
import '../../muncher.dart';

void main() => runApp(const DataMuncherApp());

class DataMuncherApp extends StatelessWidget {
  const DataMuncherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DataMuncher',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0C0F0A),
        colorScheme: const ColorScheme.dark(primary: Color(0xFF5FAE3D)),
      ),
      home: const MunchHome(),
    );
  }
}

/// What happened when flagged files were sent to the Garbage Bin.
typedef MoveOutcome = ({Set<String> movedPaths, String message});

class MunchHome extends StatefulWidget {
  const MunchHome({super.key, this.onMoveToBin, this.skip, this.decoder = const engine.FlutterThumbnailDecoder()});

  /// Moves flagged files to the Garbage Bin. Without it (the page running on
  /// its own) the results can only be looked at.
  final Future<MoveOutcome> Function(List<ClassificationResult> items)? onMoveToBin;

  /// Paths to leave out of the results, e.g. files the user recovered with
  /// "Do not collect".
  final bool Function(String path)? skip;

  /// Makes the small thumbnails the blurry-photo check looks at.
  final engine.ThumbnailDecoder decoder;

  @override
  State<MunchHome> createState() => _MunchHomeState();
}

class _MunchHomeState extends State<MunchHome> {
  /// Photos bigger than this aren't checked for blur; reading them would
  /// take long and they're rarely throwaway shots.
  static const _maxPhotoBytes = 40 * 1024 * 1024;
  static const _thumbnailSize = 64;

  MunchResult? _result;
  bool _loading = false;
  bool _moving = false;
  String _status = 'SCANNING…';
  String? _error;
  final _openCategories = <WasteCategory>{};

  Future<void> _scan() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return; // user cancelled the picker

    setState(() {
      _loading = true;
      _status = 'SCANNING…';
      _error = null;
    });
    try {
      var result = await munchMyDataInBackground(path);
      result = await _checkPhotos(result);
      final skip = widget.skip;
      if (skip != null) result = result.withItems([for (final r in result.items) if (!skip(r.file.path)) r]);
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't scan that folder: $e");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Adds black and blurry photos, using the phone's decoder for a small
  /// thumbnail of each one.
  Future<MunchResult> _checkPhotos(MunchResult result) async {
    final flagged = {for (final r in result.items) r.file.path};
    final photos = [
      for (final f in result.files)
        if (!flagged.contains(f.path) &&
            f.isReadable &&
            f.sizeBytes > 0 &&
            f.sizeBytes <= _maxPhotoBytes &&
            isPhoto(f.path) &&
            widget.decoder.supportsExtension(f.path.substring(f.path.lastIndexOf('.') + 1).toLowerCase()))
          f,
    ];
    final found = <ClassificationResult>[];
    for (var i = 0; i < photos.length; i++) {
      if (mounted) setState(() => _status = 'CHECKING PHOTOS (${i + 1}/${photos.length})');
      try {
        final thumb = await widget.decoder.decode(await File(photos[i].path).readAsBytes(), _thumbnailSize);
        if (thumb == null) continue;
        if (classifyPhoto(photos[i], thumb.luma, thumb.size) case final verdict?) found.add(verdict);
      } on FileSystemException {
        // Gone or unreadable since the scan; nothing to say about it.
      }
    }
    return found.isEmpty ? result : result.withItems([...result.items, ...found]);
  }

  Future<void> _moveToBin() async {
    final result = _result;
    final move = widget.onMoveToBin;
    if (result == null || move == null || result.items.isEmpty) return;
    final items = result.items;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Move ${items.length} ${items.length == 1 ? 'file' : 'files'} to the Garbage Bin?'),
        content: const Text('You can recover them from the bin until you empty it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Move')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _moving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final outcome = await move(items);
      if (!mounted) return;
      setState(() {
        _result = result.withItems([for (final r in items) if (!outcome.movedPaths.contains(r.file.path)) r]);
      });
      messenger.showSnackBar(SnackBar(content: Text(outcome.message)));
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  List<ClassificationResult> _itemsFor(WasteCategory cat) =>
      _result?.items.where((r) => r.category == cat).toList() ?? [];

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final canMove = widget.onMoveToBin != null && result != null && result.items.isNotEmpty && !_loading;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    const Center(
                      child: Text(
                        'DATAMUNCHER',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 30,
                          color: Color(0xFF4C8A2E),
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Center(child: _buildRing()),
                    const SizedBox(height: 16),
                    if (_error != null) _note(_error!, color: Colors.redAccent),
                    if (result != null && result.skippedFolders.isNotEmpty)
                      _note('${result.skippedFolders.length} '
                          '${result.skippedFolders.length == 1 ? "folder couldn't" : "folders couldn't"} '
                          'be opened and ${result.skippedFolders.length == 1 ? 'was' : 'were'} skipped.'),
                    const SizedBox(height: 8),
                    _categoryButton('DUPLICATES', WasteCategory.duplicate),
                    _categoryButton('EMPTY', WasteCategory.empty),
                    _categoryButton('UNREADABLE', WasteCategory.unreadable),
                    _categoryButton('BLURRY', WasteCategory.blurry),
                  ],
                ),
              ),
              if (canMove)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _moving ? null : _moveToBin,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1B3D12),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: Text(
                        _moving ? 'MOVING…' : 'MOVE ${result.items.length} TO GARBAGE BIN',
                        style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
                      ),
                    ),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading || _moving ? null : _scan,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2F6B1A),
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                  child: Text(
                    _loading
                        ? _status
                        : result == null
                            ? 'PICK A FOLDER'
                            : 'SCAN AGAIN (${result.summary.totalFlagged} FLAGGED)',
                    style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _note(String text, {Color color = const Color(0xFF9C9C98)}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: color, fontSize: 12)),
      );

  Widget _buildRing() {
    final pct = (_result != null && _result!.totalBytesScanned > 0)
        ? _result!.summary.totalBytesReclaimable / _result!.totalBytesScanned
        : 0.0;

    return SizedBox(
      width: 170,
      height: 170,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: pct.clamp(0.0, 1.0),
              strokeWidth: 16,
              backgroundColor: const Color(0xFF1C2B13),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF5FAE3D)),
            ),
          ),
          Text(
            _result == null ? '--' : '${(pct * 100).round()}%',
            style: const TextStyle(fontSize: 28, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _categoryButton(String label, WasteCategory cat) {
    final open = _openCategories.contains(cat);
    final items = _itemsFor(cat);

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFFCFCFCB)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _loading
                ? null
                : () {
                    if (_result == null) {
                      _scan();
                      return;
                    }
                    setState(() => open ? _openCategories.remove(cat) : _openCategories.add(cat));
                  },
            child: Text('$label${_result != null ? ' (${items.length})' : ''}'),
          ),
        ),
        if (open)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 6, bottom: 10),
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(maxHeight: 160),
            decoration: BoxDecoration(border: Border.all(color: const Color(0xFF2A2A28))),
            child: items.isEmpty
                ? const Text('None found.', style: TextStyle(color: Color(0xFF9C9C98), fontSize: 12))
                : ListView(
                    shrinkWrap: true,
                    children: items
                        .map((r) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '${r.file.path}\n${r.reason}',
                                style: const TextStyle(color: Color(0xFF9C9C98), fontSize: 12),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                  ),
          ),
        const SizedBox(height: 10),
      ],
    );
  }
}
