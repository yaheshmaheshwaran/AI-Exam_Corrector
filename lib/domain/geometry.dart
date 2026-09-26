import 'dart:math' as math;

import 'package:exam_corrector/domain/json_read.dart';

/// A rectangle on a page, in fractions of the page's width and height.
///
/// Normalised so a region means the same thing whatever resolution the page
/// was rendered at: a box found on a 150 dpi preview sent to the vision model
/// lands on exactly the same ink in the 300 dpi image the teacher inspects.
class NormalizedBox {
  const NormalizedBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  /// From pixel coordinates on a page of the given size.
  factory NormalizedBox.fromPixels({
    required num x,
    required num y,
    required num width,
    required num height,
    required num pageWidth,
    required num pageHeight,
  }) {
    if (pageWidth <= 0 || pageHeight <= 0) return empty;
    return NormalizedBox(
      x: x / pageWidth,
      y: y / pageHeight,
      width: width / pageWidth,
      height: height / pageHeight,
    ).clamped();
  }

  /// From the `[ymin, xmin, ymax, xmax]` box on a 0–1000 scale that Gemini
  /// vision models return for detected objects.
  static NormalizedBox? fromBox2d(Object? raw) {
    final List<Object?> values = readList(raw);
    if (values.length != 4) return null;
    final List<double> numbers = <double>[];
    for (final Object? value in values) {
      final double? number = readDouble(value);
      if (number == null) return null;
      numbers.add(number / 1000);
    }
    final double top = math.min(numbers[0], numbers[2]);
    final double bottom = math.max(numbers[0], numbers[2]);
    final double left = math.min(numbers[1], numbers[3]);
    final double right = math.max(numbers[1], numbers[3]);
    final NormalizedBox box = NormalizedBox(
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    ).clamped();
    return box.isEmpty ? null : box;
  }

  static const NormalizedBox empty =
      NormalizedBox(x: 0, y: 0, width: 0, height: 0);

  static const NormalizedBox fullPage =
      NormalizedBox(x: 0, y: 0, width: 1, height: 1);

  final double x;
  final double y;
  final double width;
  final double height;

  double get right => x + width;
  double get bottom => y + height;
  double get area => width * height;
  double get centerX => x + width / 2;
  double get centerY => y + height / 2;
  bool get isEmpty => width <= 0 || height <= 0;

  /// The box expressed in pixels of a page of the given size.
  ({int x, int y, int width, int height}) toPixels(int pageWidth, int pageHeight) {
    return (
      x: (x * pageWidth).round(),
      y: (y * pageHeight).round(),
      width: (width * pageWidth).round(),
      height: (height * pageHeight).round(),
    );
  }

  /// Keeps the box inside the page.
  NormalizedBox clamped() {
    final double left = x.clamp(0.0, 1.0);
    final double top = y.clamp(0.0, 1.0);
    final double rightEdge = right.clamp(0.0, 1.0);
    final double bottomEdge = bottom.clamp(0.0, 1.0);
    return NormalizedBox(
      x: left,
      y: top,
      width: math.max(0, rightEdge - left),
      height: math.max(0, bottomEdge - top),
    );
  }

  NormalizedBox expanded(double margin) => NormalizedBox(
        x: x - margin,
        y: y - margin,
        width: width + margin * 2,
        height: height + margin * 2,
      ).clamped();

  NormalizedBox union(NormalizedBox other) {
    if (isEmpty) return other;
    if (other.isEmpty) return this;
    final double left = math.min(x, other.x);
    final double top = math.min(y, other.y);
    return NormalizedBox(
      x: left,
      y: top,
      width: math.max(right, other.right) - left,
      height: math.max(bottom, other.bottom) - top,
    );
  }

  double intersectionArea(NormalizedBox other) {
    final double w = math.min(right, other.right) - math.max(x, other.x);
    final double h = math.min(bottom, other.bottom) - math.max(y, other.y);
    return (w <= 0 || h <= 0) ? 0 : w * h;
  }

  /// How much of this box lies inside [other], 0..1.
  double coverageBy(NormalizedBox other) =>
      area <= 0 ? 0 : intersectionArea(other) / area;

  double iou(NormalizedBox other) {
    final double overlap = intersectionArea(other);
    final double total = area + other.area - overlap;
    return total <= 0 ? 0 : overlap / total;
  }

  List<double> toJson() => <double>[
        _round(x),
        _round(y),
        _round(width),
        _round(height),
      ];

  static NormalizedBox? fromJson(Object? raw) {
    final List<Object?> values = readList(raw);
    if (values.length != 4) return null;
    final List<double> numbers = <double>[
      for (final Object? value in values) readDouble(value) ?? double.nan,
    ];
    if (numbers.any((double n) => n.isNaN)) return null;
    return NormalizedBox(
      x: numbers[0],
      y: numbers[1],
      width: numbers[2],
      height: numbers[3],
    ).clamped();
  }

  static double _round(double value) => (value * 100000).round() / 100000;

  @override
  bool operator ==(Object other) =>
      other is NormalizedBox &&
      (other.x - x).abs() < 1e-6 &&
      (other.y - y).abs() < 1e-6 &&
      (other.width - width).abs() < 1e-6 &&
      (other.height - height).abs() < 1e-6;

  @override
  int get hashCode => Object.hash(
        (x * 1e5).round(),
        (y * 1e5).round(),
        (width * 1e5).round(),
        (height * 1e5).round(),
      );

  @override
  String toString() => 'NormalizedBox(${x.toStringAsFixed(3)}, '
      '${y.toStringAsFixed(3)}, ${width.toStringAsFixed(3)}, '
      '${height.toStringAsFixed(3)})';
}
