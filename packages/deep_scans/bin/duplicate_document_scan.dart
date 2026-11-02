import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:path/path.dart' as p;
import 'package:scan_engine/scan_engine.dart';

/// Runs only the duplicate document deep scan (with the empty & unreadable
/// checks it relies on) on a folder, simulating a phone. Pointed at a test
/// area (a folder with `expected.json` and `files/`), it also checks the
/// groups and left-out documents against the expectations.
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
        help: 'Drop group members related to the kept document with less '
            'confidence than this.')
    ..addMultiOption('disable',
        valueHelp: 'RULE',
        help: 'Switch off a rule (e.g. --disable F04). Repeatable.')
    ..addOption('grace-minutes',
        defaultsTo: '10',
        help: "Minutes a just-modified file is left alone (it may still be "
            'downloading).')
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

  final disabled = <DocumentRule>{};
  for (final code in args.multiOption('disable')) {
    final rule = DocumentRule.byCode(code.toUpperCase());
    if (rule == null) return _usage(parser, 'Unknown rule: $code');
    disabled.add(rule);
  }
  final grace = int.tryParse(args.option('grace-minutes')!);
  if (grace == null || grace < 0) {
    return _usage(parser, '--grace-minutes must be a whole number');
  }

  final permissions = StaticPermissionService();
  if (args.flag('grant-access')) {
    permissions
      ..set(ScanPermission.storage, PermissionState.granted)
      ..set(ScanPermission.photos, PermissionState.granted);
  }
  final now = DateTime.now();

  final DuplicateDocumentResult result;
  try {
    result = await DuplicateDocumentScan(
      device: LocalDeviceAdapter(
        root: folder,
        permissions: permissions,
        simulate: args.option('simulate') == 'ios'
            ? DevicePlatform.ios
            : DevicePlatform.android,
      ),
      rules: DuplicateDocumentRules(
        minConfidence: Confidence.values.byName(args.option('min-confidence')!),
        disabledRules: disabled,
      ),
      healthRules:
          EmptyUnreadableRules(recentlyModifiedGrace: Duration(minutes: grace)),
      clock: () => now,
    ).run(onProgress: (progress) {
      if (progress.category == documentCategoryStandIn &&
          progress.total > 0 &&
          (progress.done == progress.total || progress.done % 10 == 0)) {
        stderr.write('\rReading documents ${progress.done}/${progress.total}');
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
    final (groups, singles, health) = readExpectedDocuments(manifest);
    final score = GroupScore(groups, singles, documentGroups(result, folder));
    final healthOutcomes = verifyHealth(result, health, folder,
        now: now.add(Duration(minutes: 10 - grace)));
    if (!args.flag('json')) {
      stdout
        ..writeln()
        ..writeln('Checking against ${p.relative(manifest)}')
        ..writeln()
        ..write(formatDocumentVerification(score, healthOutcomes));
    }
    exitCode = allDocumentExpectationsMet(score, healthOutcomes) ? 0 : 1;
  }
}

void _usage(ArgParser parser, [String? error]) {
  if (error != null) stderr.writeln('Error: $error\n');
  stderr
    ..writeln('Usage: dart run deep_scans:duplicate_document_scan <folder> '
        '[options]\n')
    ..writeln('Runs only the duplicate document deep scan on <folder>, as if '
        "it were a phone's storage. Images are left to the duplicate photo "
        'scan.\n')
    ..writeln(parser.usage);
  exitCode = 64;
}
