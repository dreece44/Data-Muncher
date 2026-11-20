/// Where a video came from, from its name and folder. Used for the reason
/// users see and to break review batches down.
enum VideoSource {
  camera('camera video', 'Camera'),
  screenRecording('screen recording', 'Screen recordings'),
  gameplay('game recording', 'Game & desktop recordings'),
  messaging('video shared in a chat', 'Shared in chats'),
  download('downloaded video', 'Downloads'),
  other('video', 'Other');

  const VideoSource(this.noun, this.label);

  /// "a 1.2 GB camera video".
  final String noun;

  /// Batch breakdown label.
  final String label;
}

/// How a recording app or camera names its files. Matched against the file
/// name without its extension, ignoring case.
///
/// Listed in `docs/LARGE_OLD_VIDEO_RULESET.md` §5; keep the two in sync.
final class VideoNamePattern {
  const VideoNamePattern(this.tool, this.source, this.pattern, {this.folders});

  final String tool;
  final VideoSource source;
  final String pattern;

  /// When set, the pattern only counts directly inside one of these folders
  /// (lower case): `<game> <date>` and `<date>_<time>` are too loose to trust
  /// anywhere else.
  final Set<String>? folders;

  RegExp get regExp => RegExp('^(?:$pattern)\$', caseSensitive: false);
}

// Date and time pieces. Loose about separators unless a tool is strict.
const _date = r'(?<y>\d{4})-?(?<mo>\d{2})-?(?<d>\d{2})';
const _time = r'(?<h>\d{2})[-.:]?(?<mi>\d{2})[-.:]?(?<s>\d{2})';
const _dashDate = r'(?<y>\d{4})-(?<mo>\d{2})-(?<d>\d{2})';
const _dashTime = r'(?<h>\d{2})-(?<mi>\d{2})-(?<s>\d{2})';
const _dotDate = r'(?<y>\d{4})\.(?<mo>\d{2})\.(?<d>\d{2})';

const defaultVideoNamePatterns = <VideoNamePattern>[
  // --- Phones and cameras
  // VID_20240706_181203.mp4 (Android camera), VID_20240706_181203_1.mp4.
  VideoNamePattern('Android camera', VideoSource.camera,
      'vid_${_date}_$_time(?:_\\d+)?(?:~\\d+)?'),
  // PXL_20260915_143005123.mp4, PXL_20260915_143005123.TS.mp4 (Pixel).
  VideoNamePattern('Pixel camera', VideoSource.camera,
      'pxl_${_date}_$_time\\d{0,3}(?:\\..+)?'),
  // 20260910_101500.mp4 (Samsung camera), only in a Camera folder.
  VideoNamePattern(
      'Samsung camera', VideoSource.camera, '${_date}_$_time(?:\\(\\d+\\))?',
      folders: {'camera'}),
  // IMG_0219.MOV, IMG_E0219.MOV (edited) — no date in the name.
  VideoNamePattern(
      'iPhone camera', VideoSource.camera, r'img_e?\d{4}(?: \(\d+\))?'),
  // GX010042.MP4, GH010042.MP4, GOPR0042.MP4.
  VideoNamePattern('GoPro', VideoSource.camera, r'g[hx]\d{6}|gopr\d{4}'),
  // DJI_0042.MP4, DJI_20260512143011_0001_D.MP4.
  VideoNamePattern(
      'DJI', VideoSource.camera, 'dji_(?:$_date${_time}_)?\\d{4}(?:_[a-z])?'),
  // C0001.MP4 (Sony), MVI_1234.MOV (Canon), MAH01234.MP4 (Sony),
  // DSC_1234.MOV (Nikon), P1000123.MP4 (Panasonic).
  VideoNamePattern('camera', VideoSource.camera,
      r'c\d{4}|mvi_\d{4}|mah\d{5}|dsc_\d{4}|p\d{7}'),

  // --- Screen recorders
  // Screen_Recording_20250412-201011_Instagram.mp4 (Samsung).
  VideoNamePattern('Samsung screen recorder', VideoSource.screenRecording,
      'screen_recording_$_date[-_]$_time(?:_(?<app>.+))?'),
  // screen-20250412-201011.mp4 (Pixel).
  VideoNamePattern('Pixel screen recorder', VideoSource.screenRecording,
      'screen-$_date-$_time(?:-\\d+)?'),
  // Screenrecorder-2025-04-12-20-10-11-123.mp4 (Xiaomi).
  VideoNamePattern('Xiaomi screen recorder', VideoSource.screenRecording,
      'screenrecorder-$_dashDate-$_dashTime(?:-\\d+)?'),
  // RPReplay_Final1712345678.mp4 (iPhone): a Unix timestamp.
  VideoNamePattern('iPhone screen recording', VideoSource.screenRecording,
      r'rpreplay_final(?<unix>\d{10})(?: \(\d+\))?'),
  // Screen Recording 2025-04-12 at 8.10.11 PM.mov (macOS).
  VideoNamePattern(
      'macOS screen recording',
      VideoSource.screenRecording,
      'screen recording $_date at (?<h>\\d{1,2})\\.(?<mi>\\d{2})\\.(?<s>\\d{2})'
          '(?:[\\s  ]?[ap]m)?(?: \\(\\d+\\))?'),
  // Screen Recording 2025-04-12 201011.mp4 (Windows Snipping Tool).
  VideoNamePattern('Windows screen recording', VideoSource.screenRecording,
      'screen recording $_date $_time(?: \\(\\d+\\))?'),

  // --- Game and desktop capture
  // Starfall Odyssey 2025.06.01 - 19.22.40.02.DVR.mp4 (NVIDIA ShadowPlay).
  VideoNamePattern(
      'NVIDIA ShadowPlay',
      VideoSource.gameplay,
      '(?<app>.+?) $_dotDate - (?<h>\\d{2})\\.(?<mi>\\d{2})\\.(?<s>\\d{2})'
          '\\.\\d{2}(?:\\.dvr)?'),
  // Minecraft 2025-02-10 20-15-33-12.avi (Fraps).
  VideoNamePattern('Fraps', VideoSource.gameplay,
      '(?<app>.+?) $_dashDate $_dashTime-\\d{2}'),
  // Starfall Odyssey_replay_2025.06.01-19.22.mp4 (AMD ReLive).
  VideoNamePattern(
      'AMD ReLive',
      VideoSource.gameplay,
      '(?<app>.+?)_(?:replay_)?$_dotDate-(?<h>\\d{2})\\.(?<mi>\\d{2})'
          '(?:\\.(?<s>\\d{2}))?'),
  // bandicam 2025-02-10 20-15-33-123.mp4.
  VideoNamePattern('Bandicam', VideoSource.gameplay,
      'bandicam $_dashDate $_dashTime-\\d{3}'),
  // 2024-03-14 16-02-11.mkv, Replay 2024-03-14 16-02-11.mkv (OBS Studio).
  VideoNamePattern(
      'OBS', VideoSource.gameplay, '(?:replay )?$_dashDate $_dashTime'),
  // Starfall Odyssey 2026-10-05 21-14-03.mp4 (Xbox Game Bar), only in its
  // Captures folder.
  VideoNamePattern(
      'Xbox Game Bar', VideoSource.gameplay, '(?<app>.+) $_date $_time',
      folders: {'captures'}),

  // --- Chats
  // VID-20240203-WA0007.mp4 (WhatsApp).
  VideoNamePattern(
      'WhatsApp', VideoSource.messaging, 'vid-$_date-wa\\d{4}(?: \\(\\d+\\))?'),
  // video_2025-05-20_22-14-09.mp4 (Telegram).
  VideoNamePattern(
      'Telegram', VideoSource.messaging, 'video_${_dashDate}_$_dashTime'),
];

/// Folder names (lower case) that say where a video came from when its name
/// doesn't. The nearest matching folder wins.
const videoSourceFolders = <String, VideoSource>{
  'dcim': VideoSource.camera,
  'camera': VideoSource.camera,
  'screen recordings': VideoSource.screenRecording,
  'screenrecorder': VideoSource.screenRecording,
  'screenrecords': VideoSource.screenRecording,
  'captures': VideoSource.gameplay,
  'obs': VideoSource.gameplay,
  'nvidia': VideoSource.gameplay,
  'shadowplay': VideoSource.gameplay,
  'fraps': VideoSource.gameplay,
  'bandicam': VideoSource.gameplay,
  'whatsapp video': VideoSource.messaging,
  'telegram': VideoSource.messaging,
  'telegram video': VideoSource.messaging,
  'download': VideoSource.download,
  'downloads': VideoSource.download,
};

/// What a matching name says.
final class VideoName {
  const VideoName(this.tool, this.source, {this.app, this.recorded});

  final String tool;
  final VideoSource source;

  /// The game or app named in the file, e.g. `Starfall Odyssey`.
  final String? app;

  /// When it was recorded, from the name.
  final DateTime? recorded;
}

/// Matches [displayName] (with its extension) in [folders] (lower-case
/// folder names above the file, nearest last) against [patterns].
VideoName? matchVideoName(
    String displayName, List<String> folders, List<VideoNamePattern> patterns) {
  final dot = displayName.lastIndexOf('.');
  final stem = dot > 0 ? displayName.substring(0, dot) : displayName;
  for (final pattern in patterns) {
    if (pattern.folders != null &&
        (folders.isEmpty || !pattern.folders!.contains(folders.last))) {
      continue;
    }
    final m = pattern.regExp.firstMatch(stem);
    if (m == null) continue;
    String? group(String name) =>
        m.groupNames.contains(name) ? m.namedGroup(name) : null;
    int? n(String name) => int.tryParse(group(name) ?? '');
    DateTime? recorded;
    final unix = n('unix');
    final y = n('y'), mo = n('mo'), d = n('d');
    if (unix != null) {
      recorded = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    } else if (y != null &&
        mo != null &&
        d != null &&
        mo >= 1 &&
        mo <= 12 &&
        d >= 1 &&
        d <= 31) {
      var h = n('h') ?? 0;
      final half = RegExp(r'([ap])m(?: \(\d+\))?$', caseSensitive: false)
          .firstMatch(stem)
          ?.group(1)
          ?.toLowerCase();
      if (half == 'p' && h < 12) h += 12;
      if (half == 'a' && h == 12) h = 0;
      recorded = DateTime(y, mo, d, h, n('mi') ?? 0, n('s') ?? 0);
    }
    return VideoName(pattern.tool, pattern.source,
        app: group('app'), recorded: recorded);
  }
  return null;
}

/// The source the nearest telling folder says, or [VideoSource.other].
VideoSource sourceFromFolders(List<String> folders) {
  for (final f in folders.reversed) {
    final s = videoSourceFolders[f];
    if (s != null) return s;
  }
  return VideoSource.other;
}
