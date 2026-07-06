import 'package:chirp/chirp.dart';

/// Contrast-verified ANSI palette.
///
/// Chirp bakes colors to fixed 256-color codes (no terminal-palette remap),
/// so adaptivity comes from the picks themselves: every color here passes
/// WCAG contrast >= 3.0 against all four target backgrounds —
/// solarized light `#fdf6e3`, solarized dark `#002b36`, soft gray light
/// `#f2f0eb`, and soft gray dark `#1e1e1e`.
///
/// The guarantee is enforced by `test/palette_contrast_test.dart`; sweep
/// candidates with `dart run tool/contrast_report.dart` before changing any
/// pick. Severity owns the red/orange/hot-pink band exclusively — no layer
/// color may reuse it, so a glance at hue always separates *where* from
/// *how bad*.
abstract final class LogPalette {
  /// Severity above `error` — `critical` and `wtf`.
  static const ConsoleColor critical = Ansi256.deepPink1_198;

  /// Severity `error`.
  static const ConsoleColor error = Ansi256.red1_196;

  /// Severity `warning` (and custom levels between warning and error).
  static const ConsoleColor warning = Ansi256.darkOrange3_166;

  /// Severity `success`.
  static const ConsoleColor success = Ansi256.springGreen4_29;

  /// Body text of rendered errors — softer than the [error] heading.
  static const ConsoleColor errorBody = Ansi256.indianRed_167;

  /// `LogLayer.app` badge/gutter color.
  static const ConsoleColor app = Ansi256.deepSkyBlue3_31;

  /// `LogLayer.state` badge/gutter color.
  static const ConsoleColor state = Ansi256.dodgerBlue1_33;

  /// `LogLayer.route` badge/gutter color.
  static const ConsoleColor route = Ansi256.turquoise4_30;

  /// `LogLayer.ui` badge/gutter color.
  static const ConsoleColor ui = Ansi256.magenta2_165;

  /// `LogLayer.network` badge/gutter color.
  static const ConsoleColor network = Ansi256.slateBlue1_99;

  /// `LogLayer.storage` badge/gutter color.
  static const ConsoleColor storage = Ansi256.yellow4_100;

  /// `LogLayer.auth` badge/gutter color.
  static const ConsoleColor auth = Ansi256.hotPink2_169;

  /// `LogLayer.analytics` badge/gutter color.
  static const ConsoleColor analytics = Ansi256.magenta3_164;

  /// `LogLayer.platform` badge/gutter color.
  static const ConsoleColor platform = Ansi256.grey54_245;

  /// Badge/gutter color per pre-defined layer name.
  static const domains = <String, ConsoleColor>{
    'App': app,
    'State': state,
    'Route': route,
    'UI': ui,
    'Network': network,
    'Storage': storage,
    'Auth': auth,
    'Analytics': analytics,
    'Platform': platform,
  };

  /// Fallback pool for layers not in [domains]: stable FNV-1a hash of the
  /// layer name indexes into this list, so a custom layer keeps its color
  /// across runs and isolates. Same contrast guarantee as the named picks;
  /// severity-band hues (red/orange/hot-pink) are deliberately absent.
  static const hashPool = <ConsoleColor>[
    IndexedColor(28),
    IndexedColor(30),
    IndexedColor(31),
    IndexedColor(32),
    IndexedColor(33),
    IndexedColor(63),
    IndexedColor(64),
    IndexedColor(65),
    IndexedColor(66),
    IndexedColor(67),
    IndexedColor(68),
    IndexedColor(97),
    IndexedColor(98),
    IndexedColor(99),
    IndexedColor(100),
    IndexedColor(101),
    IndexedColor(102),
    IndexedColor(103),
    IndexedColor(129),
    IndexedColor(132),
    IndexedColor(133),
    IndexedColor(134),
    IndexedColor(135),
    IndexedColor(162),
    IndexedColor(163),
    IndexedColor(164),
    IndexedColor(165),
    IndexedColor(169),
    IndexedColor(244),
    IndexedColor(245),
  ];

  /// Severity color, or `null` for levels that should render in the
  /// terminal's default foreground (trace/debug/info/notice).
  static ConsoleColor? levelColor(ChirpLogLevel level) {
    if (level > .error) return critical;
    if (level >= .error) return error;
    if (level >= .warning) return warning;
    if (level == .success) return success;
    return null;
  }

  /// Stable color for an arbitrary layer [name] — [domains] first, then the
  /// [hashPool] via FNV-1a (Dart's `String.hashCode` is not guaranteed
  /// stable across runs).
  static ConsoleColor colorFor(String? name) {
    if (name == null) return app;
    final listed = domains[name];
    if (listed != null) return listed;
    return hashPool[_fnv1a(name) % hashPool.length];
  }

  static int _fnv1a(String s) {
    var hash = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}
