import 'dart:math' as math;

import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

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

double _channel(int c) {
  final s = c / 255.0;
  return s <= 0.03928
      ? s / 12.92
      : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(int r, int g, int b) =>
    0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b);

double _contrast(double l1, double l2) {
  final hi = math.max(l1, l2);
  final lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

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
      final bgLum = _luminance(r, g, b);
      final failures = <String>[
        for (final MapEntry(key: name, value: color) in foregrounds.entries)
          if (_contrast(_luminance(color.r, color.g, color.b), bgLum)
              case final ratio when ratio < _minRatio)
            '$name -> ${ratio.toStringAsFixed(2)}',
      ];
      expect(failures, isEmpty, reason: failures.join('\n'));
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
    final layerColors = [
      ...LogPalette.domains.values,
      ...LogPalette.hashPool,
    ];
    for (final color in layerColors) {
      expect(severity, isNot(contains(color)));
    }
  });

  test('pre-defined layer colors are pairwise distinct', () {
    final colors = LogPalette.domains.values.toList();
    expect(colors.toSet().length, colors.length);
  });
}
