import 'package:flutter/material.dart';

import '../../data/garbage_bin/file_bin.dart';

void main() {
  runApp(const GarbageStorageApp());
}

class GarbageStorageApp extends StatelessWidget {
  const GarbageStorageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Garbage Bin Storage',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const GarbageStoragePage(),
    );
  }
}

/// The Garbage Bin's file storage, as this page sees it (DAT-17). Files that
/// Scan storage and Scan a folder move to the bin are kept here, gzipped when
/// that saves space.
abstract class GarbageStorageSource implements Listenable {
  /// Files in the bin's storage.
  List<FileBinRecord> get files;

  /// Compresses one file; null when that wouldn't make it smaller.
  Future<FileBinRecord?> compress(String id);

  /// Deletes files for good; returns the ids that were deleted.
  Future<Set<String>> deleteForGood(List<String> ids);
}

class GarbageStoragePage extends StatefulWidget {
  const GarbageStoragePage({super.key, this.source});

  /// The bin's storage. Null (the page running on its own) shows it empty.
  final GarbageStorageSource? source;

  @override
  State<GarbageStoragePage> createState() => _GarbageStoragePageState();
}

class _GarbageStoragePageState extends State<GarbageStoragePage> {
  //track files selected for bulk deletion
  final Set<String> _selectedFileIds = {};
  bool _busy = false;

  List<FileBinRecord> get _files => widget.source?.files ?? const [];

  int get _usedStorage => _files.fold(0, (total, file) => total + file.storedSizeBytes);

  int get _originalStorage => _files.fold(0, (total, file) => total + file.sizeBytes);

  int get _spaceSaved => _files.fold(0, (total, file) => total + file.bytesSaved);

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  void _say(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) _say('Something went wrong: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Gzips one file in the bin; keeps it only if it got smaller.
  Future<void> _optimizeFile(FileBinRecord file) => _run(() async {
        final updated = await widget.source!.compress(file.id);
        if (!mounted) return;
        _say(updated == null
            ? '${file.fileName} cannot be reduced further with lossless compression.'
            : 'Optimized ${file.fileName}: saved ${_formatSize(updated.bytesSaved)}.');
      });

  Future<void> _optimizeAll() => _run(() async {
        var saved = 0;
        var count = 0;
        for (final file in _files.where((f) => !f.compressed).toList()) {
          final updated = await widget.source!.compress(file.id);
          if (updated != null) {
            saved += updated.bytesSaved;
            count++;
          }
        }
        if (!mounted) return;
        _say(count == 0
            ? 'Nothing more can be compressed.'
            : 'Compressed $count file(s), saving ${_formatSize(saved)}.');
      });

  void _toggleFileSelection(FileBinRecord file, bool selected) {
    setState(() {
      if (selected) {
        _selectedFileIds.add(file.id);
      } else {
        _selectedFileIds.remove(file.id);
      }
    });
  }

  void _selectAllFiles() {
    setState(() {
      if (_selectedFileIds.length == _files.length) {
        _selectedFileIds.clear();
      } else {
        _selectedFileIds.addAll(_files.map((file) => file.id));
      }
    });
  }

  /// Deletes [ids] for good after asking.
  Future<void> _delete(List<String> ids, {required String title}) async {
    if (ids.isEmpty) return;
    final bytes = _files.where((f) => ids.contains(f.id)).fold<int>(0, (t, f) => t + f.storedSizeBytes);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(
          '${ids.length} file(s) (${_formatSize(bytes)}) will be deleted for good. '
          "They can't be recovered afterwards.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      final deleted = await widget.source!.deleteForGood(ids);
      if (!mounted) return;
      setState(() => _selectedFileIds.removeAll(deleted));
      final kept = ids.length - deleted.length;
      _say('${deleted.length} file(s) deleted successfully.'
          '${kept == 0 ? '' : " $kept couldn't be deleted."}');
    });
  }

  Widget _statCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 12),
            Text(label, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    return source == null ? _page() : ListenableBuilder(listenable: source, builder: (_, __) => _page());
  }

  Widget _page() {
    final files = _files;
    _selectedFileIds.retainAll(files.map((f) => f.id));
    final original = _originalStorage;
    final storedShare = original == 0 ? 0.0 : _usedStorage / original;
    final canAct = widget.source != null && files.isNotEmpty && !_busy;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Garbage Bin Storage'),
        backgroundColor: Colors.green.shade100,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'Temporary Storage Manager',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Files sent to the Garbage Bin by Scan storage and Scan a folder are kept here, '
                'compressed when that saves space, until you recover or delete them.',
              ),
              const SizedBox(height: 20),

              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth < 550 ? 1 : 3;

                  return GridView.count(
                    crossAxisCount: columns,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: columns == 1 ? 2.5 : 1.5,
                    children: [
                      _statCard(
                        'Storage Used',
                        _formatSize(_usedStorage),
                        Icons.storage,
                        Colors.blue,
                      ),
                      _statCard(
                        'Space Saved',
                        _formatSize(_spaceSaved),
                        Icons.compress,
                        Colors.green,
                      ),
                      _statCard(
                        'Files Collected',
                        '${files.length}',
                        Icons.delete_outline,
                        Colors.orange,
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 20),

              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Compression',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: storedShare.clamp(0.0, 1.0),
                        minHeight: 12,
                        backgroundColor: Colors.grey.shade200,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${_formatSize(_usedStorage)} stored for '
                        '${_formatSize(original)} of files',
                      ),
                      Text(
                        '${files.where((f) => f.compressed).length} of ${files.length} file(s) compressed',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: canAct && files.any((f) => !f.compressed) ? _optimizeAll : null,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.compress),
                    label: const Text('Optimize All'),
                  ),
                  OutlinedButton.icon(
                    onPressed: canAct
                        ? () => _delete([for (final f in files) f.id], title: 'Empty Storage?')
                        : null,
                    icon: const Icon(Icons.delete_sweep),
                    label: const Text('Empty Storage'),
                  ),
                  OutlinedButton.icon(
                    onPressed: canAct ? _selectAllFiles : null,
                    icon: const Icon(Icons.select_all),
                    label: Text(
                      files.isNotEmpty && _selectedFileIds.length == files.length
                          ? 'Deselect All'
                          : 'Select All',
                    ),
                  ),

                  FilledButton.icon(
                    onPressed: _selectedFileIds.isEmpty || _busy
                        ? null
                        : () => _delete(_selectedFileIds.toList(), title: 'Delete Selected Files?'),
                    icon: const Icon(Icons.delete),
                    label: Text(
                      'Delete Selected (${_selectedFileIds.length})',
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              const Text(
                'Collected Garbage',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),

              if (files.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(28),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(
                            Icons.delete_outline,
                            size: 48,
                            color: Colors.grey,
                          ),
                          SizedBox(height: 12),
                          Text('Your garbage bin is empty.'),
                          Text(
                            'Run Scan storage or Scan a folder to collect garbage.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                ...files.map(
                  (file) => Card(
                    child: ListTile(
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: _selectedFileIds.contains(file.id),
                            onChanged: _busy
                                ? null
                                : (selected) {
                                    _toggleFileSelection(file, selected ?? false);
                                  },
                          ),
                          Icon(
                            file.compressed ? Icons.folder_zip : Icons.insert_drive_file,
                            color: file.compressed ? Colors.green : Colors.blueGrey,
                          ),
                        ],
                      ),
                      title: Text(
                        file.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'Original: ${_formatSize(file.sizeBytes)}\n'
                        'Stored: ${_formatSize(file.storedSizeBytes)}'
                        '${file.compressed ? " • Compressed" : " • Original retained"}',
                      ),
                      isThreeLine: true,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Optimize File',
                            icon: const Icon(Icons.tune),
                            onPressed: file.compressed || _busy ? null : () => _optimizeFile(file),
                          ),
                          IconButton(
                            tooltip: 'Remove File',
                            icon: const Icon(Icons.close),
                            onPressed: _busy ? null : () => _delete([file.id], title: 'Delete ${file.fileName}?'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 16),
              Text(
                'Original total: ${_formatSize(_originalStorage)}',
                style: const TextStyle(color: Colors.grey),
              ),
              const Text(
                'To put a file back where it was, recover it from the Garbage Bin.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
