import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/state/appearance.dart';

/// A pinned surface that content scrolls beneath, as liquid glass: what
/// passes under it is softly blurred and its colour kept rich, its own
/// colour lies over the blur, and its edges catch the light — a bright rim
/// on the upper edge, a fainter reflection on the far one, and a lensed
/// band where content slides under. All of it is still, and all of it
/// scales with the teacher's transparency setting.
///
/// Readability comes first. What passes under these bars is the app's own
/// content — text, icons, outlined controls — which the blur spreads into
/// soft smudges no darker than half the darkest colour in the palette. The
/// surface's colour is laid on at an opacity that keeps text at 7:1 or
/// better, and secondary text and the accent at 4.5:1 or better, over such
/// a backdrop. When glass is off (the teacher's choice, reduce motion, high
/// contrast) the same surface is drawn solid, with an identical layout.
class Frosted extends StatelessWidget {
  const Frosted({
    super.key,
    required this.child,
    this.tint,
    this.top = false,
    this.bottom = false,
    this.outline = false,
    this.radius = 0,
    this.borderColor,
    this.blur = 10,
  });

  final Widget child;

  /// The surface's own colour; the theme's surface when null.
  final Color? tint;

  /// Hairlines on the edges content passes under.
  final bool top;
  final bool bottom;

  /// A hairline all round, for a rounded panel such as the total bar.
  final bool outline;
  final double radius;

  /// The hairline's colour; the theme's border when null.
  final Color? borderColor;
  final double blur;

  /// The opacity of the surface's own colour at full transparency: the
  /// clearest it may be while text still reads over blurred content, with
  /// the sheen at its brightest. The minimums are 0.47 (light) and 0.62
  /// (dark) for the surface colour, and 0.58 and 0.80 for the accent tint;
  /// each has a margin. The teacher's setting moves the opacity between
  /// solid and these.
  static const double clearestLight = 0.52;
  static const double clearestDark = 0.64;
  static const double clearestTintedLight = 0.62;
  static const double clearestTintedDark = 0.82;

  /// The most the glass's sheen lightens it, at the top edge, at full
  /// strength. Counted in the minimums above; in light mode it only adds
  /// contrast.
  static const double sheenLight = 0.14;
  static const double sheenDark = 0.02;

  /// How much richer colour stays through the glass: blur alone greys it.
  static const double vibrancy = 1.35;

  /// The opacity at [strength] (0 solid, 1 clearest) for the plain surface,
  /// or the accent tint when [tinted].
  static double alphaFor({required bool dark, required bool tinted, required double strength}) {
    final double clearest = tinted
        ? (dark ? clearestTintedDark : clearestTintedLight)
        : (dark ? clearestDark : clearestLight);
    return 1 - strength.clamp(0, 1) * (1 - clearest);
  }

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color colour = tint ?? c.surface;
    final double strength = glassStrength(context);
    final bool glass = strength > 0;
    final BorderRadius corners = BorderRadius.circular(radius);
    final BoxDecoration decoration = BoxDecoration(
      color: glass
          ? colour.withValues(
              alpha: alphaFor(dark: dark, tinted: tint != null, strength: strength),
            )
          : colour,
      borderRadius: radius > 0 ? corners : null,
      border: outline
          ? Border.all(color: borderColor ?? c.border)
          : Border(
              top: top ? BorderSide(color: borderColor ?? c.border) : BorderSide.none,
              bottom: bottom ? BorderSide(color: borderColor ?? c.border) : BorderSide.none,
            ),
    );
    if (!glass) return DecoratedBox(decoration: decoration, child: child);
    final Widget panel = ClipRRect(
      borderRadius: corners,
      child: BackdropFilter.grouped(
        filter: glassFilter(blur),
        child: DecoratedBox(
          decoration: decoration,
          // The light on the glass lies over its colour and under its text.
          child: CustomPaint(
            painter: _GlassLight(
              dark: dark,
              strength: strength,
              top: top,
              bottom: bottom,
              outline: outline,
              radius: radius,
            ),
            child: child,
          ),
        ),
      ),
    );
    if (outline || (!top && !bottom)) return panel;
    // A soft shade cast onto the content beyond the open edge, so the bar
    // reads as floating over it. Drawn outside the glass, never under it.
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        panel,
        if (bottom) _Shade(dark: dark, below: true),
        if (top) _Shade(dark: dark, below: false),
      ],
    );
  }
}

/// Blurs what lies beneath by [sigma], then restores some of the colour the
/// blur washes out — the richness that makes glass read as liquid rather
/// than frosted plastic. Brightness is kept: only saturation changes.
ImageFilter glassFilter(double sigma) {
  const double k = Frosted.vibrancy;
  const double r = 0.2126 * (1 - k), g = 0.7152 * (1 - k), b = 0.0722 * (1 - k);
  return ImageFilter.compose(
    outer: const ColorFilter.matrix(<double>[
      r + k, g, b, 0, 0, //
      r, g + k, b, 0, 0,
      r, g, b + k, 0, 0,
      0, 0, 0, 1, 0,
    ]),
    inner: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
  );
}

/// The light on a pane of glass: a sheen across its upper part, and its
/// edges catching the light.
class _GlassLight extends CustomPainter {
  const _GlassLight({
    required this.dark,
    required this.strength,
    required this.top,
    required this.bottom,
    required this.outline,
    required this.radius,
  });

  final bool dark;
  final double strength;
  final bool top;
  final bool bottom;
  final bool outline;
  final double radius;

  /// How deep the lensed band reaches in from an open edge.
  static const double lens = 6;

  Color _white(double alpha) => Colors.white.withValues(alpha: alpha * strength);

  @override
  void paint(Canvas canvas, Size size) {
    final Rect box = Offset.zero & size;

    // Sheen: the upper part of the pane a touch lighter, fading by the middle.
    canvas.drawRect(
      box,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[_white(dark ? Frosted.sheenDark : Frosted.sheenLight), _white(0)],
          stops: const <double>[0, 0.6],
        ).createShader(box),
    );

    if (outline) {
      // Rim: a bright line just inside the hairline, strongest at the top
      // left where the light falls, with a faint reflection at the bottom
      // right. The dark hairline outside it gives the glass its thickness.
      final RRect rim = RRect.fromRectAndRadius(box.deflate(1.5), Radius.circular(math.max(0, radius - 1.5)));
      final double a = dark ? 0.22 : 0.9;
      canvas.drawRRect(
        rim,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = dark ? 1 : 1.5
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[_white(a), _white(a * 0.15), _white(0), _white(a * 0.45)],
            stops: const <double>[0, 0.35, 0.7, 1],
          ).createShader(box),
      );
      // Depth: the lower edge of the pane sits a shade darker inside, as
      // thick glass does where the light leaves it.
      final Rect lower = Rect.fromLTRB(0, size.height - 1 - lens, size.width, size.height - 1);
      canvas.save();
      canvas.clipRRect(rim);
      canvas.drawRect(
        lower,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[
              Colors.black.withValues(alpha: (dark ? 0.18 : 0.07) * strength),
              Colors.black.withValues(alpha: 0),
            ],
          ).createShader(lower),
      );
      canvas.restore();
      return;
    }

    // Lensed band: where content slides under, the edge bends the light and
    // shines, fading inward. Inside the hairline, never under the text.
    final double a = dark ? 0.09 : 0.55;
    void band(double from, double to) {
      final Rect r = Rect.fromLTRB(0, math.min(from, to), size.width, math.max(from, to));
      canvas.drawRect(
        r,
        Paint()
          ..shader = LinearGradient(
            begin: from < to ? Alignment.topCenter : Alignment.bottomCenter,
            end: from < to ? Alignment.bottomCenter : Alignment.topCenter,
            colors: <Color>[_white(a), _white(0)],
          ).createShader(r),
      );
    }

    if (top) band(1, 1 + lens);
    if (bottom) band(size.height - 1, size.height - 1 - lens);
  }

  @override
  bool shouldRepaint(_GlassLight old) =>
      old.dark != dark ||
      old.strength != strength ||
      old.top != top ||
      old.bottom != bottom ||
      old.outline != outline ||
      old.radius != radius;
}

class _Shade extends StatelessWidget {
  const _Shade({required this.dark, required this.below});

  final bool dark;
  final bool below;

  static const double depth = 10;

  @override
  Widget build(BuildContext context) {
    final Color edge = Colors.black.withValues(alpha: dark ? 0.32 : 0.06);
    return Positioned(
      left: 0,
      right: 0,
      top: below ? null : -depth,
      bottom: below ? -depth : null,
      height: depth,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: below ? Alignment.topCenter : Alignment.bottomCenter,
              end: below ? Alignment.bottomCenter : Alignment.topCenter,
              colors: <Color>[edge, edge.withValues(alpha: 0)],
            ),
          ),
        ),
      ),
    );
  }
}

/// How frosted surfaces are, from 0 (solid) to 1: the teacher's setting,
/// or 0 when the system asks for reduced motion or high contrast.
double glassStrength(BuildContext context) {
  if (systemWantsSolid(context)) return 0;
  return TransparencyScope.of(context)?.value ?? Transparency.standard;
}

/// Whether surfaces are frosted at all.
bool glassActive(BuildContext context) => glassStrength(context) > 0;

/// Whether the system asks for reduced motion or high contrast, which
/// keeps surfaces solid whatever the setting.
bool systemWantsSolid(BuildContext context) {
  final MediaQueryData? media = MediaQuery.maybeOf(context);
  return media != null && (media.disableAnimations || media.highContrast);
}

/// Reports its child's size after layout, so content under a pinned
/// surface can be inset by exactly that surface's height.
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({super.key, required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderMeasureSize(onSize);

  @override
  void updateRenderObject(BuildContext context, RenderMeasureSize renderObject) => renderObject.onSize = onSize;
}

class RenderMeasureSize extends RenderProxyBox {
  RenderMeasureSize(this.onSize);

  ValueChanged<Size> onSize;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    // After this frame: reporting during layout would rebuild mid-layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(size));
  }
}
