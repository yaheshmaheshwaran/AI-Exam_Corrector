import 'package:flutter/material.dart';

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
import 'package:exam_corrector/widgets/ui/ui.dart';

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
    this.emptyDetail,
  });

  final ExamAssessment? assessment;
  final TeacherReviewBook reviews;
  final ValueChanged<String> onOpenQuestion;
  final bool pendingCorrections;
  final VoidCallback? onRemark;

  /// Shown under the empty state: what is still needed before marking.
  final Widget? emptyDetail;

  @override
  State<ResultsView> createState() => _ResultsViewState();
}

class _ResultsViewState extends State<ResultsView> {
  // Desktop does not attach a primary scroll controller, so the list and its
  // scrollbar share an explicit one.
  final ScrollController _scroll = ScrollController();

  /// Sections the teacher folded away, by short name.
  final Set<String> _collapsed = <String>{};

  /// The pinned total's height, measured, so the last row scrolls clear.
  double _total = 90;

  // When a new result arrives its first rows rise into place once; rows
  // built later — by scrolling, or after a review — simply appear.
  Object? _arrivedFor;
  DateTime _arrivedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!identical(widget.assessment?.result, _arrivedFor)) {
      _arrivedFor = widget.assessment?.result;
      if (!still && _arrivedFor != null) _arrivedAt = DateTime.now();
    }
    final ExamAssessment? assessment = widget.assessment;
    if (assessment == null) {
      return _Placeholder(
        icon: Icons.fact_check_outlined,
        message: 'Correction results will appear here.',
        detail: widget.emptyDetail,
      );
    }

    final CorrectionResult? result = assessment.result;
    final List<Widget> rows = <Widget>[
      if (widget.pendingCorrections)
        InfoBanner(
          icon: Icons.edit_note,
          title: 'Transcriptions were corrected',
          body:
              'Re-mark to apply them. Only the questions whose answers '
              'changed are sent for marking again.',
          action: widget.onRemark == null
              ? null
              : OutlinedButton(
                  onPressed: widget.onRemark,
                  child: const Text('Re-mark'),
                ),
        ),
      if (result != null && result.foundNoAnswers)
        const InfoBanner(
          icon: Icons.help_outline,
          title: 'No answers were found anywhere in this paper',
          body:
              'Every question scored zero because the marked file contains no '
              "student answers. Check that the answer sheet is the student's completed "
              'script — it is easy to choose the blank question paper for both.',
        ),
      if (result == null)
        InfoBanner(
          icon: Icons.pause_circle_outline,
          title: 'Not marked yet',
          body:
              assessment.job.error ??
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
          for (final QuestionResult question in result.questions)
            rowFor(question.questionId)
        else
          for (final Question question in assessment.questionPaper.markable)
            rowFor(question.questionId),
      ]);
    } else {
      for (final SectionTotal section in sections) {
        final bool collapsed = _collapsed.contains(section.shortName);
        rows.add(
          _SectionHeader(
            section: section,
            marked: result != null,
            collapsed: collapsed,
            onToggle: () => setState(
              () => collapsed
                  ? _collapsed.remove(section.shortName)
                  : _collapsed.add(section.shortName),
            ),
          ),
        );
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
                child: _TotalBar(
                  result: result,
                  reviews: widget.reviews,
                  sections: sections,
                ),
              );

        final Widget list = Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: Builder(
            builder: (BuildContext context) {
              // Built as they scroll into view: a long paper has many rows.
              final List<Widget> items = <Widget>[
                ...rows,
                if (!pinTotal) total,
              ];
              return ListView.builder(
                controller: _scroll,
                // Clear of the pinned total, which the rows scroll beneath.
                padding: EdgeInsets.only(
                  right: 10,
                  bottom: pinTotal && result != null ? _total : 0,
                ),
                itemCount: items.length,
                itemBuilder: (BuildContext context, int index) {
                  final bool entering =
                      index < 10 &&
                      DateTime.now().difference(_arrivedAt) <
                          const Duration(milliseconds: 400);
                  return entering
                      ? _Enter(index: index, child: items[index])
                      : items[index];
                },
              );
            },
          ),
        );
        if (!pinTotal || result == null) return list;
        return Stack(
          children: <Widget>[
            Positioned.fill(child: RepaintBoundary(child: list)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: MeasureSize(
                onSize: (Size size) {
                  if (mounted && size.height != _total) {
                    setState(() => _total = size.height);
                  }
                },
                child: total,
              ),
            ),
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
        color: context.colors.surface,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: context.colors.border),
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
                    style: context.text.caption,
                  ),
                ),
                const SizedBox(width: 10),
                if (question.syllabusAward case final SyllabusAward award
                    when award.hasBadge && counted) ...<Widget>[
                  SyllabusBadgeChip(
                    badge: award.badge,
                    bonus: award.bonus,
                    tooltip: award.summary,
                  ),
                  const SizedBox(width: 6),
                ],
                if (!counted)
                  const StatusPill(
                    label: 'Not counted',
                    icon: Icons.alt_route,
                    dense: true,
                  )
                else if (question.adjustments.isNotEmpty &&
                    status == ReviewStatus.pending &&
                    !question.needsReview)
                  Tooltip(
                    message: question.adjustments.join('\n'),
                    child: const StatusPill(
                      label: 'Adjusted',
                      icon: Icons.tune,
                      dense: true,
                    ),
                  )
                else if (status == ReviewStatus.overridden)
                  const StatusPill(
                    label: 'Changed',
                    icon: Icons.edit,
                    tone: ToneKind.primary,
                    dense: true,
                  )
                else if (status == ReviewStatus.accepted)
                  const StatusPill(
                    label: 'Accepted',
                    icon: Icons.check,
                    tone: ToneKind.success,
                    dense: true,
                  )
                else if (question.keyMatch == KeyMatch.equivalent)
                  const StatusPill(
                    label: 'Differs from your key',
                    icon: Icons.compare_arrows,
                    tone: ToneKind.warning,
                    dense: true,
                    tooltip:
                        'Credited as a correct answer that is not the one in your key — check it.',
                  )
                else if (question.needsReview)
                  const StatusPill(
                    label: 'Review',
                    icon: Icons.flag_outlined,
                    tone: ToneKind.warning,
                    dense: true,
                  ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'How sure the marking is',
                  child: Text(
                    '${(question.confidence * 100).round()}%',
                    style: context.text.caption,
                  ),
                ),
                const SizedBox(width: 10),
                MarksBadge(
                  awarded: finalMarks,
                  maximum: question.maximumMarks,
                  bonus:
                      counted && question.syllabusBadge != SyllabusBadge.none,
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
        : Tooltip(
            message: question.choiceNote,
            child: Opacity(opacity: 0.6, child: row),
          );
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
        color: context.colors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
        child: InkWell(
          key: ValueKey<String>('section-${section.shortName}'),
          onTap: onToggle,
          borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: <Widget>[
                Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 18,
                ),
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
                          style: context.text.caption,
                        ),
                    ],
                  ),
                ),
                if (section.toReview > 0) ...<Widget>[
                  StatusPill(
                    label: '${section.toReview} to review',
                    icon: Icons.flag_outlined,
                    tone: ToneKind.warning,
                    dense: true,
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
                        backgroundColor: context.colors.track,
                      ),
                    ),
                  ),
                const SizedBox(width: 10),
                Tooltip(
                  message:
                      stated != null && (stated - section.maximum).abs() > 0.001
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
  const _UnmarkedRow({
    required this.question,
    required this.answer,
    required this.onOpen,
  });

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
      title: Text(
        'Question ${question.displayNumber}',
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        'not marked · ${formatMarks(question.maximumMarks ?? 0)} available',
        style: context.text.caption,
      ),
    );
  }
}

/// Awarded out of maximum, coloured by how much was earned.
class MarksBadge extends StatelessWidget {
  const MarksBadge({
    super.key,
    required this.awarded,
    required this.maximum,
    this.bonus = false,
  });

  final double awarded;
  final double maximum;

  /// Marked in the bonus colour: the answer earned a syllabus badge.
  final bool bonus;

  @override
  Widget build(BuildContext context) {
    final bool full = maximum > 0 && awarded >= maximum;
    final bool none = awarded <= 0;
    final Tone tone = context.colors.tone(
      bonus
          ? ToneKind.bonus
          : full
          ? ToneKind.success
          : none
          ? ToneKind.danger
          : ToneKind.warning,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.fill,
        border: Border.all(color: tone.border),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Text(
        '${formatMarks(awarded)} / ${formatMarks(maximum)}',
        style: context.text.mark.copyWith(color: tone.foreground),
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
        color: context.colors.surfaceMuted,
        border: Border.all(color: context.colors.border),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        leading: Icon(
          Icons.info_outline,
          size: 16,
          color: context.colors.textMuted,
        ),
        title: Text(
          'Processing notes (${warnings.length})',
          style: theme.textTheme.titleSmall,
        ),
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

    // Frosted: the question list scrolls softly out of view beneath it.
    return Frosted(
      tint: context.colors.primarySoft,
      outline: true,
      borderColor: context.colors.primaryBorder,
      radius: AppTheme.controlRadius,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: 18,
                        ),
                      ),
                      if (sections.isNotEmpty)
                        Text(
                          sections
                              .map(
                                (SectionTotal s) =>
                                    '${s.shortName} '
                                    '${formatMarks(s.awarded)}/${formatMarks(s.maximum)}',
                              )
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
                          style: context.text.caption,
                        ),
                      if (reviews.overrideCount > 0 || outstanding > 0)
                        Text(
                          <String>[
                            if (reviews.overrideCount > 0)
                              '${reviews.overrideCount} changed by you · AI total '
                                  '${formatMarks(result.totalMarks)}',
                            if (outstanding > 0) '$outstanding still to review',
                          ].join('   ·   '),
                          style: context.text.caption,
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
                        backgroundColor: context.colors.track,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                const SizedBox(width: 16),
                Text(
                  'Percentage: ${formatPercentage(reviews.finalPercentage(result))}',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontSize: 18,
                    color: context.colors.primary,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.message, this.detail});

  final IconData icon;
  final String message;
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final Widget? detail = this.detail;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: c.surfaceMuted,
                  border: Border.all(color: c.border),
                  borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                ),
                child: Icon(icon, size: 22, color: c.textMuted),
              ),
              const SizedBox(height: 14),
              Text(
                message,
                textAlign: TextAlign.center,
                style: context.text.titleSmall.copyWith(fontSize: 14),
              ),
              if (detail != null) ...<Widget>[
                const SizedBox(height: 14),
                detail,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A row rising into place: a 6 px lift and a fade, each row 30 ms after the
/// one above it.
class _Enter extends StatefulWidget {
  const _Enter({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_Enter> createState() => _EnterState();
}

class _EnterState extends State<_Enter> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 220 + widget.index * 30),
  )..forward();
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Interval(
      widget.index * 30 / (220 + widget.index * 30),
      1,
      curve: Curves.easeOut,
    ),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _t,
      child: AnimatedBuilder(
        animation: _t,
        child: widget.child,
        builder: (BuildContext context, Widget? child) => Transform.translate(
          offset: Offset(0, 6 * (1 - _t.value)),
          child: child,
        ),
      ),
    );
  }
}
