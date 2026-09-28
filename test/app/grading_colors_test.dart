import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app_colors.dart';

double _linear(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) => 0.2126 * _linear(c.r) + 0.7152 * _linear(c.g) + 0.0722 * _linear(c.b);

double _contrast(Color a, Color b) {
  final double x = _luminance(a), y = _luminance(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// OKLab, the perceptual space the grading colours were chosen in.
(double, double, double) _oklab(Color c) {
  final double r = _linear(c.r), g = _linear(c.g), b = _linear(c.b);
  final double l = math.pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1 / 3).toDouble();
  final double m = math.pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1 / 3).toDouble();
  final double s = math.pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1 / 3).toDouble();
  return (
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  );
}

/// How far apart two colours look, where about 2 is just noticeable.
double _difference(Color x, Color y) {
  final (double l1, double a1, double b1) = _oklab(x);
  final (double l2, double a2, double b2) = _oklab(y);
  return 100 * math.sqrt(math.pow(l1 - l2, 2) + math.pow(a1 - a2, 2) + math.pow(b1 - b2, 2));
}

/// How colourful: 0 is grey.
double _chroma(Color c) {
  final (_, double a, double b) = _oklab(c);
  return math.sqrt(a * a + b * b);
}

void main() {
  const List<ToneKind> grading = <ToneKind>[ToneKind.success, ToneKind.warning, ToneKind.danger, ToneKind.bonus];

  for (final (String theme, AppColors c, double fillApart, double borderContrast)
      in <(String, AppColors, double, double)>[('light', AppColors.light, 5, 1.65), ('dark', AppColors.dark, 6, 2.0)]) {
    group('$theme grading colours', () {
      for (final ToneKind kind in grading) {
        final Tone t = c.tone(kind);

        test('${kind.name}: the chip is seen against the card, and its text reads', () {
          expect(_difference(t.fill, c.surface), greaterThanOrEqualTo(fillApart), reason: 'fill blends into the card');
          expect(_contrast(t.border, c.surface), greaterThanOrEqualTo(borderContrast), reason: 'border too faint');
          expect(_contrast(t.foreground, t.fill), greaterThanOrEqualTo(5), reason: 'text on its fill');
          expect(_contrast(t.foreground, c.surface), greaterThanOrEqualTo(4.5), reason: 'text on the card');
        });

        test('${kind.name}: the fill carries its hue but stays soft', () {
          expect(_chroma(t.fill), greaterThanOrEqualTo(0.02), reason: 'fill has no visible hue');
          expect(_chroma(t.fill), lessThanOrEqualTo(0.045), reason: 'fill is too loud');
        });
      }
    });
  }
}
