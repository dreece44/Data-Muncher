import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

/// Runs only the screenshot deep scan (with the empty & unreadable checks
/// it relies on) on a folder, simulating a phone. Pointed at a test area (a
/// folder with `expected.json` and `files/`), it also checks every result
/// against the expectations.
///
/// Exit codes: 0 done / all expectations met, 1 expectations failed,
/// 2 storage access not granted, 64 bad usage.
Future<void> main(List<String> arguments) async {
  const defaults = ScreenshotRules();
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
        help: 'Switch off a rule (e.g. --disable S04). Repeatable.')
    ..addOption('blank-share',
        valueHelp: '0-1',
        help: 'Share of one colour for S05/S06 (default '
            '${defaults.blankShare}).')
    ..addOption('ui-share',
        valueHelp: '0-1',
        help: "Share an app's background must cover for S04 (default "
            '${defaults.uiDominantShare}).')
    ..addOption('recent-days',
        valueHelp: 'DAYS',
        help: 'Hold back screenshots newer than this (default '
            '${defaults.recentWindow.inDays}; 0 flags them all).')
    ..addOption('grace-minutes',
        valueHelp: 'MIN',
        help: "Empty & unreadable checks: don't judge files modified this "
            'recently (default 10).')
    ..addFlag('evidence',
        negatable: false,
        help: 'Show the signals and measurements behind each finding.')
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

  final disabled = <ScreenshotRule>{};
  for (final code in args.multiOption('disable')) {
    final rule = ScreenshotRule.byCode(code.toUpperCase());
    if (rule == null) return _usage(parser, 'Unknown rule: $code');
    disabled.add(rule);
  }
  num? number(String option) {
    final text = args.option(option);
    return text == null ? null : num.tryParse(text);
  }

  for (final option in [
    'blank-share',
    'ui-share',
    'recent-days',
    'grace-minutes'
  ]) {
    if (args.option(option) != null && number(option) == null) {
      return _usage(parser, '--$option needs a number');
    }
  }
  final ScreenshotRules rules;
  try {
    rules = ScreenshotRules(
      blankShare: number('blank-share')?.toDouble() ?? defaults.blankShare,
      uiDominantShare:
          number('ui-share')?.toDouble() ?? defaults.uiDominantShare,
      recentWindow: number('recent-days') == null
          ? defaults.recentWindow
          : Duration(hours: (number('recent-days')! * 24).round()),
      minConfidence: Confidence.values.byName(args.option('min-confidence')!),
      disabledRules: disabled,
    );
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

  final ScreenshotResult result;
  try {
    result = await ScreenshotScan(
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
    stdout.write(
        result.format(relativeTo: folder, showEvidence: args.flag('evidence')));
  }

  if (manifest != null) {
    final outcomes =
        verifyScreenshots(result, readExpectedScreenshots(manifest), folder);
    if (!args.flag('json')) {
      stdout
        ..writeln()
        ..writeln('Checking against ${p.relative(manifest)}')
        ..writeln()
        ..write(formatScreenshotVerification(outcomes));
    }
    exitCode = allScreenshotExpectationsMet(outcomes) ? 0 : 1;
  }
}

void _usage(ArgParser parser, [String? error]) {
  if (error != null) stderr.writeln('Error: $error\n');
  stderr
    ..writeln('Usage: dart run deep_scans:screenshot_scan <folder> [options]\n')
    ..writeln('Runs only the screenshot deep scan on <folder>, as if it were '
        "a phone's storage.\n")
    ..writeln(parser.usage);
  exitCode = 64;
}
