/// How screenshot tools name their files. Each pattern is matched against
/// the file name without its extension, ignoring case. A match is S01's
/// signal; the optional `app` group names the app or game on screen.
///
/// Listed in `docs/SCREENSHOT_RULESET.md` §5 (S01); keep the two in sync.
final class ScreenshotNamePattern {
  const ScreenshotNamePattern(this.tool, this.pattern, {this.folders});

  /// The tool or platform that names files this way.
  final String tool;
  final String pattern;

  /// When set, the pattern only counts inside one of these folders (lower
  /// case). Game Bar names are just `<game> <date>`, which is too loose to
  /// trust anywhere else.
  final Set<String>? folders;

  RegExp get regExp => RegExp('^(?:$pattern)\$', caseSensitive: false);
}

// Date and time pieces, loose about the separators tools use.
const _date = r'(?<y>\d{4})-?(?<mo>\d{2})-?(?<d>\d{2})';
const _time = r'(?<h>\d{2})[-.:]?(?<mi>\d{2})[-.:]?(?<s>\d{2})';
const _space = r'[\s  ]';

const defaultScreenshotNamePatterns = <ScreenshotNamePattern>[
  // Screenshot_20260913-201500.png (Android), Screenshot_20260913-201500_Chrome.jpg
  // (Samsung adds the app), Screenshot_2026-09-13-20-15-00-123_com.whatsapp.jpg
  // (Xiaomi), Screenshot_20260913_201500.png (KDE Spectacle, older Samsung).
  ScreenshotNamePattern('Android',
      'screenshot_$_date[-_]$_time(?:[-.]\\d{1,4})?(?:_(?<app>.+))?'),
  // Screenshot 2026-09-29 at 10.02.11 AM.png (macOS 10.14+),
  // Screen Shot 2019-03-04 at 4.15.10 PM.png (older macOS), "… (2)".
  ScreenshotNamePattern(
      'macOS',
      'screen ?shot $_date at (?<h>\\d{1,2})\\.(?<mi>\\d{2})\\.(?<s>\\d{2})'
          '(?:$_space?[ap]m)?(?: \\(\\d+\\))?(?: \\d+)?'),
  // Screenshot 2026-10-06 154500.png (Windows 11 Snipping Tool).
  ScreenshotNamePattern(
      'Windows Snipping Tool', 'screenshot $_date $_time(?: \\(\\d+\\))?'),
  // Screenshot (12).png (Windows Win+PrtScn).
  ScreenshotNamePattern('Windows', r'screenshot \(\d+\)'),
  // Screenshot from 2026-10-10 09-30-00.png (GNOME).
  ScreenshotNamePattern(
      'GNOME', 'screenshot from $_date $_time(?: \\(\\d+\\))?'),
  // Starfall Odyssey 2026-10-08 21-14-03.png (Xbox Game Bar), only in its
  // Captures folder.
  ScreenshotNamePattern('Xbox Game Bar', '(?<app>.+) $_date $_time',
      folders: {'captures'}),
  // Localised Android/macOS/Windows names: Captura de pantalla 2026-…,
  // Capture d'écran 2026-…, Bildschirmfoto 2026-…, スクリーンショット 2026-…
  ScreenshotNamePattern(
      'localised',
      "(?:captura de pantalla|captura de tela|capture d.écran|bildschirmfoto|"
          'schermafbeelding|schermata|zrzut ekranu|snímek obrazovky|'
          'スクリーンショット|屏幕截图|스크린샷)[ _-]?(?:from )?$_date'
          '(?:(?: at | um | a las | à |[ _-])$_time)?.*'),
];

/// What a matching name says.
final class ScreenshotName {
  const ScreenshotName(this.tool, {this.app, this.taken});

  final String tool;

  /// The app or game named in the file, e.g. `Chrome`, `com.whatsapp`.
  final String? app;

  /// When the screenshot was taken, from the name.
  final DateTime? taken;
}

/// Matches [displayName] (with its extension) in [folders] (lower-case
/// folder names containing the file) against [patterns].
ScreenshotName? matchScreenshotName(String displayName, List<String> folders,
    List<ScreenshotNamePattern> patterns) {
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
    DateTime? taken;
    final y = n('y'), mo = n('mo'), d = n('d');
    if (y != null && mo != null && d != null && mo >= 1 && mo <= 12) {
      var h = n('h') ?? 0;
      final half =
          RegExp(r'([ap])m(?: \(\d+\))?(?: \d+)?$', caseSensitive: false)
              .firstMatch(stem)
              ?.group(1)
              ?.toLowerCase();
      if (half == 'p' && h < 12) h += 12;
      if (half == 'a' && h == 12) h = 0;
      taken = DateTime(y, mo, d, h, n('mi') ?? 0, n('s') ?? 0);
    }
    return ScreenshotName(pattern.tool, app: group('app'), taken: taken);
  }
  return null;
}

/// Words that loosely say "screenshot" in a name that no tool pattern
/// matched: `Screenshot_1.png` (Lightshot), `my screenshot.png`,
/// `screencap.png`. S03's name signal.
final looseScreenshotWords = RegExp(
    r'screen[\s_-]?shot|screen[\s_-]?cap|scrnshot|^capture[\s_(-]*\d',
    caseSensitive: false);
