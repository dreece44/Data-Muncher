
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

  GarbageFile({
    required this.id,
    required this.name,
    required this.originalSize,
    required this.storedBytes,
    required this.compressed,
  });

  int get storedSize => storedBytes.length;
  int get spaceSaved => originalSize - storedSize;
}

class GarbageStoragePage extends StatefulWidget {
  const GarbageStoragePage({super.key});

  @override
  State<GarbageStoragePage> createState() => _GarbageStoragePageState();
}

class _GarbageStoragePageState extends State<GarbageStoragePage> {
  
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

  final List<GarbageFile> _files = [];
  bool _isAddingFile = false;
  //track files selected for bulk deletion
  final Set<String> _selectedFileIds = {};

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
        '${_selectedFileIds.length} selected file(s)?',
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

  if (confirmed == true && mounted) {
    final deletedCount = _selectedFileIds.length;

    setState(() {
      _files.removeWhere(
        (file) => _selectedFileIds.contains(file.id),
      );

      _selectedFileIds.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$deletedCount file(s) deleted successfully.'),
      ),
    );
  }
}


  void _removeFile(GarbageFile file) {
    setState(() {
      _files.removeWhere((item) => item.id == file.id);
      _selectedFileIds.remove(file.id);
    });
  }


  void _clearStorage() {
    setState(() {
      _files.clear();
      _selectedFileIds.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Garbage storage cleared.')),
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
                    label: const Text('Empty Storage'),
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
                            tooltip: 'Remove File',
                            icon: const Icon(Icons.close),
                            onPressed: () => _removeFile(file),
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
                'Files are stored temporarily in memory and are cleared '
                'when the page is refreshed or closed.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
