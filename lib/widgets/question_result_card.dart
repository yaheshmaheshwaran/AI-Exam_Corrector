import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/models/question_result.dart';

/// One question's marks, the answer that earned them, and the reasoning.
class QuestionResultCard extends StatelessWidget {
  const QuestionResultCard({super.key, required this.question});

  final QuestionResult question;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        border: Border.all(color: AppTheme.stroke),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Header strip: question and its marks, the two things scanned first.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: AppTheme.subtleBackground,
              border: Border(bottom: BorderSide(color: AppTheme.stroke)),
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(AppTheme.controlRadius),
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Question ${question.questionNumber}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  'Maximum marks: ${formatMarks(question.maximumMarks)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppTheme.textSecondary),
                ),
                const SizedBox(width: 10),
                _MarksBadge(
                  awarded: question.awardedMarks,
                  maximum: question.maximumMarks,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _Field(label: 'Student answer', value: question.studentAnswer),
                const SizedBox(height: 10),
                _Field(label: 'Evaluation', value: question.evaluation),
                if (question.markingPoints.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  Text('Marking points', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  for (final MarkingPoint point in question.markingPoints)
                    _MarkingPointRow(point: point),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MarksBadge extends StatelessWidget {
  const _MarksBadge({required this.awarded, required this.maximum});

  final double awarded;
  final double maximum;

  @override
  Widget build(BuildContext context) {
    final bool full = maximum > 0 && awarded >= maximum;
    final bool none = awarded <= 0;

    final Color foreground = full
        ? AppTheme.success
        : none
            ? AppTheme.danger
            : AppTheme.caution;
    final Color background = full
        ? AppTheme.successFill
        : none
            ? AppTheme.dangerFill
            : AppTheme.cautionFill;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: foreground.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Text(
        '${formatMarks(awarded)} / ${formatMarks(maximum)}',
        style: TextStyle(
          color: foreground,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        SelectableText(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _MarkingPointRow extends StatelessWidget {
  const _MarkingPointRow({required this.point});

  final MarkingPoint point;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color colour = point.satisfied ? AppTheme.success : AppTheme.danger;

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 8),
            child: Icon(
              point.satisfied
                  ? Icons.check_circle_outline
                  : Icons.cancel_outlined,
              size: 15,
              color: colour,
            ),
          ),
          Expanded(
            child: Text(
              point.satisfied
                  ? '${point.criterion}  (${formatMarks(point.marks)})'
                  : point.criterion,
              style: theme.textTheme.bodyMedium?.copyWith(color: colour),
            ),
          ),
        ],
      ),
    );
  }
}
