import 'package:flutter/material.dart';

import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

/// What processing is doing, and what it has found so far.
///
/// A long script takes minutes. Showing the stage, the page count and what
/// has been detected turns that wait into something the teacher can follow —
/// and a stage that came from the cache says so, which is how a resumed run
/// explains why it is suddenly fast.
class ProcessingPanel extends StatelessWidget {
  const ProcessingPanel({
    super.key,
    required this.job,
    this.scriptLabel,
  });

  final ProcessingJob job;

  /// Which script of a class is being processed.
  final String? scriptLabel;

  @override
  Widget build(BuildContext context) {
    final ProcessingCounts counts = job.counts;
    final int percent = (job.overallFraction * 100).round();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (scriptLabel != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(scriptLabel!, style: context.text.titleSmall),
            ),
          // The three numbers that answer "how far along is it?", side by
          // side in one strip.
          _Figures(
            children: <Widget>[
              StatTile(
                label: 'Pages',
                value: counts.pagesTotal == 0 ? '—' : '${counts.pagesDone} / ${counts.pagesTotal}',
              ),
              StatTile(label: 'Current stage', value: job.stage.label),
              StatTile(label: 'Overall progress', value: '$percent%', tone: ToneKind.primary),
            ],
          ),
          const SizedBox(height: 14),
          SmoothProgress(
            key: const Key('processing-progress'),
            value: job.overallFraction,
            minHeight: 6,
          ),
          const SizedBox(height: 8),
          Text(job.message, key: const Key('processing-message'), style: context.text.caption),
          const SizedBox(height: 20),
          Text('Detected', style: context.text.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final (String label, int value) in <(String, int)>[
                ('Questions', counts.questions),
                ('Answer regions', counts.answerRegions),
                ('Handwriting regions', counts.handwritingRegions),
                ('Diagrams', counts.diagrams),
                ('Graphs', counts.graphs),
                ('Tables', counts.tables),
                ('Equations', counts.equations),
                ('Crossed out', counts.crossedOut),
                if (counts.questionsMarked > 0) ('Marked', counts.questionsMarked),
              ])
                StatusPill(label: '$label: $value'),
            ],
          ),
          const SizedBox(height: 20),
          Text('Stages', style: context.text.titleSmall),
          const SizedBox(height: 6),
          for (final ProcessingStage stage in ProcessingStage.pipeline)
            _StageRow(
              stage: stage,
              done: job.completedStages.contains(stage),
              active: job.stage == stage,
              reused: job.reusedStages.contains(stage),
            ),
        ],
      ),
    );
  }
}

/// Figures in one bordered strip, divided by hairlines; they wrap onto
/// their own rows when the pane is narrow.
class _Figures extends StatelessWidget {
  const _Figures({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool row = constraints.maxWidth >= 420;
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(AppTheme.controlRadius + 2),
          ),
          child: row
              ? IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int i = 0; i < children.length; i++)
                        Expanded(
                          flex: i == 1 ? 2 : 1,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              border: i == 0 ? null : Border(left: BorderSide(color: c.border)),
                            ),
                            child: children[i],
                          ),
                        ),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (int i = 0; i < children.length; i++)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          border: i == 0 ? null : Border(top: BorderSide(color: c.border)),
                        ),
                        child: children[i],
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({
    required this.stage,
    required this.done,
    required this.active,
    required this.reused,
  });

  final ProcessingStage stage;
  final bool done;
  final bool active;
  final bool reused;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final Widget icon = done
        ? Icon(Icons.check_circle, size: 15, color: c.success)
        : active
            ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.8))
            : Icon(Icons.radio_button_unchecked, size: 15, color: c.textFaint);
    // The stage running now is picked out, so the list reads at a glance.
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: active ? c.primarySoft : null,
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(width: 18, child: Center(child: icon)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              stage.label,
              overflow: TextOverflow.ellipsis,
              style: context.text.small.copyWith(
                color: done || active ? c.text : c.textFaint,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          if (reused) Text('  · from the last run', style: context.text.caption),
        ],
      ),
    );
  }
}
