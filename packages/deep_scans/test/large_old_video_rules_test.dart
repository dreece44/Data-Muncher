import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:deep_scans/deep_scans.dart';
import 'package:deep_scans/testing.dart';
import 'package:scan_engine/scan_engine.dart';
import 'package:test/test.dart';

import 'support/video_device.dart';

/// Unit tests for the large & old video deep scan: one group per part of
/// `docs/LARGE_OLD_VIDEO_RULESET.md`. Sizes are at test-area scale (1 KB on
/// disk stands for 1 MB) with the matching scaled rules.
void main() {
  const minute = Duration(minutes: 1);

  /// A normal 1080p30 phone-like MP4 standing for [real] GB, recorded [days]
  /// ago (container date and file date agree).
  VideoFile mp4(double real, int days,
      {Duration duration = const Duration(minutes: 3)}) {
    final t = daysAgo(days);
    return VideoFile(
        mp4Video(bytes: gb(real), duration: duration, created: t), t);
  }

  group('names', () {
    VideoName? match(String name, [List<String> folders = const []]) =>
        matchVideoName(name, folders, defaultVideoNamePatterns);

    test('phones and cameras', () {
      final v = match('VID_20240706_181203.mp4')!;
      expect((v.tool, v.source), ('Android camera', VideoSource.camera));
      expect(v.recorded, DateTime(2024, 7, 6, 18, 12, 3));
      expect(match('PXL_20260915_143005123.TS.mp4')!.recorded,
          DateTime(2026, 9, 15, 14, 30, 5));
      expect(match('IMG_0219.MOV')!.tool, 'iPhone camera');
      expect(match('GX010042.MP4')!.tool, 'GoPro');
      expect(match('DJI_20260512143011_0001_D.MP4')!.recorded,
          DateTime(2026, 5, 12, 14, 30, 11));
    });

    test('the bare Samsung date name only counts in a Camera folder', () {
      expect(match('20260910_101500.mp4'), isNull);
      expect(match('20260910_101500.mp4', ['dcim', 'camera'])!.tool,
          'Samsung camera');
    });

    test('screen recorders, with the Unix time and 12-hour clocks', () {
      final s = match('Screen_Recording_20250412-201011_Instagram.mp4')!;
      expect((s.source, s.app), (VideoSource.screenRecording, 'Instagram'));
      expect(match('RPReplay_Final1712345678.mp4')!.recorded,
          DateTime.fromMillisecondsSinceEpoch(1712345678000));
      expect(match('Screen Recording 2025-04-12 at 8.10.11 PM.mov')!.recorded,
          DateTime(2025, 4, 12, 20, 10, 11));
    });

    test('game capture tools', () {
      final obs = match('2024-03-14 16-02-11.mkv')!;
      expect((obs.tool, obs.source), ('OBS', VideoSource.gameplay));
      final nv = match('Starfall Odyssey 2025.06.01 - 19.22.40.02.DVR.mp4')!;
      expect((nv.tool, nv.app), ('NVIDIA ShadowPlay', 'Starfall Odyssey'));
      expect(nv.recorded, DateTime(2025, 6, 1, 19, 22, 40));
      expect(match('Minecraft 2025-02-10 20-15-33-12.avi')!.tool, 'Fraps');
      // Game Bar's "<game> <date>" is only trusted in its Captures folder.
      expect(match('Starfall Odyssey 2026-10-05 21-14-03.mp4'), isNull);
      expect(
          match('Starfall Odyssey 2026-10-05 21-14-03.mp4', ['captures'])!.tool,
          'Xbox Game Bar');
    });

    test('chats, and the folder fallback', () {
      expect(match('VID-20240203-WA0007.mp4')!.source, VideoSource.messaging);
      expect(match('video_2025-05-20_22-14-09.mp4')!.tool, 'Telegram');
      expect(sourceFromFolders(['download', 'misc']), VideoSource.download);
      expect(sourceFromFolders(['videos', 'stuff']), VideoSource.other);
    });
  });

  group('containers', () {
    Future<VideoInfo?> info(List<int> bytes, [String name = 'v.mp4']) async {
      final source = VideoStorage({name: VideoFile(bytes, testNow)});
      final item = await source.listItems().single;
      return readVideoInfo(source, item, scaledRules, (_) {});
    }

    test('MP4: duration, size, frame rate, codec and creation time', () async {
      final created = DateTime.utc(2024, 3, 14, 16, 2, 11);
      final i = (await info(mp4Video(
          bytes: 200000,
          duration: minute,
          width: 1280,
          height: 720,
          fps: 60,
          codec: 'hvc1',
          created: created)))!;
      expect(i.container, 'MP4');
      expect((i.width, i.height, i.codec), (1280, 720, 'hvc1'));
      expect(i.frameRate, closeTo(60, 0.1));
      expect(i.duration, minute);
      expect(i.created, created);
      expect(i.hasAudio, isTrue);
      expect(i.problem, isNull);
    });

    test('QuickTime with the index first', () async {
      final i = (await info(
          mp4Video(
              bytes: 100000,
              duration: minute,
              quickTime: true,
              indexFirst: true),
          'v.mov'))!;
      expect((i.container, i.problem), ('QuickTime', null));
    });

    test('Matroska and WebM, including a Video-for-Windows codec', () async {
      final mkv = (await info(
          mkvVideo(bytes: 200000, duration: minute * 5, fourcc: 'ULRG'),
          'v.mkv'))!;
      expect((mkv.container, mkv.codec, mkv.width), ('Matroska', 'ulrg', 1920));
      expect(mkv.duration, minute * 5);
      expect(mkv.frameRate, closeTo(60, 0.1));
      expect(mkv.writingApp, startsWith('OBS Studio'));
      final webm = (await info(
          mkvVideo(bytes: 100000, duration: minute, webm: true), 'v.webm'))!;
      expect((webm.container, webm.problem), ('WebM', null));
    });

    test('AVI', () async {
      final i = (await info(
          aviVideo(bytes: 100000, frames: 300, fps: 30, fourcc: 'MJPG'),
          'v.avi'))!;
      expect((i.container, i.codec, i.frames), ('AVI', 'mjpg', 300));
      expect(i.duration!.inMilliseconds, closeTo(10000, 1));
    });

    test('other formats are not opened', () async {
      expect(await info(asfVideo(4096), 'v.wmv'), isNull);
    });

    test('V01: no frames', () async {
      for (final (bytes, name) in [
        (mp4Video(bytes: 8000, duration: minute, noSamples: true), 'a.mp4'),
        (mkvVideo(bytes: 0, duration: minute, clusters: false), 'b.mkv'),
        (aviVideo(bytes: 0, frames: 0, fps: 30, emptyMovi: true), 'c.avi'),
      ]) {
        expect((await info(bytes, name))!.problem?.rule, VideoRule.v01Empty,
            reason: name);
      }
    });

    test('V02: cut off, where the box walk alone sees nothing', () async {
      final full = mkvVideo(bytes: 200000, duration: minute);
      expect((await info(full.sublist(0, 80000), 'v.mkv'))!.problem?.rule,
          VideoRule.v02CutOff);
      final gopro = mp4Video(
          bytes: 200000,
          duration: minute,
          indexFirst: true,
          mdatToEnd: true,
          keep: 80000);
      final p = (await info(gopro))!.problem!;
      expect(p.rule, VideoRule.v02CutOff);
      expect(p.reason, matches(RegExp(r'cut off: 6\d% of it is missing')));
    });

    test('V03: frame tables that disagree', () async {
      expect(
          (await info(mp4Video(bytes: 50000, duration: minute, sttsExtra: 5)))!
              .problem
              ?.rule,
          VideoRule.v03Damaged);
    });

    test('V04: a Matroska recording never finalised, cut off or not', () async {
      final open = mkvVideo(bytes: 200000, duration: minute, finalized: false);
      final whole = (await info(open, 'v.mkv'))!.problem!;
      expect(whole.rule, VideoRule.v04Interrupted);
      expect(whole.reason, contains('never finished'));
      final cut = (await info(open.sublist(0, 150000), 'v.mkv'))!.problem!;
      expect(cut.rule, VideoRule.v04Interrupted);
      expect(cut.reason, contains('cut off'));
    });
  });

  group('rules', () {
    test('size and age: V10, V11, V13, V14 and too small', () async {
      final r = await scanVideos({
        'DCIM/Camera/old_large.mp4': mp4(0.6, 400),
        'DCIM/Camera/huge.mp4': mp4(2.5, 20),
        'DCIM/Camera/large.mp4': mp4(0.6, 40),
        'DCIM/Camera/old.mp4': mp4(0.15, 400),
        'DCIM/Camera/old_small.mp4': mp4(0.05, 400),
        'DCIM/Camera/fine.mp4': mp4(0.2, 40),
      });
      expect(r.codeFor('DCIM/Camera/old_large.mp4'), 'V10');
      expect(r.codeFor('DCIM/Camera/huge.mp4'), 'V11');
      expect(r.codeFor('DCIM/Camera/large.mp4'), 'V13');
      expect(r.codeFor('DCIM/Camera/old.mp4'), 'V14');
      expect(r.codeFor('DCIM/Camera/old_small.mp4'), isNull);
      expect(r.codeFor('DCIM/Camera/fine.mp4'), isNull);
    });

    test('V12: oversized recordings, with an estimated saving', () async {
      final t = daysAgo(40);
      final r = await scanVideos({
        // ~150 Mbit/s H.264 at 1080p30 (scaled): 2.4 bits/pixel.
        'Videos/hot.mp4': VideoFile(
            mp4Video(bytes: gb(0.5), duration: minute * 0.5, created: t), t),
        // ProRes at a lowish bitrate still counts: an editing codec.
        'Videos/prores.mov': VideoFile(
            mp4Video(
                bytes: gb(0.3),
                duration: minute * 2,
                codec: 'apcs',
                quickTime: true,
                created: t),
            t),
        // A phone at 48 Mbit/s 4K30: 0.19 bits/pixel, not oversized.
        'Videos/phone.mp4': VideoFile(
            mp4Video(
                bytes: gb(0.36),
                duration: minute,
                width: 3840,
                height: 2160,
                created: t),
            t),
      });
      final hot = r.verdictFor('Videos/hot.mp4');
      expect(hot.rule, VideoRule.v12Oversized);
      expect(hot.estimatedSavingBytes, greaterThan(gb(0.4)));
      expect(r.codeFor('Videos/prores.mov'), 'V12');
      expect(r.verdictFor('Videos/prores.mov').reason, contains('ProRes'));
      expect(r.codeFor('Videos/phone.mp4'), isNull);
    });

    test('precedence: V10 wins and the other matches are kept', () async {
      final t = daysAgo(600);
      final r = await scanVideos({
        'Videos/Fraps/Minecraft 2025-02-10 20-15-33-12.avi': VideoFile(
            aviVideo(bytes: gb(2.25), frames: 2700, fps: 30, fourcc: 'FPS1'),
            t),
      });
      final v = r.verdicts.single;
      expect(v.rule, VideoRule.v10OldLarge);
      expect([for (final s in v.alsoMatched) s.rule.code],
          ['V11', 'V12', 'V13', 'V14']);
      expect(v.estimatedSavingBytes, isNotNull);
      expect((v.source, v.tool, v.app),
          (VideoSource.gameplay, 'Fraps', 'Minecraft'));
    });

    test('recorded date: container, then name, then file date', () async {
      final r = await scanVideos({
        // Copied yesterday; the container says 400 days ago.
        'a.mp4': VideoFile(
            mp4Video(bytes: gb(0.6), duration: minute, created: daysAgo(400)),
            daysAgo(1)),
        // No container date; the name says 400 days ago.
        'VID_${_cam(daysAgo(400))}.mp4':
            VideoFile(mp4Video(bytes: gb(0.6), duration: minute), daysAgo(1)),
        // Nothing but the file date: likely, not certain.
        'b.mp4':
            VideoFile(mp4Video(bytes: gb(0.6), duration: minute), daysAgo(400)),
      });
      final a = r.verdictFor('a.mp4');
      expect((a.rule, a.recordedFrom, a.confidence),
          (VideoRule.v10OldLarge, RecordedFrom.metadata, Confidence.certain));
      expect(r.notesFor('a.mp4'), contains('datesDisagree'));
      expect(r.verdictFor('VID_${_cam(daysAgo(400))}.mp4').recordedFrom,
          RecordedFrom.name);
      final b = r.verdictFor('b.mp4');
      expect((b.recordedFrom, b.confidence),
          (RecordedFrom.modified, Confidence.likely));
    });

    test('a container date that makes no sense is ignored', () async {
      final r = await scanVideos({
        'GX010051.MP4': VideoFile(
            mp4Video(
                bytes: gb(0.6), duration: minute, created: DateTime.utc(1970)),
            daysAgo(400)),
      });
      expect(r.verdicts.single.recordedFrom, RecordedFrom.modified);
      expect(r.notesFor('GX010051.MP4'), contains('badMetadataDate'));
    });

    test('min confidence falls through to a rule it trusts', () async {
      final r = await scanVideos({
        'b.mp4': VideoFile(
            mp4Video(bytes: gb(0.6), duration: minute * 10), daysAgo(400)),
      }, rules: scaledRules.copyWith(minConfidence: Confidence.certain));
      expect(r.codeFor('b.mp4'), 'V13');
      expect(r.notesFor('b.mp4'), contains('suppressed'));
    });

    test('a disabled rule falls through', () async {
      final r = await scanVideos({'a.mp4': mp4(0.6, 400)},
          rules: scaledRules.copyWith(disabledRules: {VideoRule.v10OldLarge}));
      expect(r.codeFor('a.mp4'), 'V13');
    });
  });

  group('holds and exclusions', () {
    test('X01: recent videos are held back, broken ones are not', () async {
      final t = daysAgo(1);
      final r = await scanVideos({
        'Videos/new.mp4': mp4(2.5, 1),
        'Videos/new_broken.mkv': VideoFile(
            mkvVideo(bytes: gb(0.3), duration: minute, created: t)
                .sublist(0, gb(0.1)),
            t),
      });
      expect(r.codeFor('Videos/new.mp4'), isNull);
      expect(r.notesFor('Videos/new.mp4'), contains('recent'));
      expect(r.codeFor('Videos/new_broken.mkv'), 'V02');
      final later = await scanVideos({'Videos/new.mp4': mp4(2.5, 1)},
          now: testNow.add(const Duration(days: 14)));
      expect(later.codeFor('Videos/new.mp4'), 'V11');
    });

    test('X02: active editing projects protect what they use', () async {
      final xml = utf8.encode('<mlt><property name="resource">'
          'C:/Videos/Montage/used.mkv</property></mlt>');
      final files = {
        'Videos/Montage/edit.kdenlive': VideoFile(xml, daysAgo(2)),
        'Videos/Montage/used.mkv': mp4(2.5, 30),
        'Videos/Montage/unused.mp4': mp4(2.5, 30),
        // Premiere projects are gzip; abandoned ones protect nothing.
        'Videos/Old/old.prproj': VideoFile(
            const GZipEncoder().encodeBytes(utf8.encode('<p>stale.mp4</p>')),
            daysAgo(300)),
        'Videos/Old/stale.mp4': mp4(2.5, 30),
        // A ZIP project can't be searched: it covers its folder.
        'Videos/Vlog/vlog.drp':
            VideoFile(zipArchive({'a.xml': '<x/>'}), daysAgo(5)),
        'Videos/Vlog/footage/clip.mp4': mp4(2.5, 30),
      };
      // `used.mkv` is really an MP4 here; the name is what the project uses.
      final r = await scanVideos(files);
      expect(r.codeFor('Videos/Montage/used.mkv'), isNull);
      expect(r.notesFor('Videos/Montage/used.mkv'), contains('activeProject'));
      expect(r.codeFor('Videos/Montage/unused.mp4'), 'V11');
      expect(r.codeFor('Videos/Old/stale.mp4'), 'V11');
      expect(r.verdictFor('Videos/Old/stale.mp4').evidence,
          contains('old.prproj'));
      expect(r.codeFor('Videos/Vlog/footage/clip.mp4'), isNull);
      expect(r.analysis.projectsFound, 3);
    });

    test('X04: the movie half of a Live Photo', () async {
      final t = daysAgo(700);
      final r = await scanVideos({
        'DCIM/IMG_4412.HEIC': VideoFile(heifStill(), t),
        'DCIM/IMG_4412.MOV': VideoFile(
            mp4Video(
                bytes: 8000,
                duration: const Duration(seconds: 3),
                quickTime: true,
                created: t),
            t),
      }, rules: scaledRules.copyWith(oldMinBytes: 1000));
      expect(r.codeFor('DCIM/IMG_4412.MOV'), isNull);
      expect(r.notesFor('DCIM/IMG_4412.MOV'), contains('livePhoto'));
    });

    test('X05: videos in an app folder are not judged', () async {
      final r = await scanVideos(
          {'Android/data/com.game/files/intro.mp4': mp4(2.5, 600)});
      expect(r.verdicts, isEmpty);
      expect(r.notesFor('Android/data/com.game/files/intro.mp4'),
          contains('appData'));
    });

    test('X03: a broken container modified minutes ago is not judged yet',
        () async {
      final t = testNow.subtract(const Duration(minutes: 2));
      final files = {
        'Videos/rec.mkv': VideoFile(
            mkvVideo(
                bytes: gb(0.3), duration: minute, created: t, finalized: false),
            t),
      };
      final r = await scanVideos(files);
      expect(r.codeFor('Videos/rec.mkv'), isNull);
      expect(r.notesFor('Videos/rec.mkv'), contains('stillWriting'));
      final later = await scanVideos(files,
          now: testNow.add(const Duration(minutes: 10)));
      expect(later.codeFor('Videos/rec.mkv'), 'V04');
    });

    test('X07 and X09: judged by size and date only', () async {
      final r = await scanVideos({
        'Videos/00012.MTS': VideoFile(mpegTs(gb(0.6)), daysAgo(800)),
        'photos/IMG_0001.MOV': VideoFile(
            mp4Video(bytes: gb(0.6), duration: minute), daysAgo(800),
            photoLibrary: true),
      });
      expect(r.codeFor('Videos/00012.MTS'), 'V10');
      expect(r.notesFor('Videos/00012.MTS'), contains('notParsed'));
      expect(r.codeFor('photos/IMG_0001.MOV'), 'V10');
      expect(r.notesFor('photos/IMG_0001.MOV'), contains('contentNotRead'));
    });
  });

  group('empty & unreadable videos', () {
    test('are reported under their E/U rules, with their source', () async {
      final t = daysAgo(30);
      final r = await scanVideos({
        'Download/zero.mp4': VideoFile(const [], t),
        'Download/part.mp4.crdownload':
            VideoFile(mp4Video(bytes: 50000, duration: minute), t),
        'Videos/Captures/Game 2026-10-01 20-00-00.mp4': VideoFile(
            mp4Video(bytes: 50000, duration: minute, index: false), t),
      });
      expect(r.codeFor('Download/zero.mp4'), 'E01');
      expect(r.codeFor('Download/part.mp4.crdownload'), 'U03');
      final h = r.analysis.health.singleWhere(
          (h) => h.item.id == 'Videos/Captures/Game 2026-10-01 20-00-00.mp4');
      expect((h.verdict.rule.code, h.source), ('U06', VideoSource.gameplay));
      expect(r.verdicts, isEmpty);
    });

    test('a video that cannot be read is noted', () async {
      final r =
          await scanVideos({'a.mp4': mp4(0.6, 400)}, unreadable: {'a.mp4'});
      expect(r.codeFor('a.mp4'), 'U01');
    });
  });

  group('results', () {
    test('ranking is largest first and batches are grouped by rule', () async {
      final r = await scanVideos({
        'DCIM/Camera/a.mp4': mp4(0.6, 400),
        'DCIM/Camera/b.mp4': mp4(2.5, 40),
        'DCIM/Camera/c.mp4': mp4(0.7, 40),
        'Download/cut.mkv': VideoFile(
            mkvVideo(bytes: gb(0.5), duration: minute).sublist(0, gb(0.2)),
            daysAgo(30)),
        'Download/zero.mp4': VideoFile(const [], daysAgo(30)),
      });
      expect([for (final v in r.analysis.ranking) v.item.id],
          ['DCIM/Camera/b.mp4', 'DCIM/Camera/c.mp4', 'DCIM/Camera/a.mp4']);
      expect([for (final b in r.analysis.batches) b.id],
          ['unplayable', 'oldLarge', 'huge', 'large']);
      final unplayable = r.analysis.batches.first;
      expect(unplayable.preselect, isTrue);
      expect(unplayable.items.length, 2);
      expect(r.analysis.batches.skip(1).every((b) => !b.preselect), isTrue);
      expect(r.toJson()['stats'], containsPair('countsByRule', isNotEmpty));
      expect(r.format(), contains('Largest first:'));
    });

    test('scaledDown divides sizes and bit-rate limits', () {
      const d = LargeOldVideoRules();
      final s = d.scaledDown(1024);
      expect(s.largeBytes, d.largeBytes ~/ 1024);
      expect(s.hugeBytes, d.hugeBytes ~/ 1024);
      expect(s.oversizedBitsPerPixel, d.oversizedBitsPerPixel / 1024);
      expect((s.sizeScale, s.oldAge), (1024, d.oldAge));
    });

    test('the storage permission gate applies', () async {
      final device = VideoDevice({'a.mp4': mp4(2.5, 400)}, granted: false);
      await expectLater(LargeOldVideoScan(device: device).run(),
          throwsA(isA<PermissionDeniedException>()));
      expect(device.storage.accessCount, 0);
    });

    test('drops into a ScanEngine as a detector', () async {
      final health = EmptyUnreadableAnalyzer();
      final analyzer =
          LargeOldVideoAnalyzer(rules: scaledRules, health: health);
      final report = await ScanEngine(
        device: VideoDevice({'a.mp4': mp4(2.5, 400)}),
        detectors: [
          ...health.detectors(),
          analyzer.detector(WasteCategory.unusedApp),
        ],
        clock: () => testNow,
      ).scan();
      expect(report.findings.single.reason, startsWith('Old and large'));
    });
  });
}

String _cam(DateTime t) =>
    '${t.year}${_pad(t.month)}${_pad(t.day)}_${_pad(t.hour)}'
    '${_pad(t.minute)}${_pad(t.second)}';
String _pad(int n) => n.toString().padLeft(2, '0');
