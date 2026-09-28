import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/services/ui_sound.dart';
import 'package:exam_corrector/widgets/ui/app_logo.dart';

/// Shows the [LaunchScreen] over the app while it opens, then gets out of the
/// way. The app is built underneath from the first frame, so the opening
/// screen never makes anyone wait.
class LaunchOverlay extends StatefulWidget {
  const LaunchOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<LaunchOverlay> createState() => _LaunchOverlayState();
}

class _LaunchOverlayState extends State<LaunchOverlay> {
  bool _showing = true;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        widget.child,
        if (_showing) LaunchScreen(onDone: () => setState(() => _showing = false)),
      ],
    );
  }
}

/// The opening screen: the logo draws itself — the beam sweeps down the sheet
/// and each line it passes turns to type and is ticked in the margin — and a
/// soft chime plays as the beam settles. Any click or key skips it.
///
/// With reduced motion the finished logo is shown still, briefly.
class LaunchScreen extends StatefulWidget {
  const LaunchScreen({super.key = const Key('launch-screen'), required this.onDone});

  /// Called once the screen has faded away, played through or skipped.
  final VoidCallback onDone;

  @override
  State<LaunchScreen> createState() => _LaunchScreenState();
}

class _LaunchScreenState extends State<LaunchScreen> with TickerProviderStateMixin {
  static const Duration _length = Duration(milliseconds: 1900);
  static const Duration _stillLength = Duration(milliseconds: 900);

  late final bool _still =
      SchedulerBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
  late final AnimationController _play = AnimationController(vsync: this, duration: _still ? _stillLength : _length);
  late final AnimationController _skip = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));

  // The timeline, in milliseconds of the full-length play.
  late final Animation<double> _tile = _at(0, 250, Curves.easeOutCubic);
  late final Animation<double> _margin = _at(100, 350, Curves.easeOutCubic);
  late final Animation<double> _beam = _at(250, 850, Curves.easeInOutCubic);
  late final Animation<double> _pulse = _at(850, 1150, Curves.linear);
  late final Animation<double> _title = _at(700, 1100, Curves.easeOutCubic);
  late final Animation<double> _subtitle = _at(800, 1200, Curves.easeOutCubic);
  late final Animation<double> _exit =
      _still ? _within(700, 900, Curves.easeInCubic) : _at(1600, 1900, Curves.easeInCubic);

  /// When the chime plays: as the beam settles, or soon after a still screen appears.
  late final double _chimeAt = _still ? 300 / 900 : 850 / 1900;

  bool _chimed = false;
  bool _finished = false;

  Animation<double> _at(int from, int to, Curve curve) => _within(from, to, curve, total: 1900);

  Animation<double> _within(int from, int to, Curve curve, {int total = 900}) =>
      CurvedAnimation(parent: _play, curve: Interval(from / total, to / total, curve: curve));

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _play
      ..addListener(_chime)
      ..forward().whenCompleteOrCancel(() {
        if (_play.isCompleted) _finish();
      });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _play.dispose();
    _skip.dispose();
    super.dispose();
  }

  void _chime() {
    if (_chimed || _play.value < _chimeAt) return;
    _chimed = true;
    UiSound.instance.play(UiSoundKind.welcome);
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) _skipNow();
    // Keys pressed while the screen is up are for it alone.
    return true;
  }

  void _skipNow() {
    if (_skip.isAnimating || _finished) return;
    _chimed = true; // A skipped opening stays quiet.
    _play.stop();
    _skip.forward().whenCompleteOrCancel(() {
      if (_skip.isCompleted) _finish();
    });
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    widget.onDone();
  }

  LogoFrame get _frame {
    if (_still) return LogoFrame.finished;
    return LogoFrame.fromBeam(
      margin: _margin.value,
      beamY: lerpDouble(-2, LogoPainter.beamRest, _beam.value)!,
      pulse: math.sin(math.pi * _pulse.value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = context.colors;
    final ThemeData theme = Theme.of(context);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _skipNow(),
      child: Semantics(
        label: 'Marklume is opening',
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[_play, _skip]),
          builder: (BuildContext context, _) {
            final double tile = _still ? 1 : _tile.value;
            final double title = _still ? 1 : _title.value;
            final double subtitle = _still ? 1 : _subtitle.value;
            return Opacity(
              opacity: ((1 - _exit.value) * (1 - _skip.value)).clamp(0.0, 1.0),
              child: Material(
                color: colors.bg,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Opacity(
                        opacity: tile,
                        child: Transform.scale(
                          scale: lerpDouble(0.94, 1, tile),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(120 * .23),
                              boxShadow: const <BoxShadow>[
                                BoxShadow(color: Color(0x24000000), blurRadius: 24, offset: Offset(0, 10)),
                                BoxShadow(color: Color(0x14000000), blurRadius: 3, offset: Offset(0, 1)),
                              ],
                            ),
                            child: CustomPaint(size: const Size.square(120), painter: LogoPainter(_frame)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Opacity(
                        opacity: title,
                        child: Transform.translate(
                          offset: Offset(0, 8 * (1 - title)),
                          child: Text('Marklume', style: theme.textTheme.headlineSmall),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Opacity(
                        opacity: subtitle,
                        child: Transform.translate(
                          offset: Offset(0, 8 * (1 - subtitle)),
                          child: Text('Reads and marks handwritten scripts', style: context.text.muted),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
