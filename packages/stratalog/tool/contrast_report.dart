// Palette selection oracle: sweeps all 256 ANSI colors, reports which pass a
// minimum WCAG contrast on ALL four target backgrounds, sorted by hue so
// visually-distinct picks are easy to make.
//
// dart run tool/contrast_report.dart [minRatio]
// ignore_for_file: avoid_print, lines_longer_than_80_chars
// ignore_for_file: avoid_multiple_declarations_per_line
import 'dart:math' as math;

import 'package:chirp/chirp.dart';

const backgrounds = <String, (int, int, int)>{
  'sol-light': (0xfd, 0xf6, 0xe3),
  'soft-light': (0xf2, 0xf0, 0xeb),
  'sol-dark': (0x00, 0x2b, 0x36),
  'soft-dark': (0x1e, 0x1e, 0x1e),
};

double channel(int c) {
  final s = c / 255.0;
  return s <= 0.03928
      ? s / 12.92
      : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
}

double luminance(int r, int g, int b) =>
    0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);

double contrast(double l1, double l2) {
  final hi = math.max(l1, l2);
  final lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

double hue(int r, int g, int b) {
  final rf = r / 255.0, gf = g / 255.0, bf = b / 255.0;
  final maxC = [rf, gf, bf].reduce(math.max);
  final minC = [rf, gf, bf].reduce(math.min);
  final d = maxC - minC;
  if (d == 0) return -1; // achromatic
  double h;
  if (maxC == rf) {
    h = ((gf - bf) / d) % 6;
  } else if (maxC == gf) {
    h = (bf - rf) / d + 2;
  } else {
    h = (rf - gf) / d + 4;
  }
  return (h * 60 + 360) % 360;
}

void main(List<String> args) {
  final minRatio = args.isNotEmpty ? double.parse(args[0]) : 3.0;
  final bgLums = backgrounds.map(
    (k, v) => MapEntry(k, luminance(v.$1, v.$2, v.$3)),
  );

  final rows = <(double, String)>[];
  for (var code = 16; code < 256; code++) {
    final c = IndexedColor(code);
    final lum = luminance(c.r, c.g, c.b);
    final ratios = bgLums.map((k, bl) => MapEntry(k, contrast(lum, bl)));
    final worst = ratios.values.reduce(math.min);
    if (worst < minRatio) continue;
    final h = hue(c.r, c.g, c.b);
    final detail = ratios.entries
        .map((e) => '${e.key}=${e.value.toStringAsFixed(2)}')
        .join(' ');
    rows.add((
      h,
      'ansi$code  hue=${h.toStringAsFixed(0).padLeft(4)}  worst=${worst.toStringAsFixed(2)}  $detail',
    ));
  }
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  rows.map((r) => r.$2).forEach(print);
  print('${rows.length} colors pass >= $minRatio on all backgrounds');
}
