
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

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

class GarbageFile {
  final String id;
  final String name;
  final int originalSize;
  final List<int> storedBytes;
  final bool compressed;
  final bool doNotCollect;

  GarbageFile({
    required this.id,
    required this.name,
    required this.originalSize,
    required this.storedBytes,
    required this.compressed,
    this.doNotCollect = false,
  });

  int get storedSize => storedBytes.length;
  int get spaceSaved => originalSize - storedSize;
}

class DeletionBackup {
  final GarbageFile file;
  final DateTime deletedAt;
  final DateTime expiresAt;

  const DeletionBackup({
    required this.file,
    required this.deletedAt,
    required this.expiresAt,
  });
}

class GarbageStoragePage extends StatefulWidget {
  const GarbageStoragePage({super.key});

  @override
  State<GarbageStoragePage> createState() => _GarbageStoragePageState();
}

class _GarbageStoragePageState extends State<GarbageStoragePage> {
  static const int retentionDays = 30;

  final List<GarbageFile> _files = [];
  final List<GarbageFile> _recoveredFiles = [];
  final List<DeletionBackup> _backups = [];
  bool _isAddingFile = false;
  final Set<String> _selectedFileIds = {};
  Timer? _backupExpiryTimer;

  @override
  void initState() {
    super.initState();
    // Check regularly so backups expire even if the page stays open.
    _backupExpiryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _purgeExpiredBackups(),
    );
  }

  @override
  void dispose() {
    _backupExpiryTimer?.cancel();
    super.dispose();
  }

  void _purgeExpiredBackups() {
    final now = DateTime.now();
    final expiredCount = _backups.where((backup) => !backup.expiresAt.isAfter(now)).length;
    if (expiredCount == 0 || !mounted) return;

    setState(() {
      _backups.removeWhere((backup) => !backup.expiresAt.isAfter(now));
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$expiredCount expired backup(s) permanently deleted.'),
      ),
    );
  }

  void _createBackups(Iterable<GarbageFile> files) {
    final now = DateTime.now();
    for (final file in files) {
      _backups.add(
        DeletionBackup(
          file: file,
          deletedAt: now,
          expiresAt: now.add(const Duration(days: retentionDays)),
        ),
      );
    }
  }

  String _formatDateTime(DateTime dateTime) {
    final local = dateTime.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute';
  }

  Future<void> _confirmRecovery(
    GarbageFile file, {
    required bool fromBackup,
  }) async {
    final markDoNotCollect = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore File?'),
        content: Text(
          'Restore "${file.name}"? You can also mark it as Do Not Collect '
          'so it will not be collected again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Restore'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Restore & Do Not Collect'),
          ),
        ],
      ),
    );

    if (markDoNotCollect == null || !mounted) return;

    final restoredFile = GarbageFile(
      id: file.id,
      name: file.name,
      originalSize: file.originalSize,
      storedBytes: List<int>.from(file.storedBytes),
      compressed: file.compressed,
      doNotCollect: markDoNotCollect,
    );

    setState(() {
      _recoveredFiles.removeWhere((item) => item.id == restoredFile.id);
      _recoveredFiles.add(restoredFile);

      if (fromBackup) {
        _backups.removeWhere((backup) => backup.file.id == file.id);
      } else {
        _files.removeWhere((item) => item.id == file.id);
        _selectedFileIds.remove(file.id);
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          markDoNotCollect
              ? '${file.name} restored and marked Do Not Collect.'
              : '${file.name} restored.',
        ),
      ),
    );
  }

  Future<void> _downloadRecoveredFile(GarbageFile file) async {
    try {
      final originalBytes = file.compressed
          ? GZipDecoder().decodeBytes(file.storedBytes)
          : file.storedBytes;

      await FilePicker.platform.saveFile(
        dialogTitle: 'Save recovered file',
        fileName: file.name,
        bytes: Uint8List.fromList(originalBytes),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not export ${file.name}: $error')),
      );
    }
  }

  void _permanentlyDeleteBackup(DeletionBackup backup) {
    setState(() {
      _backups.remove(backup);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${backup.file.name} permanently deleted.')),
    );
  }

  
void _optimizeFile(GarbageFile file) {
  try {
    // Recover original contents if the file is GZIP-compressed.
    final List<int> originalBytes = file.compressed
        ? GZipDecoder().decodeBytes(file.storedBytes)
        : file.storedBytes;

    // Attempt lossless compression for any file type.
    final List<int>? compressedBytes =
        GZipEncoder().encode(originalBytes);

    final bool useCompression =
        compressedBytes != null &&
        compressedBytes.length < originalBytes.length;

    // Keep compressed data only when it is smaller.
    final List<int> optimizedBytes = useCompression
        ? compressedBytes!
        : originalBytes;

    setState(() {
      final index =
          _files.indexWhere((item) => item.id == file.id);

      if (index != -1) {
        _files[index] = GarbageFile(
          id: file.id,
          name: file.name,
          originalSize: file.originalSize,
          storedBytes: List<int>.from(optimizedBytes),
          compressed: useCompression,
          doNotCollect: file.doNotCollect,
        );
      }
    });

    final int saved =
        originalBytes.length - optimizedBytes.length;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved > 0
              ? 'Optimized ${file.name}: saved ${_formatSize(saved)}.'
              : '${file.name} cannot be reduced further with lossless compression.',
        ),
      ),
    ); 
  } catch (error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Could not optimize ${file.name}: $error',
        ),
      ),
    );
  }
}

  // Proposed project decision: maximum of 100 MiB in temporary storage.
  static const int storageLimit = 100 * 1024 * 1024;

  int get _usedStorage =>
      _files.fold(0, (total, file) => total + file.storedSize);

  int get _originalStorage =>
      _files.fold(0, (total, file) => total + file.originalSize);

  int get _spaceSaved =>
      _files.fold(0, (total, file) => total + file.spaceSaved);

  double get _storagePercentage =>
      _usedStorage / storageLimit;

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _addFiles() async {
    if (_isAddingFile) return;

    setState(() => _isAddingFile = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
      );

      if (!mounted || result == null) return;

      int added = 0;
      int rejected = 0;
      int unavailable = 0;

      for (final file in result.files) {
        final Uint8List? bytes = file.bytes;

        if (bytes == null) {
          unavailable++;
          continue;
        }

        // Compress in memory, then keep the smaller representation.
        List<int> storedBytes = bytes;
        bool compressed = false;

        try {
          final compressedBytes = GZipEncoder().encode(bytes);

          if (compressedBytes != null && compressedBytes.length < bytes.length) {
            storedBytes = compressedBytes;
            compressed = true;
          }
        } catch (_) {
          // If compression fails, retain the original file bytes.
        }

        // Check the cap against actual stored size.
        if (_usedStorage + storedBytes.length > storageLimit) {
          rejected++;
          continue;
        }

        setState(() {
          _files.add(
            GarbageFile(
              id: '${DateTime.now().microsecondsSinceEpoch}_$added',
              name: file.name,
              originalSize: bytes.length,
              storedBytes: List<int>.from(storedBytes),
              compressed: compressed,
            ),
          );
        });

        added++;
      }

      if (!mounted) return;

      final messages = <String>[
        if (added > 0) '$added file(s) added.',
        if (rejected > 0)
          '$rejected file(s) rejected: the 100 MiB storage limit would be exceeded.',
        if (unavailable > 0)
          '$unavailable file(s) could not be read by the browser.',
      ];

      if (messages.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(messages.join(' '))),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not collect files: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isAddingFile = false);
      }
    }
  }
  
void _toggleFileSelection(GarbageFile file, bool selected) {
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

Future<void> _deleteSelectedFiles() async {
  if (_selectedFileIds.isEmpty) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete Selected Files?'),
      content: Text(
        'Are you sure you want to delete '
        '${_selectedFileIds.length} selected file(s)? They will be kept '
        'in Deletion Backups for $retentionDays days.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete to Backup'),
        ),
      ],
    ),
  );

  if (confirmed == true && mounted) {
    final deletedCount = _selectedFileIds.length;

    setState(() {
      final selectedFiles = _files
          .where((file) => _selectedFileIds.contains(file.id))
          .toList();
      _createBackups(selectedFiles);
      _files.removeWhere((file) => _selectedFileIds.contains(file.id));
      _selectedFileIds.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$deletedCount file(s) moved to backups. They can be recovered for '
          '$retentionDays days.',
        ),
      ),
    );
  }
}


  void _removeFile(GarbageFile file) {
    setState(() {
      _createBackups([file]);
      _files.removeWhere((item) => item.id == file.id);
      _selectedFileIds.remove(file.id);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${file.name} backed up for $retentionDays days.'),
      ),
    );
  }

  void _clearStorage() {
    final count = _files.length;
    setState(() {
      _createBackups(_files.toList());
      _files.clear();
      _selectedFileIds.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$count file(s) moved to backups for $retentionDays days.',
        ),
      ),
    );
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
    final remaining = storageLimit - _usedStorage;

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
                'Collect unwanted files, compress them when possible, '
                'and manage the space they occupy.',
              ),
              const SizedBox(height: 20),

              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth < 550 ? 1 : 3;

                  return GridView.count(
                    crossAxisCount: columns,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: columns == 1 ? 3.0 : 1.5,
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
                        '${_files.length}',
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
                        'Storage Capacity',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: _storagePercentage.clamp(0.0, 1.0),
                        minHeight: 12,
                        backgroundColor: Colors.grey.shade200,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${_formatSize(_usedStorage)} used of '
                        '${_formatSize(storageLimit)}',
                      ),
                      Text(
                        '${_formatSize(remaining)} remaining',
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
                    onPressed: _isAddingFile ? null : _addFiles,
                    icon: _isAddingFile
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.add),
                    label: Text(
                      _isAddingFile ? 'Collecting...' : 'Collect Files',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _files.isEmpty ? null : _clearStorage,
                    icon: const Icon(Icons.delete_sweep),
                    label: const Text('Move All to Backups'),
                  ),
                  
                  
                  OutlinedButton.icon(
                    onPressed: _files.isEmpty ? null : _selectAllFiles,
                    icon: const Icon(Icons.select_all),
                    label: Text(
                      _selectedFileIds.length == _files.length
                          ? 'Deselect All'
                          : 'Select All',
                    ),
                  ),

                  FilledButton.icon(
                    onPressed: _selectedFileIds.isEmpty
                        ? null
                        : _deleteSelectedFiles,
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

              if (_files.isEmpty)
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
                          Text('Select files to begin collecting garbage.'),
                        ],
                      ),
                    ),
                  ),
                )
              else
                ..._files.map(
                  (file) => Card(
                    child: ListTile(
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: _selectedFileIds.contains(file.id),
                            onChanged: (selected) {
                              _toggleFileSelection(file, selected ?? false);
                            },
                          ),
                        Icon(
                        file.compressed
                            ? Icons.folder_zip
                            : Icons.insert_drive_file,
                        color: file.compressed
                            ? Colors.green
                            : Colors.blueGrey,
                          ),
                        ],
                      ),
                      
                       
                      title: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'Original: ${_formatSize(file.originalSize)}\n'
                        'Stored: ${_formatSize(file.storedSize)}'
                        '${file.compressed ? " • Compressed" : " • Original retained"}',
                      ),
                      isThreeLine: true,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Optimize File',
                            icon: const Icon(Icons.tune),
                            onPressed: () => _optimizeFile(file),
                          ),
                          IconButton(
                            tooltip: 'Restore File',
                            icon: const Icon(Icons.restore),
                            onPressed: () => _confirmRecovery(
                              file,
                              fromBackup: false,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Delete to 30-day backup',
                            icon: const Icon(Icons.close),
                            onPressed: () => _removeFile(file),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 24),
              Text(
                'Deletion Backups (${_backups.length})',
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (_backups.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: Text('No deletion backups available.')),
                  ),
                )
              else
                ..._backups.map(
                  (backup) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.backup, color: Colors.orange),
                      title: Text(
                        backup.file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'Deleted: ${_formatDateTime(backup.deletedAt)}\n'
                        'Expires: ${_formatDateTime(backup.expiresAt)}',
                      ),
                      isThreeLine: true,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Recover Backup',
                            icon: const Icon(Icons.restore),
                            onPressed: () => _confirmRecovery(
                              backup.file,
                              fromBackup: true,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Permanently Delete Backup',
                            icon: const Icon(Icons.delete_forever),
                            onPressed: () => _permanentlyDeleteBackup(backup),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 24),
              Text(
                'Recovered Files (${_recoveredFiles.length})',
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (_recoveredFiles.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: Text('No files have been recovered yet.')),
                  ),
                )
              else
                ..._recoveredFiles.map(
                  (file) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.check_circle, color: Colors.green),
                      title: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_formatSize(file.originalSize)} • '
                        '${file.doNotCollect ? 'Do Not Collect' : 'Not marked Do Not Collect'}',
                      ),
                      trailing: IconButton(
                        tooltip: 'Download Recovered File',
                        icon: const Icon(Icons.download),
                        onPressed: () => _downloadRecoveredFile(file),
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
                'Files are stored temporarily in memory and are cleared '
                'when the page is refreshed or closed. Backups therefore remain available '
                'for up to 30 days only while this page session stays open.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
