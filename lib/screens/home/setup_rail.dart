part of 'home_screen.dart';

/// Everything a correction needs, in a column beside the rail: the scripts,
/// the paper, the guidance and the syllabi, each on its own glass card, with
/// the one command that starts marking pinned at the foot in floating glass.
///
/// Inputs are chosen once and then only glanced at, so they get a narrow
/// column; the results beside them get the rest of the window.
class _SetupRail extends StatefulWidget {
  const _SetupRail({
    required this.sections,
    required this.action,
    this.scrolls = true,
  });

  final List<Widget> sections;
  final Widget action;

  /// False when the window is narrow: the whole page scrolls instead, and
  /// the command sits at the foot of the window rather than of the column.
  final bool scrolls;

  @override
  State<_SetupRail> createState() => _SetupRailState();
}

class _SetupRailState extends State<_SetupRail> {
  /// The pinned command's height, measured, so the sections scroll clear
  /// of it.
  double _foot = 96;

  /// How far above the command the sections fade into the backdrop.
  static const double _fade = 28;

  @override
  Widget build(BuildContext context) {
    if (!widget.scrolls) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.sections);
    }
    return Stack(
      children: <Widget>[
        // Five short sections: built together, so every step — a syllabus
        // drop target included — is always there. They scroll under the
        // floating toolbar above and the command below.
        // It stops at the footer's lower edge, so nothing shows in the gap
        // beneath the floating command.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          bottom: AppTheme.floatInset,
          child: RepaintBoundary(
            // Scrolls by wheel and trackpad with no scrollbar drawn: on
            // desktop one would stand in the gap between the setup column
            // and the results. Everything inside keeps the usual behaviour,
            // so a long guidance field still shows its own.
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                // At the end of the scroll the last section clears the fade.
                padding: EdgeInsets.only(top: AppTheme.underBar, bottom: _foot + _fade - 2 * AppTheme.floatInset),
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.sections),
                ),
              ),
            ),
          ),
        ),
        // The sections dissolve into the backdrop just above the command,
        // rather than being cut off by its edge.
        Positioned(
          left: 0,
          right: 0,
          bottom: _foot - AppTheme.floatInset,
          height: _fade,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    AppColors.backdropBottom.withValues(alpha: 0),
                    AppColors.backdropBottom.withValues(alpha: 0.94),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AppToolbar(key: Key('setup-toolbar'), title: 'Setup', subtitle: 'What to mark, and how'),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: MeasureSize(
            onSize: (Size size) {
              if (mounted && size.height != _foot) setState(() => _foot = size.height);
            },
            child: _RailFoot(action: widget.action),
          ),
        ),
      ],
    );
  }
}

/// The floating pane the primary command sits in: espresso glass, so the
/// place where marking starts stands apart from the white sections above.
class _RailFoot extends StatelessWidget {
  const _RailFoot({required this.action});

  final Widget action;

  @override
  Widget build(BuildContext context) {
    // Floating glass: the sections scroll softly out of view beneath it.
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppTheme.floatInset, AppTheme.floatInset, AppTheme.floatInset, AppTheme.floatInset),
      child: Frosted(
        radius: AppTheme.footRadius,
        fill: AppGlass.espressoFill,
        edge: AppGlass.espressoEdge,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: action,
        ),
      ),
    );
  }
}

/// The primary command at the foot of the rail, or Cancel while it runs.
class _RailAction extends StatelessWidget {
  const _RailAction({
    required this.label,
    required this.onCorrect,
    required this.onCancel,
    this.readiness = '',
    this.readinessTone = ToneKind.neutral,
  });

  final String label;
  final VoidCallback? onCorrect;

  /// Set while processing runs; replaces the command.
  final VoidCallback? onCancel;

  /// One line on whether marking can start, and what it still needs.
  final String readiness;
  final ToneKind readinessTone;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? onCancel = this.onCancel;
    final Widget button = onCancel != null
        ? OutlinedButton.icon(
            key: const Key('cancel-processing'),
            onPressed: onCancel,
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(AppTheme.primaryHeight)),
            icon: const Icon(Icons.stop_circle_outlined, size: 16),
            label: const Text('Cancel'),
          )
        : FilledButton.icon(
            onPressed: onCorrect,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(AppTheme.primaryHeight),
              disabledForegroundColor: _waiting,
              disabledIconColor: _waiting,
            ).copyWith(backgroundBuilder: _background),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(label),
          );
    if (readiness.isEmpty) return button;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // In full: it wraps to a second line rather than being cut short.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Centred on the first line of 18px caption text.
            Padding(
              padding: const EdgeInsets.only(top: 5.5),
              child: StatusDot(tone: readinessTone, size: 7),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                readiness,
                key: const Key('rail-readiness'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.caption.copyWith(color: context.colors.primary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        button,
      ],
    );
  }

  /// The waiting command's text, a muted shade of the pane's espresso.
  static const Color _waiting = Color(0xFF8C7D70);

  /// The command's pill: raised espresso when it can run; a calm,
  /// see-through pill on the espresso glass while it waits.
  static Widget _background(BuildContext context, Set<WidgetState> states, Widget? child) {
    if (!states.contains(WidgetState.disabled)) return RaisedPill.primary(context, states, child);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        shape: const StadiumBorder(side: BorderSide(color: AppGlass.espressoEdge, width: 0.5)),
      ),
      child: child,
    );
  }
}

/// Which syllabus the chosen paper is marked against, and a way to change it.
class _SyllabusLine extends StatelessWidget {
  const _SyllabusLine({required this.controller});

  final CorrectionController controller;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final ({String name, String how})? inUse = controller.syllabusInUse;
    final String text = inUse != null
        ? 'Syllabus: ${inUse.name} · ${inUse.how}'
        : controller.syllabusChoice == SyllabusLibrary.none
            ? 'Marked without a syllabus · chosen by you'
            : controller.syllabi.isEmpty
                ? 'No syllabi saved yet — add one below'
                : 'No saved syllabus matches this paper';

    return Row(
      children: <Widget>[
        Icon(Icons.menu_book_outlined, size: 14, color: inUse == null ? c.textFaint : c.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            key: const Key('syllabus-line'),
            overflow: TextOverflow.ellipsis,
            style: inUse == null ? context.text.caption : context.text.caption.copyWith(color: c.text),
          ),
        ),
        if (controller.syllabi.isNotEmpty)
          PopupMenuButton<String>(
            key: const Key('syllabus-choose'),
            enabled: !controller.isBusy,
            tooltip: 'Choose the syllabus for this paper',
            onSelected: (String value) => controller.chooseSyllabus(value == _auto ? null : value),
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              CheckedPopupMenuItem<String>(
                value: _auto,
                checked: controller.syllabusChoice == null,
                child: const Text('Match automatically'),
              ),
              const PopupMenuDivider(),
              for (final Syllabus syllabus in controller.syllabi)
                CheckedPopupMenuItem<String>(
                  value: syllabus.id,
                  checked: controller.syllabusChoice == syllabus.id,
                  child: Text(syllabus.name),
                ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem<String>(
                value: SyllabusLibrary.none,
                checked: controller.syllabusChoice == SyllabusLibrary.none,
                child: const Text('No syllabus'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text('Change…', style: context.text.caption.copyWith(color: c.primary)),
            ),
          ),
      ],
    );
  }

  static const String _auto = '__auto__';
}

/// The status bar along the foot of the window: a floating pane of glass,
/// like the toolbars, with what is happening now on the left — and, while a
/// run goes, its progress and how long it has taken — and what the AI is
/// doing on the right.
///
/// It sits the same inset from the window's edges as every other pane, so
/// its ends line up with the rail and the results.
///
/// It listens to the controller's progress on its own, so a correction
/// moving through a stage redraws this bar and nothing else.
class _StatusFooter extends StatelessWidget {
  const _StatusFooter({required this.controller});

  final CorrectionController controller;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[controller, controller.progress, ?controller.health?.listenable]),
      builder: (BuildContext context, _) {
        final bool error = controller.statusIsError;
        final bool running = controller.isProcessing;
        final double fraction = controller.job?.overallFraction ?? 0;
        final List<String> markers = controller.ai.roles.chain(ModelRole.marker);
        final String model = markers.isEmpty ? '' : ModelStatus.shortName(markers.first);
        final TextStyle figures = context.text.caption.copyWith(
          color: c.textMuted,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(AppTheme.floatInset, 0, AppTheme.floatInset, AppTheme.floatInset),
          child: SizedBox(
            key: const Key('status-bar'),
            height: AppTheme.statusHeight,
            child: RepaintBoundary(
              child: Frosted(
                child: Padding(
                  padding: const EdgeInsets.only(left: 14, right: 5),
                  child: Row(
                    children: <Widget>[
                      _StatusLight(
                        tone: error
                            ? ToneKind.danger
                            : running
                                ? ToneKind.primary
                                : ToneKind.success,
                        breathing: running,
                      ),
                      const SizedBox(width: 8),
                      // The message takes what it needs, and the run's
                      // progress follows it; the AI keeps to the right.
                      Expanded(
                        child: Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                controller.statusMessage,
                                overflow: TextOverflow.ellipsis,
                                style: context.text.caption.copyWith(color: error ? c.danger : c.textMuted),
                              ),
                            ),
                            if (running) ...<Widget>[
                              const SizedBox(width: 10),
                              Container(width: 1, height: 14, color: c.text.withValues(alpha: 0.1)),
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 120,
                                // Zero would read as a stalled bar while the first stage starts,
                                // before the first page reports; indeterminate is honest there.
                                child: SmoothProgress(value: fraction),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 34,
                                child: Text(fraction > 0 ? '${(fraction * 100).round()}%' : '', style: figures),
                              ),
                              if (controller.runStartedAt != null)
                                _RunClock(controller: controller, style: figures.copyWith(color: c.textFaint)),
                              if (controller.isBackgroundRun) ...<Widget>[
                                const SizedBox(width: 10),
                                Flexible(
                                  child: StatusPill(
                                    key: const Key('background-pill'),
                                    label: 'In the background · ${controller.markedCount} of '
                                        '${controller.scripts.length} · ${controller.engineLabel}',
                                    icon: Icons.nights_stay_outlined,
                                    tone: ToneKind.primary,
                                    tooltip: 'Marking carries on while you work. This Mac stays awake '
                                        'until the class is done, and you are told when it finishes.',
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: AppTheme.gap),
                      // What the AI is doing, and how much it has been used today.
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 340),
                        child: controller.usage != null
                            ? ModelUsageIndicator(ai: controller.ai, usage: controller.usage!)
                            : StatusPill(
                                label: controller.ai.hasModelAccess ? model : 'AI not set up',
                                icon: controller.ai.hasModelAccess ? Icons.auto_awesome_outlined : Icons.key_off_outlined,
                                tone: controller.ai.hasModelAccess ? ToneKind.neutral : ToneKind.warning,
                                tooltip: controller.ai.hasModelAccess
                                    ? 'Marking runs on ${markers.isEmpty ? 'no model' : controller.modelLabel(markers.first)}'
                                    : 'Open Settings to choose where the AI runs.',
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The status bar's dot: green when ready, espresso while a run goes, red
/// when something stopped. While a run goes it breathes, a soft halo
/// swelling and fading — still under reduced motion.
class _StatusLight extends StatefulWidget {
  const _StatusLight({required this.tone, required this.breathing});

  final ToneKind tone;
  final bool breathing;

  @override
  State<_StatusLight> createState() => _StatusLightState();
}

class _StatusLightState extends State<_StatusLight> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(_StatusLight old) {
    super.didUpdateWidget(old);
    _follow();
  }

  void _follow() {
    if (widget.breathing && !AppMotion.still(context)) {
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      _breath
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color colour = context.colors.tone(widget.tone).foreground;
    return AnimatedBuilder(
      animation: _breath,
      builder: (BuildContext context, _) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: colour,
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            if (_breath.value > 0)
              BoxShadow(
                color: colour.withValues(alpha: 0.16),
                spreadRadius: 3 * Curves.easeInOut.transform(_breath.value),
              ),
          ],
        ),
      ),
    );
  }
}

/// How long the run under way has taken, ticking once a second.
///
/// Mounted only while a run is under way, so its timer stops with it.
class _RunClock extends StatefulWidget {
  const _RunClock({required this.controller, required this.style});

  final CorrectionController controller;
  final TextStyle style;

  @override
  State<_RunClock> createState() => _RunClockState();
}

class _RunClockState extends State<_RunClock> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Time this run has taken',
      // Wide enough for "59m 59s", so the bar does not shift as it ticks.
      child: SizedBox(
        key: const Key('run-clock'),
        width: 56,
        child: Text(formatElapsed(widget.controller.runTime), style: widget.style),
      ),
    );
  }
}

/// Under the empty result: the steps before marking, ticked as they are
/// done, so the teacher sees at once what is still missing.
class _EmptyChecklist extends StatelessWidget {
  const _EmptyChecklist({required this.steps, required this.closing});

  final List<({String label, bool done, bool optional})> steps;
  final String closing;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.55),
            border: Border.all(color: c.text.withValues(alpha: 0.08)),
            borderRadius: BorderRadius.circular(AppTheme.controlRadius + 4),
          ),
          child: Column(
            children: <Widget>[
              for (int i = 0; i < steps.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    border: i == 0 ? null : Border(top: BorderSide(color: c.border)),
                  ),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: steps[i].done ? c.success : null,
                          border: steps[i].done ? null : Border.all(color: c.borderStrong, width: 1.5),
                        ),
                        child: steps[i].done ? Icon(Icons.check, size: 11, color: c.surface) : null,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          steps[i].label,
                          style: context.text.small.copyWith(color: steps[i].done ? c.textMuted : c.text),
                        ),
                      ),
                      if (steps[i].optional && !steps[i].done) Text('Optional', style: context.text.faint),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(closing, key: const Key('empty-closing'), textAlign: TextAlign.center, style: context.text.caption),
      ],
    );
  }
}
