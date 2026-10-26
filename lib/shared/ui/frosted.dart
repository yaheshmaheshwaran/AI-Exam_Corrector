import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:exam_corrector/app/app_glass.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/state/appearance.dart';

/// A floating pane of liquid glass: the rail, a toolbar, the command footer.
///
/// What passes beneath it is softly blurred with its colour kept rich; the
/// pane's own white lies over the blur, brightest along the top where it
/// catches the light, with a bright inner rim, a faint outer hairline and a
/// soft warm lift. Only these few floating panes blur — content cards never
/// do — and they all read one shared backdrop (the app's `BackdropGroup`).
///
/// Readability comes first. The pane is at least half white where it is
/// clearest, which keeps text at 7:1 or better over the blurred app content
/// beneath. When glass blur is off (the teacher's choice, reduce motion,
/// high contrast) the same pane is drawn nearly solid, with an identical
/// shape and layout.
class Frosted extends StatelessWidget {
  const Frosted({
    super.key,
    required this.child,
    this.radius = AppTheme.barRadius,
    this.tint,
    this.fill,
    this.edge,
  });

  final Widget child;
  final double radius;

  /// The pane's own colour; white when null.
  final Color? tint;

  /// The pane's own glass, top to foot, in place of the white sheen: a
  /// coloured pane that keeps its colour all the way down.
  final List<Color>? fill;

  /// The outer line's colour; the neutral hairline when null.
  final Color? edge;

  /// The pane's opacity at [strength] (0 solid, 1 clearest): between the
  /// solid fill and the glass fill, a little more opaque when [tinted] so
  /// a coloured pane keeps its colour.
  static double alphaFor({required bool tinted, required double strength}) {
    final double solid = tinted ? 0.96 : AppGlass.solidFill.a;
    final double clearest = tinted ? 0.72 : AppGlass.barFill.a;
    return solid - strength.clamp(0, 1) * (solid - clearest);
  }

  @override
  Widget build(BuildContext context) {
    final double strength = glassStrength(context);
    final Color colour = tint ?? Colors.white;
    final double alpha = alphaFor(tinted: tint != null, strength: strength);
    Color lit(double sheen) => Color.alphaBlend(Colors.white.withValues(alpha: sheen * strength), colour.withValues(alpha: alpha));
    final BorderRadius corners = BorderRadius.circular(radius);

    final List<Color>? fill = this.fill;
    final Widget pane = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corners,
        gradient: fill != null
            ? LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: fill)
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[lit(AppGlass.sheenTop), lit(AppGlass.sheenMiddle), lit(AppGlass.sheenFoot)],
                stops: const <double>[0, 0.42, 1],
              ),
      ),
      position: DecorationPosition.background,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        // A coloured pane keeps its rim faint: a bright one would outline it.
        decoration: fill != null
            ? BoxDecoration(borderRadius: corners, border: Border.all(color: Colors.white.withValues(alpha: 0.4)))
            : AppGlass.rimOf(radius: radius),
        child: child,
      ),
    );

    // The lift and hairline lie outside the glass, never under its blur.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corners,
        border: Border.fromBorderSide(edge == null ? AppGlass.edge : AppGlass.edge.copyWith(color: edge)),
        boxShadow: AppGlass.lift,
      ),
      child: strength <= 0
          ? pane
          : ClipRRect(
              borderRadius: corners,
              child: BackdropFilter.grouped(
                filter: glassFilter(AppGlass.blurSigma * strength),
                child: pane,
              ),
            ),
    );
  }
}

/// Blurs what lies beneath by [sigma], then restores some of the colour the
/// blur washes out — the richness that makes glass read as liquid rather
/// than frosted plastic. Brightness is kept: only saturation changes.
ImageFilter glassFilter(double sigma) {
  const double k = AppGlass.saturation;
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

/// How strongly glass blurs, from 0 (solid) to 1: the teacher's setting,
/// or 0 when the system asks for reduced motion or high contrast.
double glassStrength(BuildContext context) {
  if (systemWantsSolid(context)) return 0;
  return TransparencyScope.of(context)?.value ?? Transparency.standard;
}

/// Whether glass blurs at all.
bool glassActive(BuildContext context) => glassStrength(context) > 0;

/// Whether the system asks for reduced motion or high contrast, which
/// keeps glass solid whatever the setting.
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
