import 'package:flutter/material.dart';

/// A progress bar that glides to each new value instead of jumping, and
/// shows the moving indeterminate bar while nothing has been counted yet.
class SmoothProgress extends StatelessWidget {
  const SmoothProgress({super.key, required this.value, this.minHeight = 3});

  /// 0..1; zero shows the indeterminate bar.
  final double value;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(minHeight),
        child: value <= 0
            ? LinearProgressIndicator(minHeight: minHeight)
            : TweenAnimationBuilder<double>(
                tween: Tween<double>(end: value.clamp(0.0, 1.0)),
                duration: still ? Duration.zero : const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                builder: (BuildContext context, double v, _) =>
                    LinearProgressIndicator(value: v, minHeight: minHeight),
              ),
      ),
    );
  }
}
