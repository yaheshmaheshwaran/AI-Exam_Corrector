part of 'home_screen.dart';

/// Everything a correction needs, in a column down the left of the window:
/// the scripts, the paper, the guidance and the syllabi, with the one
/// command that starts marking pinned at the foot.
///
/// Inputs are chosen once and then only glanced at, so they get a narrow
/// column; the results beside them get the rest of the window.
class _SetupRail extends StatefulWidget {
  const _SetupRail({
    required this.sections,
    required this.action,
    this.scrolls = true,
    this.topInset = 0,
  });

  final List<Widget> sections;
  final Widget action;

  /// False when the window is narrow: the whole page scrolls instead, and
  /// the command sits at the foot of the window rather than of the rail.
  final bool scrolls;

  /// How far the top bar reaches over the rail: its content starts below
  /// the bar and scrolls up under it.
  final double topInset;

  static const double width = 340;

  @override
  State<_SetupRail> createState() => _SetupRailState();
}

class _SetupRailState extends State<_SetupRail> {
  /// The pinned command's height, measured, so the sections scroll clear
  /// of it.
  double _foot = 96;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final List<Widget> children = <Widget>[
      for (int i = 0; i < widget.sections.length; i++) ...<Widget>[
        if (i > 0) const Divider(height: 1),
        widget.sections[i],
      ],
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: widget.scrolls ? Border(right: BorderSide(color: c.border)) : Border(bottom: BorderSide(color: c.border)),
      ),
      child: widget.scrolls
          ? Stack(
              children: <Widget>[
                // Five short sections: built together, so every step —
                // a syllabus drop target included — is always there. They
                // scroll under the frosted bar above and command below.
                Positioned.fill(
                  child: RepaintBoundary(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.only(top: widget.topInset, bottom: _foot),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                    ),
                  ),
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
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
    );
  }
}

/// The strip the primary command sits in.
class _RailFoot extends StatelessWidget {
  const _RailFoot({required this.action});

  final Widget action;

  @override
  Widget build(BuildContext context) {
    // Frosted: the sections scroll softly out of view beneath it.
    return Frosted(
      top: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.pagePadding, 12, AppTheme.pagePadding, AppTheme.pagePadding),
        child: action,
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
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(36)),
            icon: const Icon(Icons.stop_circle_outlined, size: 16),
            label: const Text('Cancel'),
          )
        : FilledButton.icon(
            onPressed: onCorrect,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(36)),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(label),
          );
    if (readiness.isEmpty) return button;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            StatusDot(tone: readinessTone, size: 7),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                readiness,
                key: const Key('rail-readiness'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.caption,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        button,
      ],
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

/// The status bar at the foot of the window: what is happening now.
///
/// It listens to the controller's progress on its own, so a correction
/// moving through a stage redraws this line and nothing else.
class _StatusFooter extends StatelessWidget {
  const _StatusFooter({required this.controller});

  final CorrectionController controller;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[controller, controller.progress]),
      builder: (BuildContext context, _) {
        final bool error = controller.statusIsError;
        final bool running = controller.isProcessing;
        final double fraction = controller.job?.overallFraction ?? 0;
        return Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.pagePadding),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(top: BorderSide(color: c.border)),
          ),
          child: Row(
            children: <Widget>[
              StatusDot(
                tone: error
                    ? ToneKind.danger
                    : running
                        ? ToneKind.primary
                        : ToneKind.success,
                size: 7,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  controller.statusMessage,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.caption.copyWith(color: error ? c.danger : null),
                ),
              ),
              if (running) ...<Widget>[
                const SizedBox(width: AppTheme.gap),
                SizedBox(
                  width: 140,
                  // Zero would read as a stalled bar while the sidecar starts,
                  // before the first page reports; indeterminate is honest there.
                  child: SmoothProgress(value: fraction),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 34,
                  child: Text(
                    fraction > 0 ? '${(fraction * 100).round()}%' : '',
                    textAlign: TextAlign.right,
                    style: context.text.caption.copyWith(
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
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
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(AppTheme.controlRadius + 2),
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
