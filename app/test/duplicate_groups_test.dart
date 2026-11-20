import 'package:datamuncher/application/duplicate_groups/best_copy.dart';
import 'package:datamuncher/presentation/duplicate_groups/duplicate_groups_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A grey 256² frame with a detailed 80² subject whose top-left corner is at
/// ([x], [y]), optionally blurred and brightened.
img.Image scene({int x = 88, int y = 88, int blur = 0, int lift = 0}) {
  var im = img.Image(width: 256, height: 256);
  img.fill(im, color: img.ColorRgb8(110 + lift, 110 + lift, 110 + lift));
  for (var j = 0; j < 80; j++) {
    for (var i = 0; i < 80; i++) {
      final v = (((i ~/ 4) + (j ~/ 4)) % 2 == 0 ? 30 : 220) + lift;
      im.setPixelRgb(x + i, y + j, v.clamp(0, 255), v.clamp(0, 255), v.clamp(0, 255));
    }
  }
  if (blur > 0) im = img.gaussianBlur(im, radius: blur);
  return im;
}

final t0 = DateTime(2026, 11, 1, 12);

DuplicateCandidate photo(String id,
        {int hash = 0, PhotoQuality? quality, int w = 4000, int h = 3000, Duration at = Duration.zero}) =>
    DuplicateCandidate(
      id: id,
      hash: hash,
      quality: quality ?? const PhotoQuality(clarity: 1, centering: 0.9),
      width: w,
      height: h,
      taken: t0.add(at),
    );

void main() {
  group('PhotoQuality', () {
    test('a blurred copy is less clear', () {
      final sharp = PhotoQuality.fromImage(scene());
      final soft = PhotoQuality.fromImage(scene(blur: 3));
      expect(sharp.clarity, greaterThan(soft.clarity * 2));
    });

    test('a brightened copy is not counted as clearer', () {
      final plain = PhotoQuality.fromImage(scene());
      final bright = PhotoQuality.fromImage(scene(lift: 25));
      expect(bright.clarity, closeTo(plain.clarity, plain.clarity * 0.1));
    });

    test('a centred subject scores higher than one at the edge', () {
      final centred = PhotoQuality.fromImage(scene());
      final corner = PhotoQuality.fromImage(scene(x: 0, y: 10));
      expect(centred.centering, greaterThan(0.95));
      expect(corner.centering, lessThan(0.6));
    });

    test('a flat image has no clarity and counts as centred', () {
      final flat = img.Image(width: 64, height: 64);
      img.fill(flat, color: img.ColorRgb8(90, 90, 90));
      final q = PhotoQuality.fromImage(flat);
      expect(q.clarity, 0);
      expect(q.centering, 1);
    });
  });

  test('hashFromBits and hashDistance', () {
    final a = hashFromBits('1' * 64);
    final b = hashFromBits('0${'1' * 63}');
    expect(hashDistance(a, b), 1);
    expect(hashDistance(a, a), 0);
    expect(hashDistance(hashFromBits('0' * 64), a), 64);
  });

  group('groupDuplicates', () {
    test('identical copies group whenever they were taken', () {
      final groups = groupDuplicates([
        photo('a', hash: 7),
        photo('b', hash: 7, at: const Duration(days: 40)),
        photo('c', hash: 0xFFFF00),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.ids..sort(), ['a', 'b']);
    });

    test('near-identical shots group only when taken close together', () {
      final close = groupDuplicates([photo('a', hash: 0), photo('b', hash: 0x3F, at: const Duration(seconds: 20))]);
      expect(close, hasLength(1));

      final apart = groupDuplicates([photo('a', hash: 0), photo('b', hash: 0x3F, at: const Duration(hours: 2))]);
      expect(apart, isEmpty);

      final tooDifferent =
          groupDuplicates([photo('a', hash: 0), photo('b', hash: 0x7F, at: const Duration(seconds: 20))]);
      expect(tooDifferent, isEmpty, reason: '7 bits apart is past the 6-bit limit');
    });

    test('shots of a different shape are not grouped', () {
      final groups =
          groupDuplicates([photo('a', hash: 0), photo('b', hash: 1, w: 3000, h: 4000, at: const Duration(seconds: 5))]);
      expect(groups, isEmpty);
    });

    test('videos only group with identical hash and the same length', () {
      DuplicateCandidate video(String id, int hash, int seconds) => DuplicateCandidate(
          id: id, hash: hash, isVideo: true, durationSec: seconds, width: 1920, height: 1080, taken: t0);
      expect(groupDuplicates([video('a', 5, 30), video('b', 5, 31)]), isEmpty);
      expect(groupDuplicates([video('a', 5, 30), video('b', 4, 30)]), isEmpty);
      expect(groupDuplicates([video('a', 5, 30), video('b', 5, 30)]), hasLength(1));
    });

    test('a chain of gradually changing shots is not one group', () {
      // a–b and b–c are 4 bits apart, but a–c is 8.
      final groups = groupDuplicates([
        photo('a', hash: 0x00),
        photo('b', hash: 0x0F, at: const Duration(seconds: 10)),
        photo('c', hash: 0xFF, at: const Duration(seconds: 20)),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.members, hasLength(2));
    });
  });

  group('best copy', () {
    test('keeps the clearest of a burst', () {
      final group = DuplicateGroup.of([
        photo('blurry', quality: PhotoQuality.fromImage(scene(blur: 3))),
        photo('sharp', quality: PhotoQuality.fromImage(scene()), at: const Duration(seconds: 2)),
      ]);
      expect(group.bestId, 'sharp');
      expect(group.reason, contains('sharpest'));
      expect(group.others.single.id, 'blurry');
    });

    test('of equally clear shots, keeps the best centred', () {
      final group = DuplicateGroup.of([
        photo('off', quality: PhotoQuality.fromImage(scene(x: 0, y: 10))),
        photo('centred', quality: PhotoQuality.fromImage(scene()), at: const Duration(seconds: 2)),
      ]);
      expect(group.bestId, 'centred');
      expect(group.reason, contains('best centred'));
    });

    test('clarity counts for more than centring', () {
      final group = DuplicateGroup.of([
        photo('centred-but-blurry', quality: PhotoQuality.fromImage(scene(blur: 3))),
        photo('sharp-off-centre', quality: PhotoQuality.fromImage(scene(x: 30, y: 60))),
      ]);
      expect(group.bestId, 'sharp-off-centre');
    });

    test('of identical-looking copies, keeps the highest resolution', () {
      final group = DuplicateGroup.of([
        photo('whatsapp', w: 1600, h: 1200),
        photo('original', at: const Duration(days: 1)),
      ]);
      expect(group.bestId, 'original');
      expect(group.reason, 'highest resolution');
    });

    test('of identical copies, keeps the oldest', () {
      final group = DuplicateGroup.of([
        photo('newer', at: const Duration(days: 3)),
        photo('older'),
      ]);
      expect(group.bestId, 'older');
      expect(group.reason, contains('oldest'));
    });

    test('losing the best copy picks a new one; one left is no group', () {
      final group = DuplicateGroup.of([
        photo('a', quality: const PhotoQuality(clarity: 3, centering: 0.9)),
        photo('b', quality: const PhotoQuality(clarity: 2, centering: 0.9)),
        photo('c', quality: const PhotoQuality(clarity: 1, centering: 0.9)),
      ]);
      expect(group.bestId, 'a');
      expect(identical(group.without({'x'}), group), isTrue);
      expect(group.without({'a'})!.bestId, 'b');
      expect(group.without({'a', 'b'}), isNull);
    });
  });

  group('DuplicateGroupsScreen', () {
    final groups = [
      DuplicateGroup.of([
        photo('a1', quality: const PhotoQuality(clarity: 1, centering: 0.9)),
        photo('a2', quality: const PhotoQuality(clarity: 3, centering: 0.9)),
        photo('a3', quality: const PhotoQuality(clarity: 2, centering: 0.9)),
      ]),
      DuplicateGroup.of([photo('b1'), photo('b2', at: const Duration(days: 1))]),
    ];

    Future<List<(List<String>, DuplicateRemoval)>> pump(WidgetTester tester) async {
      final calls = <(List<String>, DuplicateRemoval)>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DuplicateGroupsScreen(
                    groups: groups,
                    thumbnailBuilder: (id) => ColoredBox(color: Colors.grey, child: Text(id)),
                    onRemove: (ids, how) async {
                      calls.add((ids, how));
                      return 'done';
                    },
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return calls;
    }

    Finder badgeIn(String id, String label) =>
        find.descendant(of: find.byKey(ValueKey('copy-$id')), matching: find.text(label));

    testWidgets('pre-selects the best copy and removes the rest in one action', (tester) async {
      final calls = await pump(tester);
      expect(badgeIn('a2', 'KEEP'), findsOneWidget);
      expect(badgeIn('a2', '★ BEST'), findsOneWidget);
      expect(badgeIn('b1', 'KEEP'), findsOneWidget);
      expect(find.text('REMOVE 3 DUPLICATES'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('remove-duplicates')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-bin')));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.$1..sort(), ['a1', 'a3', 'b2']);
      expect(calls.single.$2, DuplicateRemoval.bin);
      expect(find.text('done'), findsOneWidget);
      expect(find.text('open'), findsOneWidget, reason: 'the page closes');
    });

    testWidgets('tapping another copy keeps it; unticking a group leaves it alone', (tester) async {
      final calls = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('copy-a1')));
      await tester.pump();
      expect(badgeIn('a1', 'KEEP'), findsOneWidget);
      expect(badgeIn('a2', 'KEEP'), findsNothing);
      expect(badgeIn('a2', '★ BEST'), findsOneWidget, reason: 'the suggestion still shows');

      await tester.tap(find.byKey(const ValueKey('group-1')));
      await tester.pump();
      expect(find.text('REMOVE 2 DUPLICATES'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('remove-duplicates')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-delete')));
      await tester.pumpAndSettle();
      expect(calls.single.$1..sort(), ['a2', 'a3']);
      expect(calls.single.$2, DuplicateRemoval.delete);
    });

    testWidgets('cancel removes nothing', (tester) async {
      final calls = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('remove-duplicates')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.text('REMOVE 3 DUPLICATES'), findsOneWidget);
    });
  });
}
