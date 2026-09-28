import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:exam_corrector/services/ui_sound.dart';

/// What a press feels like everywhere in the app: a short sound chosen by
/// what the control does, and a faint wash over it that fades in 200 ms.
///
/// It is the theme's splash factory — and each button theme's, with its own
/// [sound] — so every button, row, chip and menu item gets it without being
/// changed, and only when it can actually be pressed. With the system's
/// reduce-motion setting on, the wash is skipped; the sound, which the
/// teacher controls in Settings, still plays.
class PressFeedback extends InteractiveInkFeatureFactory {
  const PressFeedback({this.sound = UiSoundKind.tap});

  /// Null for a press that stays silent because something else sounds for
  /// it — a switch row plays the toggle sound when it changes.
  final UiSoundKind? sound;

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) {
    final UiSoundKind? sound = this.sound;
    if (sound != null) UiSound.instance.play(sound);
    return _PressWash(
      controller: controller,
      referenceBox: referenceBox,
      color: color,
      textDirection: textDirection,
      rectCallback: rectCallback,
      borderRadius: borderRadius ?? BorderRadius.zero,
      customBorder: customBorder,
      onRemoved: onRemoved,
      animate: !SchedulerBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations,
    );
  }
}

class _PressWash extends InteractiveInkFeature {
  _PressWash({
    required super.controller,
    required super.referenceBox,
    required super.color,
    required TextDirection textDirection,
    required BorderRadius borderRadius,
    required bool animate,
    RectCallback? rectCallback,
    super.customBorder,
    super.onRemoved,
  })  : _textDirection = textDirection,
        _borderRadius = borderRadius,
        _rectCallback = rectCallback {
    _fade = AnimationController(duration: const Duration(milliseconds: 200), vsync: controller.vsync)
      ..addListener(controller.markNeedsPaint)
      ..addStatusListener((AnimationStatus status) {
        if (status == AnimationStatus.completed) dispose();
      });
    if (animate) {
      _fade.forward();
    } else {
      _fade.value = 1;
    }
    controller.addInkFeature(this);
  }

  /// The strongest the wash gets: a hint, not a flash.
  static const double _peak = 0.10;

  final TextDirection _textDirection;
  final BorderRadius _borderRadius;
  final RectCallback? _rectCallback;
  late final AnimationController _fade;

  @override
  void confirm() {}

  @override
  void cancel() {}

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  void paintFeature(Canvas canvas, Matrix4 transform) {
    final double t = Curves.easeOut.transform(_fade.value);
    final double alpha = math.min(color.a, _peak) * (1 - t);
    if (alpha <= 0.002) return;
    final Paint paint = Paint()..color = color.withValues(alpha: alpha);
    final Rect rect = _rectCallback?.call() ?? Offset.zero & referenceBox.size;

    final Offset? origin = MatrixUtils.getAsTranslation(transform);
    canvas.save();
    if (origin == null) {
      canvas.transform(transform.storage);
    } else {
      canvas.translate(origin.dx, origin.dy);
    }
    final ShapeBorder? border = customBorder;
    if (border != null) {
      canvas.drawPath(border.getOuterPath(rect, textDirection: _textDirection), paint);
    } else if (_borderRadius != BorderRadius.zero) {
      canvas.drawRRect(_borderRadius.toRRect(rect), paint);
    } else {
      canvas.drawRect(rect, paint);
    }
    canvas.restore();
  }
}

/// Around a switch or checkbox row: the row keeps its press wash but not its
/// tap sound, because the control's change handler — wrapped in [toggled] —
/// plays the toggle sound instead. A toggle never sounds twice.
class ToggleRow extends StatelessWidget {
  const ToggleRow({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(splashFactory: const PressFeedback(sound: null)),
      child: child,
    );
  }
}
