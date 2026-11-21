import 'package:flutter/material.dart';
import 'package:scan_engine_flutter/scan_engine_flutter.dart';

/// Bare developer screen for trying the scan engine by hand on a device:
/// request each permission, run a scan, read the text report. Not the
/// product UI.
void main() => runApp(const MaterialApp(home: ScanHarness()));

class ScanHarness extends StatefulWidget {
  const ScanHarness({super.key});

  @override
  State<ScanHarness> createState() => _ScanHarnessState();
}

class _ScanHarnessState extends State<ScanHarness> {
  DeviceAdapter? _device;
  String _log = 'Tap a permission to request it, then Scan.';
  bool _busy = false;

  Future<DeviceAdapter> _deviceAdapter() async =>
      _device ??= await currentDevice();

  Future<void> _run(Future<String> Function() action) async {
    setState(() => _busy = true);
    String output;
    try {
      output = await action();
    } catch (e) {
      output = 'Error: $e';
    }
    setState(() {
      _busy = false;
      _log = output;
    });
  }

  Future<String> _request(ScanPermission permission) async {
    final device = await _deviceAdapter();
    final state = await device.permissions.request(permission);
    return '${permission.label}: ${state.name}';
  }

  Future<String> _scan() async {
    final engine = ScanEngine(device: await _deviceAdapter());
    try {
      return formatReport(
        await engine.scan(
          onProgress: (p) {
            if (mounted) setState(() => _log = p.toString());
          },
        ),
      );
    } on PermissionDeniedException catch (e) {
      return 'Scan refused.\n\n$e';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan engine harness')),
      body: Column(
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final permission in ScanPermission.values)
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() => _request(permission)),
                  child: Text(permission.label),
                ),
              FilledButton(
                onPressed: _busy ? null : () => _run(_scan),
                child: const Text('Scan'),
              ),
            ],
          ),
          const Divider(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _log,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
