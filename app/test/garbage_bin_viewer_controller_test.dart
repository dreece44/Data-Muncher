import 'package:datamuncher/application/garbage_bin/bin_query.dart';
import 'package:datamuncher/application/garbage_bin/garbage_bin_viewer_controller.dart';
import 'package:datamuncher/data/garbage_bin/bin_entry.dart';
import 'package:datamuncher/data/garbage_bin/garbage_bin_store.dart';
import 'package:datamuncher/data/garbage_bin/in_memory_garbage_bin_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  final photo = makeEntry(
    id: 'a',
    fileName: 'beach.jpg',
    category: FileCategory.photo,
    collectedAt: testNow.subtract(const Duration(days: 2)),
  );
  final video = makeEntry(
    id: 'b',
    fileName: 'clip.mp4',
    originalPath: '/Movies/clip.mp4',
    category: FileCategory.video,
    collectedAt: testNow.subtract(const Duration(hours: 1)),
  );

  GarbageBinViewerController makeController(GarbageBinStore store) {
    final controller =
        GarbageBinViewerController(store: store, clock: () => testNow);
    addTearDown(controller.dispose);
    return controller;
  }

  List<String> visibleIds(GarbageBinViewerController controller) =>
      [for (final e in controller.visibleEntries) e.id];

  test('starts loading, then shows the bin newest first', () async {
    final controller =
        makeController(InMemoryGarbageBinStore([photo, video]));
    expect(controller.status, BinLoadStatus.loading);

    await controller.load();

    expect(controller.status, BinLoadStatus.ready);
    expect(visibleIds(controller), ['b', 'a']);
    expect(controller.summary.itemCount, 2);
    expect(controller.error, isNull);
  });

  test('an empty bin is ready with nothing in it', () async {
    final controller = makeController(InMemoryGarbageBinStore());
    await controller.load();
    expect(controller.status, BinLoadStatus.ready);
    expect(controller.allEntries, isEmpty);
  });

  test('a failed first load can be retried', () async {
    final store = ScriptedGarbageBinStore();
    final controller = makeController(store);

    final first = controller.load();
    store.pendingLoads.single.completeError(StateError('bin unavailable'));
    await first;
    expect(controller.status, BinLoadStatus.failed);
    expect(controller.error, isA<StateError>());

    final retry = controller.load();
    expect(controller.status, BinLoadStatus.loading);
    store.pendingLoads.last.complete([photo]);
    await retry;
    expect(controller.status, BinLoadStatus.ready);
    expect(controller.error, isNull);
    expect(visibleIds(controller), ['a']);
  });

  test('a failed refresh keeps the list it already had', () async {
    final store = ScriptedGarbageBinStore();
    final controller = makeController(store);

    final first = controller.load();
    store.pendingLoads.single.complete([photo]);
    await first;

    final refresh = controller.load();
    store.pendingLoads.last.completeError(StateError('bin unavailable'));
    await refresh;

    expect(controller.status, BinLoadStatus.ready);
    expect(controller.refreshFailed, isTrue);
    expect(visibleIds(controller), ['a']);
  });

  test('reloads by itself when the bin changes', () async {
    final store = InMemoryGarbageBinStore([photo]);
    final controller = makeController(store);
    await controller.load();

    store.put(video);
    await settle();

    expect(visibleIds(controller), ['b', 'a']);
  });

  test('only the newest of overlapping loads counts', () async {
    final store = ScriptedGarbageBinStore();
    final controller = makeController(store);

    final older = controller.load();
    final newer = controller.load();
    store.pendingLoads[1].complete([video]);
    await newer;
    store.pendingLoads[0].complete([photo]);
    await older;

    expect(visibleIds(controller), ['b']);
  });

  test('search, category and sort change what is visible', () async {
    final controller =
        makeController(InMemoryGarbageBinStore([photo, video]));
    await controller.load();
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.setSearchText('beach');
    expect(visibleIds(controller), ['a']);
    expect(notifications, 1);

    controller.setSearchText('beach');
    expect(notifications, 1, reason: 'same text should not rebuild');

    controller.clearFilters();
    controller.setCategory(FileCategory.video);
    expect(visibleIds(controller), ['b']);

    controller.setCategory(null);
    controller.setSort(BinSort.oldestFirst);
    expect(visibleIds(controller), ['a', 'b']);
    expect(controller.query.sort, BinSort.oldestFirst);
  });

  test('clearFilters keeps the sort order', () async {
    final controller =
        makeController(InMemoryGarbageBinStore([photo, video]));
    await controller.load();
    controller.setSort(BinSort.oldestFirst);
    controller.setSearchText('zzz');
    expect(controller.visibleEntries, isEmpty);

    controller.clearFilters();

    expect(controller.query.searchText, '');
    expect(controller.query.sort, BinSort.oldestFirst);
    expect(visibleIds(controller), ['a', 'b']);
  });

  test('the category is cleared once its last file leaves the bin', () async {
    final store = InMemoryGarbageBinStore([photo, video]);
    final controller = makeController(store);
    await controller.load();
    controller.setCategory(FileCategory.video);

    store.remove('b');
    await settle();

    expect(controller.query.category, isNull);
    expect(visibleIds(controller), ['a']);
  });

  test('a load that finishes after dispose is ignored', () async {
    final store = ScriptedGarbageBinStore();
    final controller =
        GarbageBinViewerController(store: store, clock: () => testNow);

    final load = controller.load();
    controller.dispose();
    store.pendingLoads.single.complete([photo]);

    await expectLater(load, completes);
  });
}
