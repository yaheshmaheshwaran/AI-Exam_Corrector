import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/widgets/question_result_card.dart';

/// Read-only, question-by-question rendering of a validated correction.
class ResultsView extends StatefulWidget {
  const ResultsView({
    super.key,
    required this.result,
    required this.isCorrecting,
  });

  final CorrectionResult? result;
  final bool isCorrecting;

  @override
  State<ResultsView> createState() => _ResultsViewState();
}

class _ResultsViewState extends State<ResultsView> {
  // Desktop does not attach a primary scroll controller, so the list and its
  // scrollbar share an explicit one.
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isCorrecting) {
      return const _Placeholder(
        icon: Icons.hourglass_empty,
        message: 'Marking in progress…\n'
            'A full paper can take a couple of minutes.',
        showSpinner: true,
      );
    }

    final CorrectionResult? correction = widget.result;
    if (correction == null) {
      return const _Placeholder(
        icon: Icons.fact_check_outlined,
        message: 'Correction results will appear here.',
      );
    }

    // The questions scroll; the total stays in view, however long the paper.
    return Column(
      children: <Widget>[
        Expanded(
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.only(right: 10),
              children: <Widget>[
                if (correction.foundNoAnswers) const _NoAnswersNotice(),
                if (correction.warnings.isNotEmpty)
                  _Warnings(warnings: correction.warnings),
                for (final QuestionResult question in correction.questions)
                  QuestionResultCard(question: question),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        _TotalBar(result: correction),
      ],
    );
  }
}

/// Zero out of everything, with no answer found anywhere, is far more often
/// the wrong file than a blank script — so the result says so instead of
/// leaving the teacher to wonder whether the marking failed.
class _NoAnswersNotice extends StatelessWidget {
  const _NoAnswersNotice();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cautionFill,
        border: Border.all(color: const Color(0xFFE8CE6A)),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.help_outline, size: 16, color: AppTheme.caution),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'No answers were found anywhere in this paper',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: AppTheme.caution),
                ),
                const SizedBox(height: 2),
                Text(
                  'Every question scored zero because the marked file contains '
                  'no student answers. Check that section 1 holds the '
                  "student's completed paper rather than the mark scheme or a "
                  'blank question paper.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppTheme.caution),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A Fluent InfoBar: the marks were changed, and here is exactly how.
class _Warnings extends StatelessWidget {
  const _Warnings({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cautionFill,
        border: Border.all(color: const Color(0xFFE8CE6A)),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.warning_amber_rounded,
                  size: 16, color: AppTheme.caution),
              const SizedBox(width: 8),
              Text(
                'The marks were adjusted before display',
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: AppTheme.caution),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final String warning in warnings)
            Padding(
              padding: const EdgeInsets.only(left: 24, bottom: 2),
              child: Text(
                '• $warning',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppTheme.caution),
              ),
            ),
        ],
      ),
    );
  }
}

class _TotalBar extends StatelessWidget {
  const _TotalBar({required this.result});

  final CorrectionResult result;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double fraction = result.maximumTotalMarks > 0
        ? (result.totalMarks / result.maximumTotalMarks).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F6FC),
        border: Border.all(color: const Color(0xFFCFE2F3)),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // The marks and the percentage always fit; the bar between them is
          // decoration and yields first on a narrow window.
          final bool showBar = constraints.maxWidth >= 420;

          return Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  'Total marks: ${formatMarks(result.totalMarks)} / '
                  '${formatMarks(result.maximumTotalMarks)}',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
                ),
              ),
              if (showBar) ...<Widget>[
                const SizedBox(width: 16),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: fraction,
                      minHeight: 6,
                      backgroundColor: const Color(0xFFDCE9F5),
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              const SizedBox(width: 16),
              Flexible(
                child: Text(
                  'Percentage: ${formatPercentage(result.percentage)}',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontSize: 18, color: AppTheme.accent),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.message,
    this.showSpinner = false,
  });

  final IconData icon;
  final String message;
  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showSpinner)
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          else
            Icon(icon, size: 28, color: AppTheme.textDisabled),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }
}
