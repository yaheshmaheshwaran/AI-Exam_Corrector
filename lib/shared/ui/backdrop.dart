import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/services/window_chrome.dart';

/// The Warm mist backdrop behind every screen: soft ivory, a shade warmer
/// at the foot, with a faint warm glow from the top left.
///
/// It is what the glass has to show through, so it is kept quiet: one hue
/// family, long soft falloffs, no edges. It is painted once, on its own
/// layer, and never again while the app runs.
class WarmMistBackdrop extends StatelessWidget {
  const WarmMistBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const RepaintBoundary(child: _Mist()),
        child,
      ],
    );
  }
}

class _Mist extends StatelessWidget {
  const _Mist();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      key: Key('warm-mist'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[AppColors.backdropTop, AppColors.backdropBottom],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.7, -1.2),
            radius: 1.3,
            colors: <Color>[
              AppColors.backdropGlow,
              Color(0x8CF1E9E0),
              Color(0x00F1E9E0),
            ],
            stops: <double>[0, 0.38, 0.78],
          ),
        ),
        child: SizedBox.expand(),
      ),
    );
  }
}

/// Empty space in a floating bar that moves the window when dragged and
/// zooms it when double-clicked, where the app draws its own title bar.
/// Controls laid over it keep their own clicks.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (!WindowChrome.integratedTitleBar) return child ?? const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => WindowChrome.startDrag(),
      onDoubleTap: WindowChrome.zoom,
      child: child,
    );
  }
}
