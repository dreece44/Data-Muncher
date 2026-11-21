import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../large_old_videos/rules.dart';
import '../large_old_videos/scan.dart';
import 'document_factory.dart' show zipArchive;
import 'empty_unreadable_test_area.dart' show testAreaMarker;
import 'video_factory.dart';

/// Test areas are built at 1/[videoTestAreaScale] of real sizes: 1 MB on
/// disk stands for 1 GB. `expected.json` records it, and the scan divides
/// its size and bitrate thresholds by it (`LargeOldVideoRules.scaledDown`).
const videoTestAreaScale = 1024;

/// A generated large & old video test area: [filesDir] is the folder to
/// scan, [manifest] the `expected.json` with what each video should get.
final class LargeOldVideoTestArea {
  const LargeOldVideoTestArea(this.root, this.videos, this.sizeScale);

  final String root;
  final List<ExpectedVideo> videos;
  final int sizeScale;

  String get filesDir => p.join(root, 'files');
  String get manifest => p.join(root, 'expected.json');

  /// The default rules, scaled to this area's file sizes.
  LargeOldVideoRules get rules =>
      const LargeOldVideoRules().scaledDown(sizeScale);
}

/// Builds the large & old video test area in [root]: Timmy's computer (OBS,
/// Game Bar, ShadowPlay and Fraps recordings, an editing project in
/// progress and an old one, a recording that failed to save when storage
/// ran out), phone camera rolls and chats from the other personas, broken
/// videos of every kind, and look-alikes that must not be flagged.
///
/// Dates are relative to [now] (default: the real time). A few answers
/// change with time (the recording just made stops being recent, the one
/// still being written gets judged, a clip turns a year old);
/// `expected.json` records when.
///
/// Refuses to overwrite a non-empty folder it didn't make.
Future<LargeOldVideoTestArea> buildLargeOldVideoTestArea(String root,
    {DateTime? now}) async {
  root = p.absolute(root);
  final dir = Directory(root);
  if (dir.existsSync() && dir.listSync().isNotEmpty) {
    if (!File(p.join(root, testAreaMarker)).existsSync()) {
      throw StateError('$root already exists and was not made by this tool');
    }
    dir.deleteSync(recursive: true);
  }
  Directory(p.join(root, 'files')).createSync(recursive: true);
  File(p.join(root, testAreaMarker)).writeAsStringSync('');

  final t = now ?? DateTime.now();
  final b = _Builder(p.join(root, 'files'),
      DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second));
  _plant(b);

  File(p.join(root, 'expected.json'))
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'scan': 'largeOldVideos',
    'rulesetVersion': largeOldVideoRulesetVersion,
    'scanFolder': 'files',
    'sizeScale': videoTestAreaScale,
    'videos': [for (final e in b.videos) e.toJson()],
  }));
  return LargeOldVideoTestArea(root, b.videos, videoTestAreaScale);
}

/// Reads a large & old video test area's `expected.json`.
List<ExpectedVideo> readExpectedVideos(String manifestPath) {
  final json = _manifest(manifestPath);
  return [
    for (final e in json['videos']! as List)
      ExpectedVideo.fromJson(e as Map<String, Object?>)
  ];
}

/// The size scale a test area was built at (1 if it doesn't say).
int readVideoTestAreaScale(String manifestPath) =>
    (_manifest(manifestPath)['sizeScale'] as num?)?.toInt() ?? 1;

Map<String, Object?> _manifest(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

final class _Builder {
  _Builder(this.root, this.now);
  final String root;
  final DateTime now;
  final videos = <ExpectedVideo>[];

  DateTime ago({int days = 0, int hours = 0, int minutes = 0}) =>
      now.subtract(Duration(days: days, hours: hours, minutes: minutes));

  void file(String path, List<int> bytes, DateTime modified) {
    final f = File(p.join(root, path));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    f.setLastModifiedSync(modified);
  }

  void video(String path, List<int> bytes, DateTime modified, String why,
      {String? expect,
      String? source,
      String? observation,
      DateTime? changesAt,
      String? thenExpect,
      String? thenObservation}) {
    file(path, bytes, modified);
    videos.add(ExpectedVideo(
        path: path,
        why: why,
        rule: expect,
        source: source,
        observation: observation,
        changesAt: changesAt,
        thenRule: thenExpect,
        thenObservation: thenObservation));
  }
}

/// On-disk bytes standing for [gigabytes] / [megabytes] of real video.
int _gb(double gigabytes) => (gigabytes * 1024 * 1024).round();
int _mb(double megabytes) => (megabytes * 1024).round();

String _pad(int n) => n.toString().padLeft(2, '0');
String _ymd(DateTime t, [String sep = '']) =>
    '${t.year}$sep${_pad(t.month)}$sep${_pad(t.day)}';
String _hms(DateTime t, [String sep = '']) =>
    '${_pad(t.hour)}$sep${_pad(t.minute)}$sep${_pad(t.second)}';

/// `2024-03-14 16-02-11`: OBS, Game Bar.
String _obs(DateTime t) => '${_ymd(t, '-')} ${_hms(t, '-')}';

/// `20240706_181203`: Android camera.
String _cam(DateTime t) => '${_ymd(t)}_${_hms(t)}';

const _min = Duration(minutes: 1);

void _plant(_Builder b) {
  // --- Timmy's computer: game and desktop recordings ---------------------
  var t = b.ago(days: 600);
  b.video(
      'Videos/OBS/${_obs(t)}.mkv',
      mkvVideo(bytes: _gb(1.5), duration: _min * 25, created: t, seed: 1),
      t,
      'A 25-minute OBS gameplay recording from almost two years ago',
      expect: 'V10',
      source: 'gameplay');
  t = b.ago(days: 73);
  b.video(
      'Videos/OBS/${_obs(t)}.mkv',
      mkvVideo(bytes: _gb(2.6), duration: _min * 70, created: t, seed: 2),
      t,
      'A 70-minute stream recording from ten weeks ago: huge, not old',
      expect: 'V11',
      source: 'gameplay');
  t = b.ago(days: 50);
  b.video(
      'Videos/OBS/${_obs(t)}.mov',
      mp4Video(
          bytes: _gb(1.5),
          duration: _min * 2,
          fps: 30,
          codec: 'apcs',
          quickTime: true,
          created: t,
          seed: 3),
      t,
      'Two minutes recorded as ProRes 422 LT for editing: ~100 Mbit/s, '
          'could be re-encoded to a fraction',
      expect: 'V12',
      source: 'gameplay');
  t = b.ago(days: 45);
  b.video(
      'Videos/OBS/${_obs(t)}.mkv',
      mkvVideo(
          bytes: _gb(1.2), duration: _min, fourcc: 'ULRG', created: t, seed: 4),
      t,
      'One minute in Ut Video, the lossless codec OBS offers: oversized',
      expect: 'V12',
      source: 'gameplay');
  t = b.ago(days: 27);
  b.video(
      'Videos/Captures/Starfall Odyssey ${_obs(t)}.mp4',
      mp4Video(
          bytes: _gb(1.35), duration: _min * 12, fps: 60, created: t, seed: 5),
      t,
      'A 12-minute Xbox Game Bar clip from last month: large',
      expect: 'V13',
      source: 'gameplay');
  t = b.ago(days: 520);
  b.video(
      'Videos/NVIDIA/Starfall Odyssey/Starfall Odyssey '
          '${_ymd(t, '.')} - ${_hms(t, '.')}.02.DVR.mp4',
      mp4Video(
          bytes: _gb(1.875), duration: _min * 5, fps: 60, created: t, seed: 6),
      t,
      'A ShadowPlay instant replay at 50 Mbit/s (0.40 bits/pixel: high, but '
          'normal for game capture, so not oversized)',
      expect: 'V10',
      source: 'gameplay');
  t = b.ago(days: 630);
  b.video(
      'Videos/Fraps/Minecraft ${_obs(t)}-12.avi',
      aviVideo(
          bytes: _gb(2.25), frames: 2700, fps: 30, fourcc: 'FPS1', seed: 7),
      t,
      'A 90-second Fraps capture: old, large, huge and oversized at once; V10 '
          'wins and the others are kept as evidence',
      expect: 'V10',
      source: 'gameplay');

  // Recordings from school, copied off his phone 20 days ago.
  t = b.ago(days: 410);
  b.video(
      'Videos/School/VID_${_cam(t)}.mp4',
      mp4Video(bytes: _mb(135), duration: _min * 1.5, created: t, seed: 8),
      b.ago(days: 20),
      'A school video copied to the PC recently: the file date is new, the '
          'recording is over a year old',
      expect: 'V14',
      source: 'camera',
      observation: 'datesDisagree');
  t = b.ago(days: 416);
  b.video(
      'Videos/School/VID_${_cam(t)}.mp4',
      mp4Video(
          bytes: _mb(30),
          duration: const Duration(seconds: 30),
          created: t,
          seed: 9),
      t,
      'Old, but only 30 MB: not worth surfacing');

  // An editing project in progress: its footage is protected.
  t = b.ago(days: 40);
  b.file(
      'Videos/Projects/Starfall Montage/Starfall Montage.kdenlive',
      utf8.encode('<?xml version="1.0" encoding="utf-8"?>\n<mlt>\n'
          ' <producer id="producer0">\n'
          '  <property name="resource">C:/Users/Timmy/Videos/Projects/'
          'Starfall Montage/raw_boss_fight.mkv</property>\n'
          ' </producer>\n</mlt>\n'),
      b.ago(days: 2));
  b.video(
      'Videos/Projects/Starfall Montage/raw_boss_fight.mkv',
      mkvVideo(bytes: _gb(2.2), duration: _min * 50, created: t, seed: 10),
      t,
      'Huge, but the montage he edited two days ago uses it',
      observation: 'activeProject');
  b.video(
      'Videos/Projects/Starfall Montage/raw_intro.mkv',
      mkvVideo(bytes: _gb(0.9), duration: _min * 20, created: t, seed: 11),
      t,
      'In the project folder, but the project never uses it: large',
      expect: 'V13');

  // An abandoned Premiere project doesn't protect anything.
  t = b.ago(days: 420);
  b.file(
      'Videos/Projects/Old Montage/Old Montage.prproj',
      const GZipEncoder().encodeBytes(
          utf8.encode('<?xml version="1.0"?><PremiereData><Media><FilePath>'
              'D:\\Footage\\clip_a.mp4</FilePath></Media></PremiereData>')),
      b.ago(days: 400));
  b.video(
      'Videos/Projects/Old Montage/clip_a.mp4',
      mp4Video(bytes: _gb(0.7), duration: _min * 3, created: t, seed: 12),
      t,
      'Used by a project last opened 400 days ago: old and large',
      expect: 'V10');

  // A DaVinci Resolve project (a ZIP the scan can't search) protects its
  // folder.
  t = b.ago(days: 60);
  b.file('Videos/Projects/Vlog/Vlog.drp',
      zipArchive({'project.xml': '<SyncDocument/>'}), b.ago(days: 5));
  b.video(
      'Videos/Projects/Vlog/footage/A001_C002.mov',
      mp4Video(
          bytes: _gb(1.1),
          duration: _min * 2,
          width: 3840,
          height: 2160,
          quickTime: true,
          created: t,
          seed: 13),
      t,
      'Footage next to a Resolve project changed five days ago',
      observation: 'activeProject');

  // Just recorded: never suggested while recent.
  t = b.ago(days: 1);
  b.video(
      'Videos/OBS/${_obs(t)}.mkv',
      mkvVideo(bytes: _gb(2.4), duration: _min * 60, created: t, seed: 14),
      t,
      "Yesterday's recording: huge, but too recent to suggest",
      observation: 'recent',
      changesAt: t.add(const Duration(days: 14)),
      thenExpect: 'V11');
  t = b.ago(days: 3);
  b.video(
      'Videos/Exports/Starfall Montage - final.mp4',
      mp4Video(
          bytes: _gb(0.6), duration: _min * 10, fps: 60, created: t, seed: 15),
      t,
      'The export he is about to upload',
      observation: 'recent',
      changesAt: t.add(const Duration(days: 14)),
      thenExpect: 'V13');

  // Still recording right now.
  t = b.ago(minutes: 20);
  final writing = b.ago(minutes: 2);
  b.video(
      'Videos/OBS/${_obs(t)}.mkv',
      mkvVideo(
          bytes: _gb(0.3),
          duration: _min * 20,
          created: t,
          finalized: false,
          seed: 16),
      writing,
      'OBS is still writing this one (modified two minutes ago)',
      observation: 'stillWriting',
      changesAt: writing.add(const Duration(minutes: 10)),
      thenExpect: 'V04');

  // Timmy's scenario: storage ran out while saving.
  t = b.ago(hours: 3);
  b.video(
      'Videos/OBS/${_obs(t)}.mkv',
      mkvVideo(
          bytes: _gb(1.2),
          duration: _min * 40,
          created: t,
          finalized: false,
          keep: (_gb(1.2) * 0.7).round(),
          seed: 17),
      t,
      'The recording that ran out of storage: never finalised, the end cut '
          'off',
      expect: 'V04',
      source: 'gameplay');
  b.video(
      'Videos/Captures/Starfall Odyssey ${_obs(t.add(const Duration(minutes: 41)))}.mp4',
      mp4Video(
          bytes: _gb(0.8),
          duration: _min * 7,
          fps: 60,
          created: t,
          index: false,
          seed: 18),
      t.add(const Duration(minutes: 48)),
      'A Game Bar clip saved when storage was full: no index (the empty & '
          'unreadable scan reports it)',
      expect: 'U06',
      source: 'gameplay');

  // Other things on his PC.
  t = b.ago(days: 200);
  b.video(
      'Videos/Movies/Night Run (2019) 1080p.mkv',
      mkvVideo(
          bytes: _gb(2.1),
          duration: _min * 104,
          fps: 24,
          writingApp: 'mkvmerge v81.0',
          muxingApp: 'libebml v1.4.4 + libmatroska v1.7.1',
          seed: 19),
      t,
      'A downloaded film with no recording date: dated by the file, huge',
      expect: 'V11');
  t = b.ago(days: 30);
  b.video(
      'Downloads/tutorial_part2.mkv',
      mkvVideo(
          bytes: _gb(0.9),
          duration: _min * 35,
          fps: 30,
          writingApp: 'mkvmerge v80.0',
          keep: (_gb(0.9) * 0.4).round(),
          seed: 20),
      t,
      'A download that stopped at 40%: the header promises far more than is '
          'there',
      expect: 'V02',
      source: 'download');
  t = b.ago(days: 120);
  b.video(
      'Videos/OBS/${_obs(t)}.mkv',
      mkvVideo(
          bytes: _gb(1), duration: Duration.zero, created: t, clusters: false),
      t,
      'Recording started and stopped at once: headers, no frames',
      expect: 'V01',
      source: 'gameplay');
  t = b.ago(days: 250);
  b.video(
      'Videos/Recovered/clip_0007.mp4',
      mp4Video(
          bytes: _gb(0.3),
          duration: _min * 2,
          created: t,
          sttsExtra: 120,
          seed: 21),
      t,
      'Rescued by a recovery tool: its frame tables disagree',
      expect: 'V03');
  t = b.ago(days: 900);
  b.video(
      'Videos/Webcam/capture_0001.avi',
      aviVideo(
          bytes: 4096, frames: 0, fps: 30, fourcc: 'MJPG', emptyMovi: true),
      t,
      'A webcam capture with no frames',
      expect: 'V01');
  t = b.ago(days: 10);
  b.video('Videos/Captures/Starfall Odyssey ${_obs(t)}.mp4', const [], t,
      'A 0-byte Game Bar clip',
      expect: 'E01', source: 'gameplay');
  t = b.ago(days: 15);
  b.video(
      'Downloads/speedrun_wr.mp4.crdownload',
      mp4Video(bytes: _mb(400), duration: _min * 9, created: t, seed: 22)
          .sublist(0, _mb(120)),
      t,
      'A download Chrome never finished',
      expect: 'U03',
      source: 'download');
  b.video('Videos/OneDrive/Family BBQ.mp4', Uint8List(_mb(50)), b.ago(days: 90),
      'A cloud placeholder that never synced: all zero bytes',
      expect: 'U04');
  b.video(
      'Android/data/com.starfall.game/files/cutscenes/intro.mp4',
      mp4Video(
          bytes: _gb(0.8),
          duration: _min * 4,
          created: b.ago(days: 500),
          seed: 23),
      b.ago(days: 500),
      "A game's own cut-scene: deleting it would break the game",
      observation: 'appData');
  t = b.ago(days: 365 * 3);
  b.video(
      'Videos/Camcorder/00012.MTS',
      mpegTs(_gb(1.3), seed: 24),
      t,
      'Camcorder footage in a format the scan doesn\'t open: judged by size '
          'and file date',
      expect: 'V10',
      observation: 'notParsed');
  t = b.ago(days: 365 * 10);
  b.video('Videos/Old/Family Christmas 2015.wmv', asfVideo(_gb(0.65), seed: 25),
      t, 'A Windows Media video from ten years ago',
      expect: 'V10', observation: 'notParsed');

  // --- Phones: Gerald, Alexa, Jasmine, Ethan ------------------------------
  t = b.ago(days: 840);
  b.video(
      'DCIM/Camera/VID_${_cam(t)}.mp4',
      mp4Video(
          bytes: _gb(1.08),
          duration: _min * 3,
          width: 3840,
          height: 2160,
          created: t,
          indexFirst: true,
          seed: 26),
      t,
      "Gerald's 4K clip of mini golf two years ago (48 Mbit/s: normal for a "
          'phone)',
      expect: 'V10',
      source: 'camera');
  t = b.ago(days: 47);
  b.video(
      'DCIM/Camera/PXL_${_cam(t)}123.mp4',
      mp4Video(
          bytes: _gb(0.72),
          duration: _min * 2,
          width: 3840,
          height: 2160,
          created: t,
          indexFirst: true,
          seed: 27),
      t,
      "Alexa's Yosemite clip from last month: large",
      expect: 'V13',
      source: 'camera');
  t = b.ago(days: 340);
  b.video(
      'DCIM/Camera/PXL_${_cam(t)}456.mp4',
      mp4Video(
          bytes: _gb(0.8),
          duration: _min * 2,
          width: 3840,
          height: 2160,
          created: t,
          indexFirst: true,
          seed: 28),
      t,
      'Eleven months old: large now, old and large in 25 days',
      expect: 'V13',
      source: 'camera',
      changesAt: t.add(const Duration(days: 365)),
      thenExpect: 'V10');
  t = b.ago(days: 52);
  b.video(
      'DCIM/Camera/${_cam(t)}.mp4',
      mp4Video(bytes: _mb(130), duration: _min, created: t, seed: 29),
      t,
      'A one-minute Samsung clip: neither large nor old');
  t = b.ago(days: 30);
  b.video(
      'DCIM/Camera/VID_${_cam(t)}.mp4',
      mp4Video(
          bytes: _mb(40),
          duration: const Duration(seconds: 20),
          created: t,
          seed: 30),
      t,
      'A short recent clip');
  t = b.ago(days: 90);
  b.video(
      'DCIM/Camera/VID_${_cam(t)}.mp4',
      mp4Video(
          bytes: _mb(4),
          duration: const Duration(seconds: 12),
          created: t,
          noSamples: true,
          seed: 31),
      t,
      'The camera app saved an empty clip when storage filled up',
      expect: 'V01',
      source: 'camera');
  t = b.ago(days: 900);
  b.video(
      'DCIM/Camera/IMG_0219.MOV',
      mp4Video(
          bytes: _gb(2.1),
          duration: _min * 5,
          width: 3840,
          height: 2160,
          fps: 60,
          codec: 'hvc1',
          quickTime: true,
          created: t,
          indexFirst: true,
          seed: 32),
      b.ago(days: 6),
      'An iPhone 4K60 video re-downloaded from iCloud last week: recorded '
          'two and a half years ago',
      expect: 'V10',
      source: 'camera',
      observation: 'datesDisagree');
  t = b.ago(days: 700);
  b.file('DCIM/Camera/IMG_4412.HEIC', heifStill(), t);
  b.video(
      'DCIM/Camera/IMG_4412.MOV',
      mp4Video(
          bytes: _mb(3),
          duration: const Duration(seconds: 3),
          quickTime: true,
          created: t,
          indexFirst: true,
          seed: 33),
      t,
      'The movie half of a Live Photo');
  t = b.ago(days: 200);
  b.video(
      'DCIM/GoPro/GX010042.MP4',
      mp4Video(
          bytes: _gb(1.2),
          duration: _min * 2,
          width: 3840,
          height: 2160,
          created: t,
          indexFirst: true,
          mdatToEnd: true,
          keep: (_gb(1.2) * 0.4).round(),
          seed: 34),
      t,
      'Copied off the camera card when it ran out of space: the index lists '
          'frames the file no longer has',
      expect: 'V02',
      source: 'camera');
  b.video(
      'DCIM/GoPro/GX010051.MP4',
      mp4Video(
          bytes: _gb(0.3),
          duration: _min,
          created: DateTime.utc(1970),
          indexFirst: true,
          seed: 35),
      b.ago(days: 400),
      "A GoPro whose clock was never set: the container date is ignored, "
          'the file date says old',
      expect: 'V14',
      observation: 'badMetadataDate');

  const wa = 'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video';
  t = b.ago(days: 670);
  b.video(
      '$wa/VID-${_ymd(t)}-WA0001.mp4',
      mp4Video(
          bytes: _mb(160),
          duration: _min * 3,
          width: 848,
          height: 480,
          created: t,
          indexFirst: true,
          seed: 36),
      t,
      'A long video someone sent in a group chat two years ago',
      expect: 'V14',
      source: 'messaging');
  t = b.ago(days: 700);
  b.video(
      '$wa/VID-${_ymd(t)}-WA0007.mp4',
      mp4Video(
          bytes: _mb(16),
          duration: const Duration(seconds: 30),
          width: 848,
          height: 480,
          created: t,
          indexFirst: true,
          seed: 37),
      t,
      'A short shared clip: old but small');
  t = b.ago(days: 530);
  b.video(
      'Download/Telegram/video_${_ymd(t, '-')}_${_hms(t, '-')}.mp4',
      mp4Video(
          bytes: _mb(300),
          duration: _min * 6,
          width: 1280,
          height: 720,
          created: t,
          seed: 38),
      t,
      'A video saved from a Telegram channel',
      expect: 'V14',
      source: 'messaging');
  t = b.ago(days: 400);
  b.video(
      'Movies/Screen recordings/Screen_Recording_${_ymd(t)}-${_hms(t)}_Instagram.mp4',
      mp4Video(
          bytes: _mb(250),
          duration: _min * 4,
          width: 1080,
          height: 2340,
          created: t,
          seed: 39),
      t,
      'A screen recording of Instagram from last year',
      expect: 'V14',
      source: 'screenRecording');
  t = b.ago(days: 450);
  b.video(
      'DCIM/100APPLE/RPReplay_Final${t.millisecondsSinceEpoch ~/ 1000}.mp4',
      mp4Video(
          bytes: _mb(150),
          duration: _min * 2,
          width: 1170,
          height: 2532,
          seed: 40),
      t,
      'An iPhone screen recording: dated by the Unix time in its name',
      expect: 'V14',
      source: 'screenRecording');
  t = b.ago(days: 60);
  b.video(
      'Weddings/Smith/C0001.MP4',
      mp4Video(
          bytes: _gb(6),
          duration: _min * 8,
          width: 3840,
          height: 2160,
          created: t,
          indexFirst: true,
          seed: 41),
      t,
      "Jasmine's 4K ceremony footage: huge",
      expect: 'V11',
      source: 'camera');
  t = b.ago(days: 550);
  b.video(
      'Download/training_webinar_2023.mp4',
      mp4Video(
          bytes: _gb(0.9),
          duration: _min * 60,
          width: 1280,
          height: 720,
          fps: 15,
          created: t,
          seed: 42),
      t,
      "Ethan's recorded training webinar from last year",
      expect: 'V10',
      source: 'download');
}
