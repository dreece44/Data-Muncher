import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:scan_engine/scan_engine.dart';

/// Runs the scan engine on a folder, simulating a phone. See README.md.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('grant-access',
        negatable: false,
        help: 'Simulate the user granting storage access. Without this the '
            'scan refuses to run, just as it would on a phone.')
    ..addFlag('limited',
        negatable: false,
        help: 'With --grant-access: grant limited access (iOS "Selected '
            'Photos") instead of full access.')
    ..addOption('simulate',
        allowed: ['android', 'ios'],
        defaultsTo: 'android',
        help: "Which phone's permission rules to follow.")
    ..addOption('apps',
        valueHelp: 'apps.json',
        help: 'Installed apps with usage history, for unused-app detection.')
    ..addFlag('grant-usage-access',
        negatable: false,
        help: 'Simulate granting Android "Usage access" (needed with --apps).')
    ..addFlag('json', negatable: false, help: 'Print the full report as JSON.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    _usage(parser, e.message);
    return;
  }
  if (args.flag('help')) {
    _usage(parser);
    exitCode = 0;
    return;
  }
  if (args.rest.length != 1) {
    _usage(parser, 'Give exactly one folder to scan.');
    return;
  }
  final folder = Directory(args.rest.single).absolute.path;
  if (!Directory(folder).existsSync()) {
    _usage(parser, 'Folder not found: $folder');
    return;
  }

  final simulate = args.option('simulate') == 'ios'
      ? DevicePlatform.ios
      : DevicePlatform.android;
  final permissions = StaticPermissionService();
  if (args.flag('grant-access')) {
    final state = args.flag('limited')
        ? PermissionState.limited
        : PermissionState.granted;
    permissions
      ..set(ScanPermission.storage, state)
      ..set(ScanPermission.photos, state);
  }
  if (args.flag('grant-usage-access')) {
    permissions.set(ScanPermission.appUsage, PermissionState.granted);
  }
  final appsFile = args.option('apps');

  final engine = ScanEngine(
    device: LocalDeviceAdapter(
      root: folder,
      permissions: permissions,
      simulate: simulate,
      apps: appsFile == null ? null : JsonAppInventory(File(appsFile)),
    ),
  );

  WasteCategory? lastCategory;
  try {
    final report = await engine.scan(onProgress: (progress) {
      if (progress.category != lastCategory && progress.category != null) {
        lastCategory = progress.category;
        stderr.writeln('Checking ${lastCategory!.label.toLowerCase()}…');
      }
    });
    if (args.flag('json')) {
      stdout
          .writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    } else {
      stdout.write(formatReport(report, relativeTo: folder));
    }
  } on PermissionDeniedException catch (e) {
    stderr
      ..writeln('Scan refused: storage access has not been granted.')
      ..writeln('  ${e.missing.keys.map((p) => p.label).join(', ')} missing.')
      ..writeln('  On a phone the user grants this in the app; here, pass '
          '--grant-access to simulate it.');
    exitCode = 2;
  }
}

void _usage(ArgParser parser, [String? error]) {
  if (error != null) stderr.writeln('Error: $error\n');
  stderr
    ..writeln('Usage: dart run scan_engine:scan <folder> [options]\n')
    ..writeln('Scans <folder> as if it were a phone\'s storage.\n')
    ..writeln(parser.usage);
  exitCode = 64;
}
