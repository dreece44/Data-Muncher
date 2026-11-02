// Sets up the Android and iOS folders DataMuncher needs.
//
// Run from the project folder (the one with pubspec.yaml):
//
//   dart run tool/setup_platforms.dart
//
// Safe to run again: it only adds what's missing. It
//   1. runs `flutter create` if android/ or ios/ is missing,
//   2. removes Flutter's sample test (it looks for a MyApp that doesn't exist),
//   3. adds photo, usage-access and uninstall permissions to Android,
//   4. installs MainActivity.kt (unused app detection, DAT-25),
//   5. adds the photo library messages iPhone requires to Info.plist.

import 'dart:io';

const _manifestPath = 'android/app/src/main/AndroidManifest.xml';
const _plistPath = 'ios/Runner/Info.plist';
const _activityTemplate = 'tool/android/MainActivity.kt';

const _permissions = {
  'android.permission.READ_EXTERNAL_STORAGE':
      '<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />',
  'android.permission.READ_MEDIA_IMAGES':
      '<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />',
  'android.permission.READ_MEDIA_VIDEO':
      '<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />',
  // Unused apps (DAT-25): when each app was last opened.
  'android.permission.PACKAGE_USAGE_STATS':
      '<uses-permission android:name="android.permission.PACKAGE_USAGE_STATS" tools:ignore="ProtectedPermissions" />',
  // Unused apps (DAT-25): show Android's uninstall dialog.
  'android.permission.REQUEST_DELETE_PACKAGES':
      '<uses-permission android:name="android.permission.REQUEST_DELETE_PACKAGES" />',
};

const _queriesMarker = '<!-- DataMuncher: apps it may list (DAT-25) -->';
const _queryIntents = '''
        $_queriesMarker
        <intent>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LAUNCHER" />
        </intent>
        <intent>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.HOME" />
        </intent>''';

const _plistEntries = {
  'NSPhotoLibraryUsageDescription':
      'DataMuncher scans your photos to find duplicates and blurry shots.',
  'NSPhotoLibraryAddUsageDescription':
      'DataMuncher needs this to restore or remove photos.',
};

Future<void> main() async {
  if (!File('pubspec.yaml').existsSync() || !File(_activityTemplate).existsSync()) {
    _fail('Run this from the DataMuncher project folder (the one with '
        'pubspec.yaml and tool/), e.g.\n'
        '  cd ~/Data-Muncher/dat-27-28-flutter\n'
        '  dart run tool/setup_platforms.dart');
  }

  await _createPlatformFolders();
  _removeSampleTest();
  _patchManifest();
  _installMainActivity();
  _patchInfoPlist();

  stdout.writeln('\nDone. Next:\n'
      '  flutter pub get\n'
      '  flutter test\n'
      '  flutter run');
}

Future<void> _createPlatformFolders() async {
  if (Directory('android').existsSync() && Directory('ios').existsSync()) {
    _ok('android/ and ios/ already exist');
    return;
  }
  stdout.writeln('Running flutter create (this can take a minute)...');
  final result = await Process.run(
    'flutter',
    ['create', '--project-name', 'datamuncher', '--platforms=android,ios', '.'],
    runInShell: true,
  );
  stdout.write(result.stdout);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    _fail('flutter create failed. Check that `flutter doctor` works.');
  }
  _ok('Created android/ and ios/');
}

void _removeSampleTest() {
  final sample = File('test/widget_test.dart');
  if (sample.existsSync() && sample.readAsStringSync().contains('MyApp')) {
    sample.deleteSync();
    _ok("Removed Flutter's sample test/widget_test.dart");
  }
}

void _patchManifest() {
  final file = File(_manifestPath);
  if (!file.existsSync()) _fail('Missing $_manifestPath');
  var xml = file.readAsStringSync();
  final original = xml;

  if (!xml.contains('xmlns:tools=')) {
    xml = xml.replaceFirst(
        '<manifest ', '<manifest xmlns:tools="http://schemas.android.com/tools" ');
  }

  final missing = [
    for (final entry in _permissions.entries)
      if (!xml.contains('"${entry.key}"')) entry.value,
  ];
  if (missing.isNotEmpty) {
    final at = xml.indexOf('<application');
    if (at < 0) _fail('Unexpected $_manifestPath: no <application> tag');
    xml = xml.replaceRange(
        at, at, '${missing.join('\n    ')}\n\n    ');
  }

  if (!xml.contains(_queriesMarker)) {
    final queries = RegExp(r'<queries>').firstMatch(xml);
    if (queries != null) {
      xml = xml.replaceRange(queries.end, queries.end, _queryIntents);
    } else {
      final end = xml.lastIndexOf('</manifest>');
      if (end < 0) _fail('Unexpected $_manifestPath: no </manifest> tag');
      xml = xml.replaceRange(
          end, end, '    <queries>$_queryIntents\n    </queries>\n');
    }
  }

  if (xml == original) {
    _ok('Android permissions already set');
  } else {
    file.writeAsStringSync(xml);
    _ok('Added Android permissions to $_manifestPath');
  }
}

void _installMainActivity() {
  final kotlinRoot = Directory('android/app/src/main/kotlin');
  final javaRoot = Directory('android/app/src/main/java');
  File? target = _find(kotlinRoot, 'MainActivity.kt');
  if (target == null && _find(javaRoot, 'MainActivity.java') != null) {
    _fail('This project uses Java for Android. Delete the android/ folder '
        'and run this script again; it recreates it in Kotlin.');
  }
  if (target == null) _fail('Could not find MainActivity.kt under ${kotlinRoot.path}');

  final current = target.readAsStringSync();
  final package = RegExp(r'^package\s+([\w.]+)', multiLine: true)
      .firstMatch(current)
      ?.group(1);
  if (package == null) _fail('Could not read the package name in ${target.path}');

  final wanted = File(_activityTemplate)
      .readAsStringSync()
      .replaceFirst('__PACKAGE__', package);
  if (current == wanted) {
    _ok('MainActivity.kt already up to date');
  } else {
    target.writeAsStringSync(wanted);
    _ok('Installed unused-app code in ${target.path}');
  }
}

void _patchInfoPlist() {
  final file = File(_plistPath);
  if (!file.existsSync()) {
    _ok('No $_plistPath (skipping iPhone setup)');
    return;
  }
  var plist = file.readAsStringSync();
  final additions = StringBuffer();
  for (final entry in _plistEntries.entries) {
    if (!plist.contains('<key>${entry.key}</key>')) {
      additions.write('\t<key>${entry.key}</key>\n'
          '\t<string>${entry.value}</string>\n');
    }
  }
  if (additions.isEmpty) {
    _ok('iPhone photo messages already set');
    return;
  }
  final end = plist.lastIndexOf('</dict>');
  if (end < 0) _fail('Unexpected $_plistPath: no </dict>');
  plist = plist.replaceRange(end, end, additions.toString());
  file.writeAsStringSync(plist);
  _ok('Added photo library messages to $_plistPath');
}

File? _find(Directory root, String name) {
  if (!root.existsSync()) return null;
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File && entity.uri.pathSegments.last == name) return entity;
  }
  return null;
}

void _ok(String message) => stdout.writeln('✓ $message');

Never _fail(String message) {
  stderr.writeln('✗ $message');
  exit(1);
}
