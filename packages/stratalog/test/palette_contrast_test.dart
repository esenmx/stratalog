import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

import '../tool/contrast_report.dart' show contrast, luminance;

/// The palette's core promise, enforced: every color stays readable on the
/// four target backgrounds. Sweep replacements with
/// `dart run tool/contrast_report.dart` before changing a pick.
const _backgrounds = <String, (int, int, int)>{
  'solarized light #fdf6e3': (0xfd, 0xf6, 0xe3),
  'soft gray light #f2f0eb': (0xf2, 0xf0, 0xeb),
  'solarized dark #002b36': (0x00, 0x2b, 0x36),
  'soft gray dark #1e1e1e': (0x1e, 0x1e, 0x1e),
};

const _minRatio = 3.0;

void main() {
  final foregrounds = <String, ConsoleColor>{
    ...LogPalette.domains,
    'level:critical': LogPalette.critical,
    'level:error': LogPalette.error,
    'level:warning': LogPalette.warning,
    'level:success': LogPalette.success,
    'errorBody': LogPalette.errorBody,
    for (final (i, c) in LogPalette.hashPool.indexed) 'hashPool[$i]': c,
  };

  for (final MapEntry(key: bgName, value: (r, g, b)) in _backgrounds.entries) {
    test('palette passes >= $_minRatio contrast on $bgName', () {
      final bgLum = luminance(r, g, b);
      final failures = <String>[
        for (final MapEntry(key: name, value: color) in foregrounds.entries)
          if (contrast(luminance(color.r, color.g, color.b), bgLum)
              case final ratio when ratio < _minRatio)
            '$name -> ${ratio.toStringAsFixed(2)}',
      ];
      check(because: failures.join('\n'), failures).isEmpty();
    });
  }

  test('severity band hues are exclusive to severity colors', () {
    // Red/orange/hot-pink must always mean "how bad", never "which layer".
    final severity = {
      LogPalette.critical,
      LogPalette.error,
      LogPalette.warning,
      LogPalette.errorBody,
    };
    check(
      severity.intersection({
        ...LogPalette.domains.values,
        ...LogPalette.hashPool,
      }),
    ).isEmpty();
  });

  test('pre-defined layer colors are pairwise distinct', () {
    final colors = LogPalette.domains.values.toList();
    check(colors.toSet()).length.equals(colors.length);
  });

  test('levelColor colors severities; low levels keep the default', () {
    check({
      for (final level in <ChirpLogLevel>[
        .trace,
        .debug,
        .info,
        .notice,
        .success,
        .warning,
        .error,
        .critical,
        .wtf,
      ])
        level.name: LogPalette.levelColor(level),
    }).deepEquals({
      'trace': null,
      'debug': null,
      'info': null,
      'notice': null,
      'success': LogPalette.success,
      'warning': LogPalette.warning,
      'error': LogPalette.error,
      'critical': LogPalette.critical,
      'wtf': LogPalette.critical,
    });
  });

  test('resolve: override beats the declared layer color, which beats '
      'colorFor', () {
    const name = 'PaletteResolve';
    Chirp.root = ChirpLogger();
    addTearDown(() => Chirp.root = null);
    const LogLayer(name, color: Ansi256.green3_34).info('registers');

    check(LogPalette.colorFor(name)).not((it) => it.equals(Ansi256.green3_34));
    check(LogPalette.resolve(name)).equals(Ansi256.green3_34);
    check(LogPalette.resolve(name, overrides: {name: Ansi256.springGreen4_29}))
        .equals(Ansi256.springGreen4_29);
  });
}
