import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

/// Runs only the blurry photo deep scan (with the empty & unreadable checks
/// it relies on) on a folder, simulating a phone. Pointed at a test area (a
/// folder with `expected.json` and `files/`), it also checks every result
/// against the expectations.
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
    ..addOption('min-confidence',
        allowed: ['certain', 'likely'],
        defaultsTo: 'likely',
        help: 'Hide findings with less confidence than this.')
    ..addMultiOption('disable',
        valueHelp: 'RULE',
        help: 'Switch off a rule (e.g. --disable B04). Repeatable.')
    ..addOption('blurry-width',
        valueHelp: 'PX',
        help: 'Override the B02 threshold (default '
            '${const BlurryPhotoRules().blurryWidth}).')
    ..addOption('severe-width',
        valueHelp: 'PX',
        help: 'Override the B01 threshold (default '
            '${const BlurryPhotoRules().severeWidth}).')
    ..addOption('analysis-size',
        valueHelp: 'PX',
        help: 'Thumbnail side photos are measured at (default '
            '${const BlurryPhotoRules().analysisSize}).')
    ..addOption('top',
        valueHelp: 'N', defaultsTo: '10', help: 'Blurriest photos to list.')
    ..addFlag('evidence',
        negatable: false, help: 'Show the measurements behind each finding.')
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

  final disabled = <BlurRule>{};
  for (final code in args.multiOption('disable')) {
    final rule = BlurRule.byCode(code.toUpperCase());
    if (rule == null) return _usage(parser, 'Unknown rule: $code');
    disabled.add(rule);
  }
  num? number(String option) {
    final text = args.option(option);
    return text == null ? null : num.tryParse(text);
  }

  for (final option in [
    'blurry-width',
    'severe-width',
    'analysis-size',
    'top'
  ]) {
    if (args.option(option) != null && number(option) == null) {
      return _usage(parser, '--$option needs a number');
    }
  }
  const defaults = BlurryPhotoRules();
  final BlurryPhotoRules rules;
  try {
    rules = BlurryPhotoRules(
      blurryWidth: number('blurry-width')?.toDouble() ?? defaults.blurryWidth,
      severeWidth: number('severe-width')?.toDouble() ?? defaults.severeWidth,
      analysisSize: number('analysis-size')?.toInt() ?? defaults.analysisSize,
      minConfidence: Confidence.values.byName(args.option('min-confidence')!),
      disabledRules: disabled,
    );
  } on AssertionError catch (e) {
    return _usage(parser, 'Thresholds out of order: ${e.message}');
  }

  final permissions = StaticPermissionService();
  if (args.flag('grant-access')) {
    permissions
      ..set(ScanPermission.storage, PermissionState.granted)
      ..set(ScanPermission.photos, PermissionState.granted);
  }
  final device = LocalDeviceAdapter(
    root: folder,
    permissions: permissions,
    simulate: args.option('simulate') == 'ios'
        ? DevicePlatform.ios
        : DevicePlatform.android,
  );

  final BlurryPhotoResult result;
  try {
    result = await BlurryPhotoScan(device: device, rules: rules).run(
        onProgress: (progress) {
      if (progress.total > 0 &&
          (progress.done == progress.total || progress.done % 10 == 0)) {
        stderr.write('\rChecking ${progress.category?.label.toLowerCase()} '
            '${progress.done}/${progress.total}   ');
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

  if (args.flag('json')) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result.toJson()));
  } else {
    stdout.write(result.format(
        relativeTo: folder,
        showEvidence: args.flag('evidence'),
        rankingSize: number('top')?.toInt() ?? 10));
  }

  if (manifest != null) {
    final (expected, order) = readExpectedPhotos(manifest);
    final outcomes = verifyBlurryPhotos(result, expected, folder);
    final rankingOk = rankingFollows(result, order, folder);
    if (!args.flag('json')) {
      stdout
        ..writeln()
        ..writeln('Checking against ${p.relative(manifest)}')
        ..writeln()
        ..write(formatBlurryVerification(outcomes,
            rankingOrder: order, rankingOk: rankingOk));
    }
    exitCode = allBlurryExpectationsMet(outcomes, rankingOk: rankingOk) ? 0 : 1;
  }
}

void _usage(ArgParser parser, [String? error]) {
  if (error != null) stderr.writeln('Error: $error\n');
  stderr
    ..writeln('Usage: dart run deep_scans:blurry_photo_scan <folder> '
        '[options]\n')
    ..writeln('Runs only the blurry photo deep scan on <folder>, as if it '
        "were a phone's storage.\n")
    ..writeln(parser.usage);
  exitCode = 64;
}
