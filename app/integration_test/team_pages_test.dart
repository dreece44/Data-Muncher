import 'dart:io';

import 'package:datamuncher/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Drives the real app on an emulator or phone through the teammates'
/// pages: storage scan → Summary (Storage Scan Results) → By category
/// (Garbage Collection) → Garbage Bin, plus Scan a folder (DAT-16/18) and
/// Garbage storage (DAT-17).
///
/// Needs "All files access" and photo access granted, and the sample phone
/// pushed to /sdcard/TeamTest:
///
///   adb push ../packages/scan_engine/sample_phone /sdcard/TeamTest
///   adb shell appops set com.example.datamuncher MANAGE_EXTERNAL_STORAGE allow
///   flutter test integration_test -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps until [finder] shows up; the scan's spinner never settles.
  Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(minutes: 2)}) async {
    final end = DateTime.now().add(timeout);
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) fail('Timed out waiting for $finder');
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> tapButton(WidgetTester tester, String text) async {
    final button = find.text(text);
    await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Taps the top page's back button. The page underneath has one too
  /// while the transition runs.
  Future<void> goBack(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Back').last);
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('teammates\' pages work inside the app', (tester) async {
    await tester.pumpWidget(const DataMuncherApp());
    await waitFor(tester, find.text('DATAMUNCHER'));
    // The photo scan runs at start-up; wait for it so the buttons settle.
    await waitFor(tester, find.textContaining('GB FREE'));

    // nathangh-ung's DAT-16/18 folder scan.
    await tapButton(tester, 'SCAN A FOLDER');
    await waitFor(tester, find.text('BLURRY (not built yet)'));
    expect(find.text('FOLDER MUNCH'), findsOneWidget);
    expect(find.text('DUPLICATES'), findsWidgets);
    await goBack(tester);

    // coilehayden0's DAT-17 garbage storage.
    await tapButton(tester, 'GARBAGE STORAGE');
    await waitFor(tester, find.text('Temporary Storage Manager'));
    expect(find.text('Collect Files'), findsOneWidget);
    await goBack(tester);

    // Storage scan, then coilehayden0's results page with real numbers.
    await tapButton(tester, 'SCAN STORAGE');
    await waitFor(tester, find.text('Summary'));
    final sample = File('/sdcard/TeamTest/Download/lease_agreement.pdf');
    expect(sample.existsSync(), isTrue, reason: 'push sample_phone to /sdcard/TeamTest first');

    await tester.tap(find.text('Summary'));
    await waitFor(tester, find.text('Wasted Digital Space Detected'));
    expect(find.text('Scan Complete'), findsOneWidget);
    expect(find.text('8.7 GB of storage may be wasted.'), findsNothing, reason: 'real data, not the sample');
    await goBack(tester);

    // coilehayden0's garbage collection page moves the files to the bin.
    await tester.tap(find.text('By category'));
    await waitFor(tester, find.text('Detected Storage Items'));
    expect(find.textContaining('Empty file ('), findsOneWidget);
    await tester.tap(find.text('Send selected items to garbage bin'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Continue?'));
    await waitFor(tester, find.text('Selected items sent to the garbage bin.'));
    expect(sample.existsSync(), isFalse, reason: 'the broken PDF should be in the Garbage Bin folder now');
    expect(find.textContaining('Empty file ('), findsNothing);
    await goBack(tester);

    // Back on the scan page nothing is left to move; the bin has the files.
    await waitFor(tester, find.text('NOTHING TO MUNCH'));
    await goBack(tester);
    await tester.scrollUntilVisible(find.text('DATAMUNCHER'), -300, scrollable: find.byType(Scrollable).first);
    final binButton = find.byWidgetPredicate((w) => w is IconButton && (w.tooltip ?? '').startsWith('Garbage Bin'));
    final binCount = int.parse(RegExp(r'\d+').firstMatch(tester.widget<IconButton>(binButton).tooltip!)!.group(0)!);
    expect(binCount, greaterThan(0));
    await tester.tap(binButton);
    await waitFor(tester, find.text('Garbage Bin'));
    await waitFor(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'lease_agreement');
    await waitFor(tester, find.text('lease_agreement.pdf'));
  });
}
