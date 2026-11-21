import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

/// Runs only the duplicate photo deep scan on a folder, simulating a phone.
/// Pointed at a test area (a folder with `expected.json` and `files/`), it
/// also checks the groups against the expectations.
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
        help: 'Check groups against a test-area manifest. Automatic when the '
            'folder is a test area.')
    ..addFlag('compare',
        negatable: false,
        help: "Also run the mass scan's DuplicatePhotoDetector on the same "
            'photos and compare.')
    ..addOption('min-confidence',
        allowed: ['certain', 'likely'],
        defaultsTo: 'likely',
        help: 'Drop group members related to the kept photo with less '
            'confidence than this.')
    ..addMultiOption('disable',
        valueHelp: 'RULE',
        help: 'Switch off a rule (e.g. --disable D06). Repeatable.')
    ..addFlag('evidence',
        negatable: false, help: 'Show the measurements behind each match.')
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

  final disabled = <DuplicateRule>{};
  for (final code in args.multiOption('disable')) {
    final rule = DuplicateRule.byCode(code.toUpperCase());
    if (rule == null) return _usage(parser, 'Unknown rule: $code');
    disabled.add(rule);
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

  final DuplicatePhotoResult result;
  try {
    result = await DuplicatePhotoScan(
      device: device(),
      rules: DuplicatePhotoRules(
        minConfidence: Confidence.values.byName(args.option('min-confidence')!),
        disabledRules: disabled,
      ),
    ).run(onProgress: (progress) {
      if (progress.total > 0 &&
          (progress.done == progress.total || progress.done % 10 == 0)) {
        stderr.write('\rDecoding photos ${progress.done}/${progress.total}');
        if (progress.done == progress.total) stderr.writeln();
      }
    });
  } on PermissionDeniedException catch (e) {
    stderr
      ..writeln('Scan refused: storage access has not been granted.')
      ..writeln('  ${e.missing.keys.map((p) => p.label).join(', ')} missing.')
      ..writeln('  On a phone the user grants this in the app; here, pass '
          '--grant-access to simulate it.');
    exitCode = 2;
    return;
  }

  final mass = args.flag('compare') ? await massScanDuplicates(device()) : null;

  if (args.flag('json')) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      ...result.toJson(),
      if (mass != null) 'massScan': [for (final f in mass) f.toJson()],
    }));
  } else {
    stdout.write(
        result.format(relativeTo: folder, showEvidence: args.flag('evidence')));
    if (mass != null && manifest == null) {
      stdout
        ..writeln()
        ..writeln('Mass scan (DuplicatePhotoDetector) found ${mass.length} '
            'groups:');
      for (final g in massGroups(mass, folder)) {
        stdout.writeln('  keep ${g.keep}: ${g.paths.length} photos');
      }
    }
  }

  if (manifest != null) {
    final (groups, singles) = readExpectedGroups(manifest);
    final deep = GroupScore(groups, singles, deepGroups(result, folder));
    final massScore = mass == null
        ? null
        : GroupScore(groups, singles, massGroups(mass, folder));
    if (!args.flag('json')) {
      stdout
        ..writeln()
        ..writeln('Checking against ${p.relative(manifest)}')
        ..writeln()
        ..write(formatGroupVerification(deep, mass: massScore));
    }
    exitCode = deep.allPassed ? 0 : 1;
  }
}

void _usage(ArgParser parser, [String? error]) {
  if (error != null) stderr.writeln('Error: $error\n');
  stderr
    ..writeln('Usage: dart run deep_scans:duplicate_photo_scan <folder> '
        '[options]\n')
    ..writeln('Runs only the duplicate photo deep scan on <folder>, as if it '
        "were a phone's storage.\n")
    ..writeln(parser.usage);
  exitCode = 64;
}
