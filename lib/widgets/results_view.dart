import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/models/section_totals.dart';
import 'package:exam_corrector/widgets/syllabus_badge.dart';

/// The marked paper, section by section and question by question.
///
/// Each row is a summary to scan — marks, whether it needs review, how sure
/// the marking is — and opens the full evidence for that question. On a paper
/// with sections the questions sit under their section, with its own total,
/// and a section can be folded away. Every total counts the teacher's marks
/// wherever they overrode the AI.
class ResultsView extends StatefulWidget {
  const ResultsView({
    super.key,
    required this.assessment,
    required this.reviews,
    required this.onOpenQuestion,
    this.pendingCorrections = false,
    this.onRemark,
  });

  final ExamAssessment? assessment;
  final TeacherReviewBook reviews;
  final ValueChanged<String> onOpenQuestion;
  final bool pendingCorrections;
  final VoidCallback? onRemark;

  @override
  State<ResultsView> createState() => _ResultsViewState();
}

class _ResultsViewState extends State<ResultsView> {
  // Desktop does not attach a primary scroll controller, so the list and its
  // scrollbar share an explicit one.
  final ScrollController _scroll = ScrollController();

  /// Sections the teacher folded away, by short name.
  final Set<String> _collapsed = <String>{};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ExamAssessment? assessment = widget.assessment;
    if (assessment == null) {
      return const _Placeholder(
        icon: Icons.fact_check_outlined,
        message: 'Correction results will appear here.',
      );
    }

    final CorrectionResult? result = assessment.result;
    final List<Widget> rows = <Widget>[
      if (widget.pendingCorrections)
        _Notice(
          icon: Icons.edit_note,
          title: 'Transcriptions were corrected',
          body: 'Re-mark to apply them. Only the questions whose answers '
              'changed are sent for marking again.',
          action: widget.onRemark == null
              ? null
              : OutlinedButton(onPressed: widget.onRemark, child: const Text('Re-mark')),
        ),
      if (result != null && result.foundNoAnswers)
        const _Notice(
          icon: Icons.help_outline,
          title: 'No answers were found anywhere in this paper',
          body: 'Every question scored zero because the marked file contains no '
              "student answers. Check that step 1 holds the student's completed "
              'script — it is easy to choose the blank question paper for both.',
        ),
      if (result == null)
        _Notice(
          icon: Icons.pause_circle_outline,
          title: 'Not marked yet',
          body: assessment.job.error ??
              'Marking did not finish. Everything read from the paper is kept.',
          action: widget.onRemark == null
              ? null
              : OutlinedButton(
                  onPressed: widget.onRemark,
                  child: const Text('Resume marking'),
                ),
        ),
      if (assessment.warnings.isNotEmpty) _Notes(warnings: assessment.warnings),
    ];

    Widget rowFor(String questionId) {
      final QuestionResult? question = result?.question(questionId);
      if (question != null) {
        return _QuestionRow(
          question: question,
          review: widget.reviews[question.questionId],
          finalMarks: widget.reviews.finalMarks(question),
          onOpen: () => widget.onOpenQuestion(question.questionId),
        );
      }
      final Question? unmarked = assessment.questionPaper.byId(questionId);
      if (unmarked == null) return const SizedBox.shrink();
      return _UnmarkedRow(
        question: unmarked,
        answer: assessment.answers[questionId],
        onOpen: () => widget.onOpenQuestion(questionId),
      );
    }

    final List<SectionTotal> sections = result != null
        ? SectionTotal.of(result, widget.reviews, assessment.questionPaper)
        : SectionTotal.ofPaper(assessment.questionPaper);
    if (sections.isEmpty) {
      rows.addAll(<Widget>[
        if (result != null)
          for (final QuestionResult question in result.questions) rowFor(question.questionId)
        else
          for (final Question question in assessment.questionPaper.markable)
            rowFor(question.questionId),
      ]);
    } else {
      for (final SectionTotal section in sections) {
        final bool collapsed = _collapsed.contains(section.shortName);
        rows.add(_SectionHeader(
          section: section,
          marked: result != null,
          collapsed: collapsed,
          onToggle: () => setState(() => collapsed
              ? _collapsed.remove(section.shortName)
              : _collapsed.add(section.shortName)),
        ));
        if (!collapsed) rows.addAll(section.questionIds.map(rowFor));
      }
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // The total stays pinned in view — unless the pane is too short for
        // that, when it scrolls with the questions rather than crushing them.
        final bool pinTotal = constraints.maxHeight >= 240;
        final Widget total = result == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _TotalBar(result: result, reviews: widget.reviews, sections: sections),
              );

        return Column(
          children: <Widget>[
            Expanded(
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.only(right: 10),
                  children: <Widget>[...rows, if (!pinTotal) total],
                ),
              ),
            ),
            if (pinTotal) total,
          ],
        );
      },
    );
  }
}

class _QuestionRow extends StatelessWidget {
  const _QuestionRow({
    required this.question,
    required this.review,
    required this.finalMarks,
    required this.onOpen,
  });

  final QuestionResult question;
  final TeacherReview? review;
  final double finalMarks;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ReviewStatus status = review?.status ?? ReviewStatus.pending;

    // The other option of an OR: marked and shown, but in no total.
    final bool counted = question.counted;

    final Widget row = Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AppTheme.cardBackground,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: AppTheme.stroke),
          borderRadius: BorderRadius.circular(AppTheme.controlRadius),
        ),
        child: InkWell(
          key: ValueKey<String>('question-row-${question.questionId}'),
          onTap: onOpen,
          borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 110,
                  child: Text(
                    'Question ${question.questionNumber}',
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: Text(
                    counted ? question.evaluation : question.choiceNote,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                  ),
                ),
                const SizedBox(width: 10),
                if (question.syllabusAward case final SyllabusAward award when award.hasBadge && counted) ...<Widget>[
                  SyllabusBadgeChip(badge: award.badge, bonus: award.bonus, tooltip: award.summary),
                  const SizedBox(width: 6),
                ],
                if (!counted)
                  const _Tag(
                    label: 'Not counted',
                    icon: Icons.alt_route,
                    colour: AppTheme.textSecondary,
                  )
                else if (question.adjustments.isNotEmpty && status == ReviewStatus.pending && !question.needsReview)
                  Tooltip(
                    message: question.adjustments.join('\n'),
                    child: const _Tag(label: 'Adjusted', icon: Icons.tune, colour: AppTheme.textSecondary),
                  )
                else if (status == ReviewStatus.overridden)
                  const _Tag(label: 'Changed', icon: Icons.edit, colour: AppTheme.accent)
                else if (status == ReviewStatus.accepted)
                  const _Tag(label: 'Accepted', icon: Icons.check, colour: AppTheme.success)
                else if (question.needsReview)
                  const _Tag(
                    label: 'Review',
                    icon: Icons.flag_outlined,
                    colour: AppTheme.caution,
                  ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'How sure the marking is',
                  child: Text(
                    '${(question.confidence * 100).round()}%',
                    style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                  ),
                ),
                const SizedBox(width: 10),
                MarksBadge(
                  awarded: finalMarks,
                  maximum: question.maximumMarks,
                  gold: counted && question.syllabusBadge != SyllabusBadge.none,
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
    return counted
        ? row
        : Tooltip(message: question.choiceNote, child: Opacity(opacity: 0.6, child: row));
  }
}

/// A section's heading: its name, its instructions, and what it scored.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.section,
    required this.marked,
    required this.collapsed,
    required this.onToggle,
  });

  final SectionTotal section;
  final bool marked;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double? stated = section.statedMarks;
    final String marks = marked
        ? '${formatMarks(section.awarded)} / ${formatMarks(section.maximum)}'
        : '${formatMarks(section.maximum)} marks';

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Material(
        color: AppTheme.pageBackground,
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
        child: InkWell(
          key: ValueKey<String>('section-${section.shortName}'),
          onTap: onToggle,
          borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: <Widget>[
                Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '${section.title}  ·  ${section.questionIds.length} '
                        'question${section.questionIds.length == 1 ? '' : 's'}',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      if (section.instructions.isNotEmpty)
                        Text(
                          section.instructions.replaceAll('\n', ' '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                        ),
                    ],
                  ),
                ),
                if (section.toReview > 0) ...<Widget>[
                  _Tag(
                    label: '${section.toReview} to review',
                    icon: Icons.flag_outlined,
                    colour: AppTheme.caution,
                  ),
                  const SizedBox(width: 10),
                ],
                if (marked)
                  SizedBox(
                    width: 70,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: section.fraction,
                        minHeight: 5,
                        backgroundColor: const Color(0xFFDCE9F5),
                      ),
                    ),
                  ),
                const SizedBox(width: 10),
                Tooltip(
                  message: stated != null && (stated - section.maximum).abs() > 0.001
                      ? 'The paper prints ${formatMarks(stated)} marks for this section.'
                      : 'Marks for this section',
                  child: Text(
                    marks,
                    key: ValueKey<String>('section-total-${section.shortName}'),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnmarkedRow extends StatelessWidget {
  const _UnmarkedRow({required this.question, required this.answer, required this.onOpen});

  final Question question;
  final StudentAnswer? answer;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String text = answer == null || answer!.isEmpty
        ? 'No answer found'
        : answer!.text.replaceAll('\n', ' ');
    return ListTile(
      dense: true,
      onTap: onOpen,
      title: Text('Question ${question.displayNumber}', style: theme.textTheme.titleSmall),
      subtitle: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        'not marked · ${formatMarks(question.maximumMarks ?? 0)} available',
        style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
      ),
    );
  }
}

/// Awarded out of maximum, coloured by how much was earned.
class MarksBadge extends StatelessWidget {
  const MarksBadge({super.key, required this.awarded, required this.maximum, this.gold = false});

  final double awarded;
  final double maximum;

  /// Gold for an answer that earned a syllabus badge.
  final bool gold;

  @override
  Widget build(BuildContext context) {
    final bool full = maximum > 0 && awarded >= maximum;
    final bool none = awarded <= 0;
    final Color foreground = gold
        ? AppTheme.gold
        : full
        ? AppTheme.success
        : none
            ? AppTheme.danger
            : AppTheme.caution;
    final Color background = gold
        ? AppTheme.goldFill
        : full
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
        style: TextStyle(color: foreground, fontWeight: FontWeight.w600, fontSize: 13),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.icon, required this.colour});

  final String label;
  final IconData icon;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.08),
        border: Border.all(color: colour.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: colour),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11.5, color: colour)),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.title, required this.body, this.action});

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

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
          Icon(icon, size: 16, color: AppTheme.caution),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.titleSmall?.copyWith(color: AppTheme.caution)),
                const SizedBox(height: 2),
                Text(body, style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.caution)),
              ],
            ),
          ),
          if (action != null) ...<Widget>[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }
}

/// Things processing wants the teacher to know, folded away by default.
class _Notes extends StatelessWidget {
  const _Notes({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.subtleBackground,
        border: Border.all(color: AppTheme.stroke),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        leading: const Icon(Icons.info_outline, size: 16, color: AppTheme.textSecondary),
        title: Text('Processing notes (${warnings.length})', style: theme.textTheme.titleSmall),
        children: <Widget>[
          for (final String warning in warnings)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('• $warning', style: theme.textTheme.bodySmall),
              ),
            ),
        ],
      ),
    );
  }
}

class _TotalBar extends StatelessWidget {
  const _TotalBar({
    required this.result,
    required this.reviews,
    this.sections = const <SectionTotal>[],
  });

  final CorrectionResult result;
  final TeacherReviewBook reviews;

  /// Shown as a one-line breakdown under the total.
  final List<SectionTotal> sections;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double total = reviews.finalTotal(result);
    final double fraction = result.maximumTotalMarks > 0
        ? (total / result.maximumTotalMarks).clamp(0.0, 1.0)
        : 0.0;
    final int outstanding = reviews.outstanding(result);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F6FC),
        border: Border.all(color: const Color(0xFFCFE2F3)),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool showBar = constraints.maxWidth >= 520;
          return Row(
            children: <Widget>[
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      'Total marks: ${formatMarks(total)} / '
                      '${formatMarks(result.maximumTotalMarks)}',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
                    ),
                    if (sections.isNotEmpty)
                      Text(
                        sections
                            .map((SectionTotal s) => '${s.shortName} '
                                '${formatMarks(s.awarded)}/${formatMarks(s.maximum)}')
                            .join('   ·   '),
                        key: const Key('section-breakdown'),
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    if (result.standard.isNotEmpty)
                      Text(
                        'Marked to: ${result.standard}',
                        key: const Key('marked-to'),
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                      ),
                    if (reviews.overrideCount > 0 || outstanding > 0)
                      Text(
                        <String>[
                          if (reviews.overrideCount > 0)
                            '${reviews.overrideCount} changed by you · AI total '
                                '${formatMarks(result.totalMarks)}',
                          if (outstanding > 0) '$outstanding still to review',
                        ].join('   ·   '),
                        style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                      ),
                  ],
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
              Text(
                'Percentage: ${formatPercentage(reviews.finalPercentage(result))}',
                style: theme.textTheme.titleLarge?.copyWith(fontSize: 18, color: AppTheme.accent),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 28, color: AppTheme.textDisabled),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }
}
