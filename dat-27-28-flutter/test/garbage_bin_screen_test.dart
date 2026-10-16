import 'dart:async';

import 'package:datamuncher/application/garbage_bin/empty_bin.dart';
import 'package:datamuncher/data/garbage_bin/bin_entry.dart';
import 'package:datamuncher/data/garbage_bin/garbage_bin_store.dart';
import 'package:datamuncher/data/garbage_bin/in_memory_garbage_bin_store.dart';
import 'package:datamuncher/presentation/garbage_bin/bin_entry_details_sheet.dart';
import 'package:datamuncher/presentation/garbage_bin/garbage_bin_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  const photoName = 'beach_duplicate.jpg';
  const videoName = 'old_gameplay.mp4';
  const documentName = 'receipt_scan (2).pdf';

  Future<void> pumpScreen(
    WidgetTester tester,
    GarbageBinStore store, {
    BinEntryAction? onRecover,
    BinEntryAction? onDelete,
    Future<EmptyBinOutcome> Function()? onEmptyBin,
    String? emptyBinNote,
    Widget? Function(BinEntry)? thumbnailBuilder,
  }) async {
    // A tall surface so the header and all three rows fit on screen.
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: GarbageBinScreen(
          store: store,
          clock: () => testNow,
          onRecover: onRecover,
          onDelete: onDelete,
          onEmptyBin: onEmptyBin,
          emptyBinNote: emptyBinNote,
          thumbnailBuilder: thumbnailBuilder,
        ),
      ),
    );
  }

  double rowTop(WidgetTester tester, String fileName) =>
      tester.getTopLeft(find.text(fileName)).dy;

  testWidgets('shows a spinner while the bin opens, then the files',
      (tester) async {
    final store = ScriptedGarbageBinStore();
    await pumpScreen(tester, store);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    store.pendingLoads.single.complete(sampleEntries());
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(photoName), findsOneWidget);
    expect(find.text(videoName), findsOneWidget);
    expect(find.text(documentName), findsOneWidget);
  });

  testWidgets('explains an empty bin', (tester) async {
    await pumpScreen(tester, InMemoryGarbageBinStore());
    await tester.pumpAndSettle();

    expect(find.text('Your Garbage Bin is empty'), findsOneWidget);
    expect(find.byIcon(Icons.sort), findsNothing);
  });

  testWidgets('shows an error and can try again', (tester) async {
    final store = ScriptedGarbageBinStore();
    await pumpScreen(tester, store);
    store.pendingLoads.single.completeError(StateError('bin unavailable'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't open the Garbage Bin"), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    store.pendingLoads.last.complete(sampleEntries());
    await tester.pumpAndSettle();

    expect(find.text(photoName), findsOneWidget);
  });

  testWidgets('summary shows totals and files leaving soon', (tester) async {
    await pumpScreen(tester, InMemoryGarbageBinStore(sampleEntries()));
    await tester.pumpAndSettle();

    expect(find.text('3 files · 905 MB'), findsOneWidget);
    expect(
      find.text('Compressed to 884 MB while in the bin (saving 20.5 MB)'),
      findsOneWidget,
    );
    expect(
      find.text('1 file will be removed from the bin within 3 days'),
      findsOneWidget,
    );
  });

  testWidgets('each row says why, how big, when, and where from',
      (tester) async {
    await pumpScreen(tester, InMemoryGarbageBinStore(sampleEntries()));
    await tester.pumpAndSettle();

    expect(find.text('Duplicate · 4.2 MB · Yesterday'), findsOneWidget);
    expect(find.text('From /DCIM/Camera'), findsOneWidget);
    expect(find.text('2 days left'), findsOneWidget);

    expect(find.text('Old file · 900 MB · 3 days ago'), findsOneWidget);
    expect(find.text('Duplicate · 350 KB · Today'), findsOneWidget);
    // Only the photo is leaving within three days.
    expect(find.textContaining('days left'), findsOneWidget);
  });

  testWidgets('lists newest first and the sort menu reorders',
      (tester) async {
    await pumpScreen(tester, InMemoryGarbageBinStore(sampleEntries()));
    await tester.pumpAndSettle();

    expect(rowTop(tester, documentName), lessThan(rowTop(tester, photoName)));
    expect(rowTop(tester, photoName), lessThan(rowTop(tester, videoName)));

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Largest first'));
    await tester.pumpAndSettle();

    expect(rowTop(tester, videoName), lessThan(rowTop(tester, photoName)));
    expect(rowTop(tester, photoName), lessThan(rowTop(tester, documentName)));
  });

  testWidgets('search narrows the list and can be cleared', (tester) async {
    await pumpScreen(tester, InMemoryGarbageBinStore(sampleEntries()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'receipt');
    await tester.pumpAndSettle();

    expect(find.text(documentName), findsOneWidget);
    expect(find.text(photoName), findsNothing);
    expect(find.text('Showing 1 of 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();

    expect(find.text(photoName), findsOneWidget);
    expect(find.text('Showing 1 of 3'), findsNothing);
  });

  testWidgets('category chips filter by kind of file', (tester) async {
    await pumpScreen(tester, InMemoryGarbageBinStore(sampleEntries()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Videos (1)'));
    await tester.pumpAndSettle();

    expect(find.text(videoName), findsOneWidget);
    expect(find.text(photoName), findsNothing);
    expect(find.text('Showing 1 of 3'), findsOneWidget);

    await tester.tap(find.text('All (3)'));
    await tester.pumpAndSettle();
    expect(find.text(photoName), findsOneWidget);
  });

  testWidgets('no matches offers a way back', (tester) async {
    await pumpScreen(tester, InMemoryGarbageBinStore(sampleEntries()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No files match'), findsOneWidget);

    await tester.tap(find.text('Clear search and filters'));
    await tester.pumpAndSettle();

    expect(find.text(photoName), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('tapping a file shows its details', (tester) async {
    await pumpScreen(tester, InMemoryGarbageBinStore(sampleEntries()));
    await tester.pumpAndSettle();

    await tester.tap(find.text(photoName));
    await tester.pumpAndSettle();

    expect(find.text('/DCIM/Camera/beach_duplicate.jpg'), findsOneWidget);
    expect(find.text('Why it was collected'), findsOneWidget);
    expect(find.text('3.9 MB (compressed)'), findsOneWidget);
    expect(find.text('Oct 9, 2026 (2 days left)'), findsOneWidget);
    // Recover and Delete stay hidden until those features are connected.
    expect(find.text('Recover'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('a file with no time limit says so', (tester) async {
    await pumpScreen(tester, InMemoryGarbageBinStore(sampleEntries()));
    await tester.pumpAndSettle();

    await tester.tap(find.text(documentName));
    await tester.pumpAndSettle();

    expect(find.text('No time limit set'), findsOneWidget);
  });

  testWidgets('Recover hands the file to File Recovery and refreshes',
      (tester) async {
    final store = InMemoryGarbageBinStore(sampleEntries());
    final recovered = <String>[];
    await pumpScreen(
      tester,
      store,
      onRecover: (BinEntry entry) async {
        recovered.add(entry.id);
        store.remove(entry.id);
      },
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(photoName));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recover'));
    await tester.pumpAndSettle();

    expect(recovered, ['p1']);
    expect(find.text('Recovered $photoName'), findsOneWidget);
    expect(find.text(photoName), findsNothing);
    expect(find.text('2 files · 900 MB'), findsOneWidget);

    // Let the snack bar time out.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a failed recovery says the file is still in the bin',
      (tester) async {
    await pumpScreen(
      tester,
      InMemoryGarbageBinStore(sampleEntries()),
      onRecover: (BinEntry entry) async => throw StateError('disk full'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(photoName));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recover'));
    await tester.pumpAndSettle();

    expect(
      find.text("Couldn't recover $photoName. It's still in the bin."),
      findsOneWidget,
    );
    expect(find.text(photoName), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('Delete asks first and does nothing on Cancel', (tester) async {
    final store = InMemoryGarbageBinStore(sampleEntries());
    final deleted = <String>[];
    await pumpScreen(
      tester,
      store,
      onDelete: (BinEntry entry) async {
        deleted.add(entry.id);
        store.remove(entry.id);
      },
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(videoName));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete this file now?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(deleted, isEmpty);
    expect(find.text(videoName), findsOneWidget);

    await tester.tap(find.text(videoName));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleted, ['v1']);
    expect(find.text(videoName), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  const allIds = {'p1', 'v1', 'd1'};
  const trash = Duration(days: 30);

  Future<void> confirmEmpty(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Empty Garbage Bin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Empty bin'));
    await tester.pumpAndSettle();
  }

  Future<void> dismissSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
  }

  testWidgets('Empty Bin asks first, then reports what was removed',
      (tester) async {
    final store = InMemoryGarbageBinStore(sampleEntries());
    var emptied = 0;
    await pumpScreen(
      tester,
      store,
      emptyBinNote: "They'll go to your phone's trash.",
      onEmptyBin: () async {
        emptied++;
        store.clear();
        return const EmptyBinOutcome(removedIds: allIds, restorableFor: trash);
      },
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Empty Garbage Bin'));
    await tester.pumpAndSettle();
    expect(
      find.text('All 3 files (905 MB) will be deleted from your device. '
          "They'll go to your phone's trash."),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(emptied, 0);

    await confirmEmpty(tester);

    expect(emptied, 1);
    expect(
      find.text("Emptied the bin: 3 files (905 MB). You can restore them from "
          "your phone's trash for 30 days; the space is freed after that."),
      findsOneWidget,
    );
    expect(find.text('Your Garbage Bin is empty'), findsOneWidget);
    expect(find.byTooltip('Empty Garbage Bin'), findsNothing);
    await dismissSnackBar(tester);
  });

  testWidgets('a permanent empty reports the space freed', (tester) async {
    final store = InMemoryGarbageBinStore(sampleEntries());
    await pumpScreen(
      tester,
      store,
      onEmptyBin: () async {
        store.clear();
        return const EmptyBinOutcome(removedIds: allIds);
      },
    );
    await tester.pumpAndSettle();
    await confirmEmpty(tester);

    expect(find.text('Emptied the bin and freed 905 MB.'), findsOneWidget);
    await dismissSnackBar(tester);
  });

  testWidgets('a partial empty says what is still in the bin',
      (tester) async {
    final store = InMemoryGarbageBinStore(sampleEntries());
    await pumpScreen(
      tester,
      store,
      onEmptyBin: () async {
        store.remove('v1');
        return const EmptyBinOutcome(removedIds: {'v1'}, restorableFor: trash);
      },
    );
    await tester.pumpAndSettle();
    await confirmEmpty(tester);

    expect(
      find.text('Removed 1 file (900 MB) from the bin. 2 files are still in '
          "the bin. You can restore it from your phone's trash for 30 days; "
          'the space is freed after that.'),
      findsOneWidget,
    );
    expect(find.text(videoName), findsNothing);
    expect(find.text(photoName), findsOneWidget);
    await dismissSnackBar(tester);
  });

  testWidgets('cancelling the phone prompt deletes nothing', (tester) async {
    await pumpScreen(
      tester,
      InMemoryGarbageBinStore(sampleEntries()),
      onEmptyBin: () async => EmptyBinOutcome.nothingRemoved,
    );
    await tester.pumpAndSettle();
    await confirmEmpty(tester);

    expect(find.text('Nothing was deleted. Your files are still in the bin.'),
        findsOneWidget);
    expect(find.text(photoName), findsOneWidget);
    await dismissSnackBar(tester);
  });

  testWidgets('a failed empty says so and keeps the list', (tester) async {
    await pumpScreen(
      tester,
      InMemoryGarbageBinStore(sampleEntries()),
      onEmptyBin: () async => throw StateError('disk error'),
    );
    await tester.pumpAndSettle();
    await confirmEmpty(tester);

    expect(find.text("Couldn't empty the Garbage Bin."), findsOneWidget);
    expect(find.text(photoName), findsOneWidget);
    await dismissSnackBar(tester);
  });

  testWidgets('Empty Bin warns when a filter hides files', (tester) async {
    await pumpScreen(
      tester,
      InMemoryGarbageBinStore(sampleEntries()),
      onEmptyBin: () async => EmptyBinOutcome.nothingRemoved,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Videos (1)'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Empty Garbage Bin'));
    await tester.pumpAndSettle();
    expect(
      find.text('All 3 files (905 MB) will be deleted from your device. '
          'This includes files hidden by your search or filter.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Empty Bin cannot be pressed twice while running',
      (tester) async {
    final store = InMemoryGarbageBinStore(sampleEntries());
    final finish = Completer<EmptyBinOutcome>();
    var calls = 0;
    await pumpScreen(
      tester,
      store,
      onEmptyBin: () {
        calls++;
        return finish.future;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Empty Garbage Bin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Empty bin'));
    // The progress bar animates until emptying finishes, so don't settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_sweep_outlined),
    );
    expect(button.onPressed, isNull);

    store.clear();
    finish.complete(const EmptyBinOutcome(removedIds: allIds));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await dismissSnackBar(tester);
  });

  testWidgets('Empty Bin is hidden when not connected', (tester) async {
    await pumpScreen(tester, InMemoryGarbageBinStore(sampleEntries()));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Empty Garbage Bin'), findsNothing);
  });

  testWidgets('thumbnails replace the type icon when provided',
      (tester) async {
    await pumpScreen(
      tester,
      InMemoryGarbageBinStore(sampleEntries()),
      thumbnailBuilder: (entry) => entry.category == FileCategory.photo
          ? Container(key: ValueKey('thumb-${entry.id}'))
          : null,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('thumb-p1')), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
  });
}
