import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'core.dart';
import 'pages.dart';

void main() => runApp(const DataMuncherApp());

class DataMuncherApp extends StatelessWidget {
  const DataMuncherApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'DataMuncher',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(scaffoldBackgroundColor: const Color(0xFF111111)),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final s = MunchState();

  @override
  void initState() {
    super.initState();
    s.init();
  }

  void _open(String title, List<AssetEntity> list, {bool pre = true}) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => ReviewPage(s, title, list, preselect: pre)));

  Future<void> _munch() async {
    if (!s.scanned) await s.scan();
    final map = {for (final a in [...s.duplicates, ...s.empty, ...s.blurry]) a.id: a};
    if (!mounted) return;
    if (map.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing to munch. Storage looks clean!')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Munch my data?'),
        content: Text('Move ${map.length} duplicate, empty and blurry items to the Garbage Bin? You can recover them anytime before emptying.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Munch')),
        ],
      ),
    );
    if (ok == true) {
      await s.collect(map.values);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Munched ${map.length} items. Empty the bin to free space.')));
      }
    }
  }

  Widget _btn(String label, int? count, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(64),
            shape: const RoundedRectangleBorder(),
            side: const BorderSide(color: Colors.white70),
          ),
          child: Text(count == null ? label : '$label ($count)', style: mono.copyWith(fontSize: 20)),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListenableBuilder(
            listenable: s,
            builder: (_, __) => ListView(padding: const EdgeInsets.all(16), children: [
              Row(children: [
                Expanded(
                  child: FittedBox(
                    alignment: Alignment.centerLeft,
                    fit: BoxFit.scaleDown,
                    child: Text('DATAMUNCHER',
                        style: mono.copyWith(color: green, fontSize: 40, fontWeight: FontWeight.w900)),
                  ),
                ),
                IconButton(
                  tooltip: 'Garbage Bin (${s.bin.length})',
                  icon: Badge(label: Text('${s.bin.length}'), isLabelVisible: s.bin.isNotEmpty, child: const Icon(Icons.delete_outline)),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BinPage(s))),
                ),
              ]),
              const SizedBox(height: 20),
              Center(
                child: SizedBox(
                  width: 210,
                  height: 210,
                  child: Stack(alignment: Alignment.center, children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: s.scanning ? s.progress : s.usedFraction,
                        strokeWidth: 16,
                        color: s.usedFraction > 0.9 ? Colors.red.shade700 : const Color(0xFF1E5A12),
                        backgroundColor: const Color(0xFF1A1A1A),
                      ),
                    ),
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(s.scanning ? 'SCANNING' : '${(s.usedFraction * 100).round()}%',
                          style: mono.copyWith(fontSize: s.scanning ? 18 : 46)),
                      if (!s.scanning) Text('${s.freeGb.toStringAsFixed(1)} GB FREE', style: mono.copyWith(fontSize: 12)),
                    ]),
                  ]),
                ),
              ),
              const SizedBox(height: 24),
              if (s.denied)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextButton(
                      onPressed: PhotoManager.openSetting,
                      child: const Text('Photo access is needed. Tap to open settings.')),
                ),
              _btn('DUPLICATES', s.duplicates.length, () => _open('DUPLICATES', s.duplicates)),
              _btn('EMPTY', s.empty.length, () => _open('EMPTY', s.empty)),
              _btn('BLURRY', s.blurry.length, () => _open('BLURRY', s.blurry)),
              Row(children: [
                Expanded(child: _selectTile('IMAGE\nSELECT', () => _open('IMAGES', s.images.toList(), pre: false))),
                const SizedBox(width: 12),
                Expanded(child: _selectTile('VIDEO\nSELECT', () => _open('VIDEOS', s.videos.toList(), pre: false))),
              ]),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: s.scanning ? null : _munch,
                style: FilledButton.styleFrom(
                  backgroundColor: darkGreen,
                  minimumSize: const Size.fromHeight(84),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                child: Text('MUNCH MY DATA', style: mono.copyWith(fontSize: 22)),
              ),
              TextButton(onPressed: s.scanning ? null : s.scan, child: const Text('Rescan storage')),
            ]),
          ),
        ),
      );

  Widget _selectTile(String label, VoidCallback onTap) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(130),
          shape: const RoundedRectangleBorder(),
          side: const BorderSide(color: Colors.white70),
        ),
        child: Text(label, textAlign: TextAlign.center, style: mono.copyWith(fontSize: 22)),
      );
}
