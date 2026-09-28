import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_theme.dart';

/// A loading placeholder shaped like the content on its way, with a soft
/// light sweeping across it.
///
/// One animation drives the whole subtree, and it is repainted on its own
/// layer. With the system's reduce-motion setting on, the bones stay still.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, required this.child, this.label = 'Loading'});

  final Widget child;

  /// What a screen reader announces.
  final String label;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _sweep.stop();
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color base = _BoneColor.of(context);
    final Color light = Color.lerp(base, dark ? Colors.white : c.surface, dark ? 0.06 : 0.7)!;
    final Widget bones = _BoneColor(color: base, child: widget.child);
    return Semantics(
      label: widget.label,
      liveRegion: true,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: _sweep.isAnimating
              ? AnimatedBuilder(
                  animation: _sweep,
                  child: bones,
                  builder: (BuildContext context, Widget? child) => ShaderMask(
                    blendMode: BlendMode.srcATop,
                    shaderCallback: (Rect bounds) => LinearGradient(
                      colors: <Color>[base, light, base],
                      stops: const <double>[0.35, 0.5, 0.65],
                      transform: _Slide(Curves.easeInOut.transform(_sweep.value)),
                    ).createShader(bounds),
                    child: child,
                  ),
                )
              : bones,
        ),
      ),
    );
  }
}

class _Slide extends GradientTransform {
  const _Slide(this.t);

  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 2 - 1), 0, 0);
}

/// The colour bones are drawn in, shared down the skeleton.
class _BoneColor extends InheritedWidget {
  const _BoneColor({required this.color, required super.child});

  final Color color;

  static Color of(BuildContext context) {
    final AppColors c = context.colors;
    return context.dependOnInheritedWidgetOfExactType<_BoneColor>()?.color ??
        Color.lerp(c.surfaceMuted, c.border, 0.5)!;
  }

  @override
  bool updateShouldNotify(_BoneColor old) => old.color != color;
}

/// One bone: a rounded bar standing in for a line of text, a badge or an
/// image. With no [width] it fills the width it is given.
class Bone extends StatelessWidget {
  const Bone({super.key, this.width, this.height = 10, this.radius = 4});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: _BoneColor.of(context), borderRadius: BorderRadius.circular(radius)),
    );
  }
}

/// Rows shaped like the result list: a label, a line of reasoning, a mark.
class SkeletonRows extends StatelessWidget {
  const SkeletonRows({super.key, this.count = 6, this.label = 'Loading'});

  final int count;
  final String label;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    // Fixed widths that vary row to row, so the list looks like text.
    const List<double> reasons = <double>[0.62, 0.48, 0.7, 0.4, 0.56, 0.66, 0.44, 0.6];
    return Skeleton(
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < count; i++)
            Container(
              height: 40,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border.all(color: c.border),
                borderRadius: BorderRadius.circular(AppTheme.controlRadius),
              ),
              child: Row(
                children: <Widget>[
                  const Bone(width: 72, height: 12),
                  const SizedBox(width: 24),
                  Expanded(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: reasons[i % reasons.length],
                      child: const Bone(),
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Bone(width: 40, height: 18, radius: 5),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A block of text lines, for a card or a paragraph still loading.
class SkeletonLines extends StatelessWidget {
  const SkeletonLines({super.key, this.lines = 3, this.label = 'Loading'});

  final int lines;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Bone(width: 140, height: 12),
          for (int i = 0; i < lines; i++) ...<Widget>[
            const SizedBox(height: 10),
            FractionallySizedBox(widthFactor: i == lines - 1 ? 0.55 : 0.9, child: const Bone()),
          ],
        ],
      ),
    );
  }
}

/// A table still loading: a header and [rows] rows of [columns] cells.
class SkeletonTable extends StatelessWidget {
  const SkeletonTable({super.key, this.rows = 6, this.columns = 6, this.label = 'Loading'});

  final int rows;
  final int columns;
  final String label;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    Widget row({required bool header}) => Container(
          height: header ? 36 : 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: header ? c.surfaceMuted : null,
            border: header ? null : Border(top: BorderSide(color: c.border)),
          ),
          child: Row(
            children: <Widget>[
              for (int i = 0; i < columns; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 24),
                Expanded(
                  flex: i == 1 ? 2 : 1,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: header ? 0.5 : 0.8,
                    child: Bone(height: header ? 8 : 10),
                  ),
                ),
              ],
            ],
          ),
        );
    return Skeleton(
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[row(header: true), for (int i = 0; i < rows; i++) row(header: false)],
      ),
    );
  }
}

/// An image still decoding: a bone the size of the image's box.
class SkeletonImage extends StatelessWidget {
  const SkeletonImage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Skeleton(
      label: 'Loading page image',
      child: SizedBox.expand(child: Bone(height: double.infinity, radius: 0)),
    );
  }
}
