import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

/// The application's mark: an answer sheet under a reading beam, the lines
/// above it ticked in the margin.
///
/// Drawn by [LogoPainter] from the same geometry as assets/brand/logo.svg,
/// which is the source of the macOS and Windows app icons. The tile carries
/// its own colours, so it reads the same on light and dark surfaces.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: const LogoPainter(LogoFrame.finished),
    );
  }
}

/// One moment of the logo being drawn, for the opening screen's animation.
///
/// Every value runs from its starting state to the finished logo; the rows
/// and ticks follow the beam, so the frame is usually built with
/// [LogoFrame.fromBeam].
@immutable
class LogoFrame {
  const LogoFrame({
    required this.margin,
    required this.beamY,
    required this.row1,
    required this.row2,
    required this.tick1,
    required this.tick2,
    this.pulse = 0,
  });

  /// The rows turn to type and get their ticks as the beam passes them.
  factory LogoFrame.fromBeam({required double margin, required double beamY, double pulse = 0}) {
    double after(double from, double to) => ((beamY - from) / (to - from)).clamp(0.0, 1.0);
    return LogoFrame(
      margin: margin,
      beamY: beamY,
      row1: Curves.easeOut.transform(after(21, 31)),
      tick1: Curves.easeOut.transform(after(22, 34)),
      row2: Curves.easeOut.transform(after(36, 46)),
      tick2: Curves.easeOut.transform(after(37, 49)),
      pulse: pulse,
    );
  }

  static const LogoFrame finished = LogoFrame(
    margin: 1,
    beamY: LogoPainter.beamRest,
    row1: 1,
    row2: 1,
    tick1: 1,
    tick2: 1,
  );

  /// How much of the red margin rule is drawn, top down.
  final double margin;

  /// Where the reading beam is, in the logo's 100-unit square.
  final double beamY;

  /// 0 is handwriting, 1 is a typed line.
  final double row1;
  final double row2;

  /// How much of each margin tick is drawn.
  final double tick1;
  final double tick2;

  /// A brief brightening of the beam's glow as it settles.
  final double pulse;

  @override
  bool operator ==(Object other) =>
      other is LogoFrame &&
      other.margin == margin &&
      other.beamY == beamY &&
      other.row1 == row1 &&
      other.row2 == row2 &&
      other.tick1 == tick1 &&
      other.tick2 == tick2 &&
      other.pulse == pulse;

  @override
  int get hashCode => Object.hash(margin, beamY, row1, row2, tick1, tick2, pulse);
}

/// Paints the logo at [frame], in a 100-unit square scaled to the canvas.
class LogoPainter extends CustomPainter {
  const LogoPainter(this.frame);

  final LogoFrame frame;

  /// Where the beam rests in the finished logo.
  static const double beamRest = 50;

  static const Color _tileTop = Color(0xFFFFFDFA);
  static const Color _tileBottom = Color(0xFFF1EBE3);
  static const Color _ink = Color(0xFF3E2F23);
  static const Color _margin = Color(0xFF993324);
  static const Color _tick = Color(0xFF4E7951);
  static const Color _glow = Color(0xFFE7AF61);
  static const Color _beam = Color(0xFFE3A248);

  static final RRect _tile = RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 100, 100), const Radius.circular(23));

  static Paint _stroke(Color color, double width) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  /// A line of handwriting flattening into type: [segments] half-waves along
  /// [length], their height shrinking to nothing as [typed] reaches 1.
  static Path _row(double x, double y, int segments, double length, double typed) {
    final double amplitude = 7 * (1 - typed);
    final double step = length / segments;
    final Path path = Path()..moveTo(x, y);
    for (int i = 0; i < segments; i++) {
      final double start = x + i * step;
      path.quadraticBezierTo(start + step / 2, y + (i.isEven ? -amplitude : amplitude), start + step, y);
    }
    return path;
  }

  static void _partial(Canvas canvas, Path path, double amount, Paint paint) {
    if (amount <= 0) return;
    if (amount >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final PathMetric metric in path.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * amount), paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final LogoFrame f = frame;
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);

    canvas.drawRRect(
      _tile,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[_tileTop, _tileBottom],
        ).createShader(_tile.outerRect),
    );

    canvas.save();
    canvas.clipRRect(_tile);

    if (f.margin > 0) {
      canvas.drawLine(const Offset(32, 0), Offset(32, 100 * f.margin), _stroke(_margin, 3));
    }

    // Read, or being read: the two rows above the beam and their ticks. The
    // typed lines are 44 and 34 long; as handwriting they are 42 and 36.
    final Paint ink = _stroke(_ink, 4.5);
    canvas.drawPath(_row(40, 20, 7, 42 + 2 * f.row1, f.row1), ink);
    canvas.drawPath(_row(40, 35, 6, 36 - 2 * f.row2, f.row2), ink);
    final Paint tick = _stroke(_tick, 5);
    _partial(canvas, Path()..moveTo(9, 20)..lineTo(15.4, 26.4)..lineTo(25, 11.2), f.tick1, tick);
    _partial(canvas, Path()..moveTo(9, 35)..lineTo(15.4, 41.4)..lineTo(25, 26.2), f.tick2, tick);

    // Not yet read.
    canvas.drawPath(_row(40, 64, 7, 42, 0), ink);
    canvas.drawPath(_row(40, 80, 5, 30, 0), ink);

    // The beam, its glow trailing over what it has read.
    final Rect glow = Rect.fromLTWH(0, f.beamY - 18, 100, 18);
    final double strength = math.min(1, 0.5 * (1 + 0.6 * f.pulse));
    canvas.drawRect(
      glow,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[_glow.withValues(alpha: 0), _glow.withValues(alpha: strength)],
        ).createShader(glow),
    );
    canvas.drawLine(Offset(0, f.beamY), Offset(100, f.beamY), _stroke(_beam, 4));
    canvas.restore();

    canvas.drawRRect(
      _tile.deflate(.5),
      Paint()
        ..color = const Color(0x14000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(LogoPainter oldDelegate) => oldDelegate.frame != frame;
}
