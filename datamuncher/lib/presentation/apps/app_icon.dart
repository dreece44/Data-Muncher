import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Loads an app's icon once and keeps it for the rest of the session.
class AppIconCache {
  AppIconCache(this._load);

  final Future<Uint8List?> Function(String packageName) _load;
  final Map<String, Future<Uint8List?>> _icons = {};

  Future<Uint8List?> iconFor(String packageName) =>
      _icons.putIfAbsent(packageName, () async {
        try {
          return await _load(packageName);
        } catch (_) {
          return null;
        }
      });
}

/// An app's icon, or a generic one while it loads or if there is none.
class AppIcon extends StatefulWidget {
  const AppIcon({super.key, required this.packageName, required this.cache});

  final String packageName;
  final AppIconCache cache;

  @override
  State<AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<AppIcon> {
  late Future<Uint8List?> _icon = widget.cache.iconFor(widget.packageName);

  @override
  void didUpdateWidget(AppIcon old) {
    super.didUpdateWidget(old);
    if (old.packageName != widget.packageName) {
      _icon = widget.cache.iconFor(widget.packageName);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _icon,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) {
          final scheme = Theme.of(context).colorScheme;
          return ColoredBox(
            color: scheme.primaryContainer,
            child: Icon(Icons.apps, color: scheme.onPrimaryContainer),
          );
        }
        return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}
