import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

/// Runs only the empty & unreadable deep scan on a folder, simulating a
/// phone. Pointed at a test area (a folder with `expected.json` and
/// `files/`), it also checks every result against the expectations.
///
/// Exit codes: 0 done / all expectations met, 1 expectations failed,
/// 2 storage access not granted, 64 bad usage.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('grant-access',
        negatable: false,
        help: 'Simulate the user granting storage access. Without this the '
            'scan refuses to run, just as it would on a phone.')
    ..addOption('simulate',
        allowed: ['android', 'ios'],
        defaultsTo: 'android',
        help: "Which phone's permission rules to follow.")
    ..addOption('verify',
        valueHelp: 'expected.json',
        help: 'Check results against a test-area manifest. Automatic when '
            'the folder is a test area.')
    ..addFlag('compare',
        negatable: false,
        help: "Also run the mass scan's EmptyFileDetector and "
            'UnreadableFileDetector on the same files and compare.')
    ..addOption('min-confidence',
        allowed: ['certain', 'likely'],
        defaultsTo: 'likely',
        help: 'Drop findings below this confidence.')
    ..addOption('grace-minutes',
        defaultsTo: '10',
        help: 'Hold back "still being written" findings for files modified '
            'this recently. Use 0 for freshly copied test folders.')
    ..addMultiOption('disable',
        valueHelp: 'RULE',
        help: 'Switch off a rule (e.g. --disable E03). Repeatable.')
    ..addFlag('evidence',
        negatable: false, help: 'Show what each rule actually saw.')
    ..addFlag('json', negatable: false, help: 'Print the result as JSON.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    return _usage(parser, e.message);
  }
  if (args.flag('help')) {
    _usage(parser);
    exitCode = 0;
    return;
  }
  if (args.rest.length != 1) {
    return _usage(parser, 'Give exactly one folder to scan.');
  }

  var folder = p.absolute(args.rest.single);
  var manifest = args.option('verify');
  if (manifest == null &&
      File(p.join(folder, 'expected.json')).existsSync() &&
      Directory(p.join(folder, 'files')).existsSync()) {
    manifest = p.join(folder, 'expected.json');
    folder = p.join(folder, 'files');
  }
  if (!Directory(folder).existsSync()) {
    return _usage(parser, 'Folder not found: $folder');
  }

  final disabled = <DeepRule>{};
  for (final code in args.multiOption('disable')) {
    final rule = DeepRule.byCode(code.toUpperCase());
    if (rule == null) return _usage(parser, 'Unknown rule: $code');
    disabled.add(rule);
  }

  final grace = int.tryParse(args.option('grace-minutes')!);
  if (grace == null || grace < 0) {
    return _usage(parser, '--grace-minutes must be a whole number ≥ 0');
  }

  final permissions = StaticPermissionService();
  if (args.flag('grant-access')) {
    permissions
      ..set(ScanPermission.storage, PermissionState.granted)
      ..set(ScanPermission.photos, PermissionState.granted);
  }
  DeviceAdapter device() => LocalDeviceAdapter(
        root: folder,
        permissions: permissions,
        simulate: args.option('simulate') == 'ios'
            ? DevicePlatform.ios
            : DevicePlatform.android,
      );

  final now = DateTime.now();
  final DeepScanResult result;
  try {
    result = await EmptyUnreadableScan(
      device: device(),
      clock: () => now,
      rules: EmptyUnreadableRules(
        minConfidence: Confidence.values.byName(args.option('min-confidence')!),
        disabledRules: disabled,
        recentlyModifiedGrace: Duration(minutes: grace),
      ),
    ).run();
  } on PermissionDeniedException catch (e) {
    stderr
      ..writeln('Scan refused: storage access has not been granted.')
      ..writeln('  ${e.missing.keys.map((p) => p.label).join(', ')} missing.')
      ..writeln('  On a phone the user grants this in the app; here, pass '
          '--grant-access to simulate it.');
    exitCode = 2;
    return;
  }

  final mass = args.flag('compare') ? await massScanFindings(device()) : null;

  if (args.flag('json')) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      ...result.toJson(),
      if (mass != null)
        'massScan': {
          for (final e in mass.entries)
            e.key: {'category': e.value.category.name, 'reason': e.value.reason}
        },
    }));
  } else {
    stdout.write(
        result.format(relativeTo: folder, showEvidence: args.flag('evidence')));
    if (mass != null && manifest == null) {
      _printComparison(result, mass, folder);
    }
  }

  if (manifest != null) {
    final outcomes = verify(result, readExpectedCases(manifest),
        root: folder, now: now, massScan: mass);
    if (!args.flag('json')) {
      stdout
        ..writeln('Checking against ${p.relative(manifest)}')
        ..writeln()
        ..write(formatVerification(outcomes, compared: mass != null));
    }
    exitCode = outcomes.every((o) => o.passed) ? 0 : 1;
  }
}

void _printComparison(
    DeepScanResult result, Map<String, Finding> mass, String root) {
  String rel(String id) => p.relative(id, from: root).replaceAll(r'\', '/');
  final deep = {for (final v in result.verdicts) v.item.id: v};
  final ids = {...deep.keys, ...mass.keys}.toList()..sort();
  final differences = [
    for (final id in ids)
      if (deep[id]?.category != mass[id]?.category) id
  ];
  stdout.writeln('Compared with the mass scan: ${differences.length} '
      'difference(s)');
  for (final id in differences) {
    stdout.writeln('  ${rel(id)}');
    stdout.writeln(
        '    deep: ${deep[id] == null ? 'clean' : '${deep[id]!.rule.code} ${deep[id]!.reason}'}');
    stdout.writeln(
        '    mass: ${mass[id] == null ? 'clean' : '${mass[id]!.category.name} ${mass[id]!.reason}'}');
  }
}

void _usage(ArgParser parser, [String? error]) {
  if (error != null) stderr.writeln('Error: $error\n');
  stderr
    ..writeln('Usage: dart run deep_scans:empty_unreadable_scan <folder> '
        '[options]\n')
    ..writeln('Runs only the empty & unreadable deep scan on <folder>, as if '
        "it were a phone's storage.\n")
    ..writeln(parser.usage);
  exitCode = 64;
}
