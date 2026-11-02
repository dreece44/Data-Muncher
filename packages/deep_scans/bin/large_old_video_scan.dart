import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

/// Runs only the large & old video deep scan (with the empty & unreadable
/// checks it relies on) on a folder, simulating a phone. Pointed at a test
/// area (a folder with `expected.json` and `files/`), it scales its size
/// thresholds to the area and checks every result against the
/// expectations.
///
/// Exit codes: 0 done / all expectations met, 1 expectations failed,
/// 2 storage access not granted, 64 bad usage.
Future<void> main(List<String> arguments) async {
  const defaults = LargeOldVideoRules();
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
    ..addOption('size-scale',
        valueHelp: 'N',
        help: 'Divide size thresholds by N (storage built at 1/N of real '
            'size). Read from expected.json for a test area.')
    ..addOption('min-confidence',
        allowed: ['certain', 'likely'],
        defaultsTo: 'likely',
        help: 'Hide findings with less confidence than this.')
    ..addMultiOption('disable',
        valueHelp: 'RULE',
        help: 'Switch off a rule (e.g. --disable V12). Repeatable.')
    ..addOption('large-mb',
        valueHelp: 'MB',
        help: 'V10/V13 threshold, before scaling (default '
            '${defaults.largeBytes ~/ (1024 * 1024)}).')
    ..addOption('huge-mb',
        valueHelp: 'MB',
        help: 'V11 threshold, before scaling (default '
            '${defaults.hugeBytes ~/ (1024 * 1024)}).')
    ..addOption('old-days',
        valueHelp: 'DAYS',
        help: 'V10/V14 age (default ${defaults.oldAge.inDays}).')
    ..addOption('recent-days',
        valueHelp: 'DAYS',
        help: 'Hold back videos newer than this (default '
            '${defaults.recentWindow.inDays}; 0 flags them all).')
    ..addOption('oversized-bpp',
        valueHelp: 'BITS',
        help: 'V12 bits per pixel per frame, before scaling (default '
            '${defaults.oversizedBitsPerPixel}).')
    ..addOption('grace-minutes',
        valueHelp: 'MIN',
        help: "Don't judge files modified this recently; they may still be "
            'recording (default 10).')
    ..addOption('top',
        valueHelp: 'N', defaultsTo: '10', help: 'Largest videos to list.')
    ..addFlag('evidence',
        negatable: false,
        help: 'Show what each rule saw and what the container says.')
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

  final disabled = <VideoRule>{};
  for (final code in args.multiOption('disable')) {
    final rule = VideoRule.byCode(code.toUpperCase());
    if (rule == null) return _usage(parser, 'Unknown rule: $code');
    disabled.add(rule);
  }
  num? number(String option) {
    final text = args.option(option);
    return text == null ? null : num.tryParse(text);
  }

  for (final option in [
    'size-scale',
    'large-mb',
    'huge-mb',
    'old-days',
    'recent-days',
    'oversized-bpp',
    'grace-minutes',
    'top',
  ]) {
    if (args.option(option) != null && number(option) == null) {
      return _usage(parser, '--$option needs a number');
    }
  }
  final scale = number('size-scale')?.toInt() ??
      (manifest == null ? 1 : readVideoTestAreaScale(manifest));
  int? mb(String option) =>
      number(option) == null ? null : (number(option)! * 1024 * 1024).round();
  Duration? days(String option) => number(option) == null
      ? null
      : Duration(hours: (number(option)! * 24).round());
  final LargeOldVideoRules rules;
  try {
    rules = defaults
        .copyWith(
          largeBytes: mb('large-mb'),
          hugeBytes: mb('huge-mb'),
          oldAge: days('old-days'),
          recentWindow: days('recent-days'),
          oversizedBitsPerPixel: number('oversized-bpp')?.toDouble(),
          minConfidence:
              Confidence.values.byName(args.option('min-confidence')!),
          disabledRules: disabled,
        )
        .scaledDown(scale < 1 ? 1 : scale);
  } on AssertionError catch (e) {
    return _usage(parser, 'Out of range: ${e.message}');
  }
  final grace = number('grace-minutes');
  final healthRules = grace == null
      ? const EmptyUnreadableRules()
      : EmptyUnreadableRules(
          recentlyModifiedGrace: Duration(minutes: grace.round()));

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

  final LargeOldVideoResult result;
  try {
    result = await LargeOldVideoScan(
            device: device, rules: rules, healthRules: healthRules)
        .run(onProgress: (progress) {
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
        top: number('top')!.toInt()));
  }

  if (manifest != null) {
    final verification =
        verifyVideos(result, readExpectedVideos(manifest), folder);
    if (!args.flag('json')) {
      stdout
        ..writeln()
        ..writeln('Checking against ${p.relative(manifest)}')
        ..writeln()
        ..write(formatVideoVerification(verification));
    }
    exitCode = verification.passed ? 0 : 1;
  }
}

void _usage(ArgParser parser, [String? error]) {
  if (error != null) stderr.writeln('Error: $error\n');
  stderr
    ..writeln(
        'Usage: dart run deep_scans:large_old_video_scan <folder> [options]\n')
    ..writeln('Runs only the large & old video deep scan on <folder>, as if '
        "it were a phone's storage.\n")
    ..writeln(parser.usage);
  exitCode = 64;
}
