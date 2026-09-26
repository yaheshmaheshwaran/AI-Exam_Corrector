import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/processing_job.dart';

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
    required this.onCancel,
    this.scriptLabel,
  });

  final ProcessingJob job;

  /// Which script of a class is being processed.
  final String? scriptLabel;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ProcessingCounts counts = job.counts;
    final int percent = (job.overallFraction * 100).round();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (scriptLabel != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(scriptLabel!, style: theme.textTheme.titleSmall),
            ),
          Wrap(
            spacing: 28,
            runSpacing: 8,
            children: <Widget>[
              _Figure(
                label: 'Pages',
                value: counts.pagesTotal == 0
                    ? '—'
                    : '${counts.pagesDone} / ${counts.pagesTotal}',
              ),
              _Figure(label: 'Current stage', value: job.stage.label),
              _Figure(label: 'Overall progress', value: '$percent%'),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              key: const Key('processing-progress'),
              value: job.overallFraction > 0 ? job.overallFraction : null,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            job.message,
            key: const Key('processing-message'),
            style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 14),
          Text('Detected', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              _Count('Questions', counts.questions),
              _Count('Answer regions', counts.answerRegions),
              _Count('Handwriting regions', counts.handwritingRegions),
              _Count('Diagrams', counts.diagrams),
              _Count('Graphs', counts.graphs),
              _Count('Tables', counts.tables),
              _Count('Equations', counts.equations),
              _Count('Crossed out', counts.crossedOut),
              if (counts.questionsMarked > 0) _Count('Marked', counts.questionsMarked),
            ],
          ),
          const SizedBox(height: 14),
          Text('Stages', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final ProcessingStage stage in ProcessingStage.pipeline)
            _StageRow(
              stage: stage,
              done: job.completedStages.contains(stage),
              active: job.stage == stage,
              reused: job.reusedStages.contains(stage),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onCancel,
            icon: const Icon(Icons.stop_circle_outlined, size: 16),
            label: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary)),
        Text(value, style: theme.textTheme.titleMedium),
      ],
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.label, this.value);

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.pageBackground,
        border: Border.all(color: AppTheme.stroke),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Text('$label: $value', style: const TextStyle(fontSize: 12)),
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
    final Widget icon = done
        ? const Icon(Icons.check_circle, size: 14, color: AppTheme.success)
        : active
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              )
            : const Icon(Icons.radio_button_unchecked, size: 14, color: AppTheme.textDisabled);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          SizedBox(width: 18, child: Center(child: icon)),
          const SizedBox(width: 6),
          Text(
            stage.label,
            style: TextStyle(
              fontSize: 12.5,
              color: done || active ? AppTheme.textPrimary : AppTheme.textDisabled,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          if (reused)
            const Text(
              '  · from the last run',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
        ],
      ),
    );
  }
}
