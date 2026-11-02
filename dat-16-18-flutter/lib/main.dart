import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'models.dart';
import 'muncher.dart';

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

class MunchHome extends StatefulWidget {
  const MunchHome({super.key});

  @override
  State<MunchHome> createState() => _MunchHomeState();
}

class _MunchHomeState extends State<MunchHome> {
  MunchResult? _result;
  bool _loading = false;
  final _openCategories = <WasteCategory>{};

  Future<void> _scan() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return; // user cancelled the picker

    setState(() => _loading = true);
    final result = munchMyData(path);
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  List<ClassificationResult> _itemsFor(WasteCategory cat) =>
      _result?.items.where((r) => r.category == cat).toList() ?? [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const Text(
                'DATAMUNCHER',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 30,
                  color: Color(0xFF4C8A2E),
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 20),
              _buildRing(),
              const SizedBox(height: 24),
              _categoryButton('DUPLICATES', WasteCategory.duplicate),
              _categoryButton('EMPTY', WasteCategory.empty),
              _disabledButton('BLURRY (not built yet)'),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _scan,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2F6B1A),
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                  child: Text(
                    _loading
                        ? 'SCANNING…'
                        : _result == null
                            ? 'MUNCH MY DATA'
                            : 'SCAN AGAIN (${_result!.summary.totalFlagged} FLAGGED)',
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
          CircularProgressIndicator(
            value: pct.clamp(0.0, 1.0),
            strokeWidth: 16,
            backgroundColor: const Color(0xFF1C2B13),
            valueColor: const AlwaysStoppedAnimation(Color(0xFF5FAE3D)),
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
            onPressed: () {
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
            constraints: const BoxConstraints(maxHeight: 120),
            decoration: BoxDecoration(border: Border.all(color: const Color(0xFF2A2A28))),
            child: items.isEmpty
                ? const Text('None found.', style: TextStyle(color: Color(0xFF9C9C98), fontSize: 12))
                : ListView(
                    shrinkWrap: true,
                    children: items
                        .map((r) => Text(
                              r.file.path,
                              style: const TextStyle(color: Color(0xFF9C9C98), fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ))
                        .toList(),
                  ),
          ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _disabledButton(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: null,
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF3A3A38))),
            child: Text(label, style: const TextStyle(color: Color(0xFF5A5A58))),
          ),
        ),
      );
}
