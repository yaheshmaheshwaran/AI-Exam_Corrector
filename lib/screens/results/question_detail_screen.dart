import 'dart:io';

import 'package:flutter/material.dart';

import 'package:exam_corrector/services/ui_sound.dart';

import 'package:exam_corrector/app/press_feedback.dart';
import 'package:flutter/services.dart';

import 'package:exam_corrector/widgets/ui/ui.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/marking/teacher_key.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/page_viewer.dart';
import 'package:exam_corrector/widgets/results_view.dart';
import 'package:exam_corrector/widgets/syllabus_badge.dart';

/// Everything behind one question's mark, and the teacher's say over it.
///
/// Built so the mark can be checked rather than trusted: the student's
/// original ink sits beside what the machine read from it, every marking point
/// names the regions it was awarded for, and a click on any of them shows
/// that region on the scanned page.
class QuestionDetailScreen extends StatefulWidget {
  const QuestionDetailScreen({
    super.key,
    required this.controller,
    required this.questionId,
  });

  final CorrectionController controller;
  final String questionId;

  static const String routeName = '/question';

  static Future<void> open(
    BuildContext context,
    CorrectionController controller,
    String questionId,
  ) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: routeName),
        builder: (_) => QuestionDetailScreen(controller: controller, questionId: questionId),
      ),
    );
  }

  @override
  State<QuestionDetailScreen> createState() => _QuestionDetailScreenState();
}

class _QuestionDetailScreenState extends State<QuestionDetailScreen> {
  late String _questionId = widget.questionId;

  CorrectionController get _controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: _controller,
        builder: (BuildContext context, _) {
          final ExamAssessment? assessment = _controller.assessment;
          final Question? question = assessment?.questionPaper.byId(_questionId);
          if (assessment == null || question == null) {
            return const Center(child: Text('This question is no longer available.'));
          }

          final QuestionResult? marked = assessment.result?.question(_questionId);
          final StudentAnswer answer = assessment.answers[_questionId] ??
              StudentAnswer.none(_questionId);
          final List<Question> all = assessment.questionPaper.markable;
          final int index = all.indexWhere((Question q) => q.questionId == _questionId);

          return Column(
            children: <Widget>[
              _Header(
                question: question,
                marked: marked,
                review: _controller.reviews[_questionId],
                finalMarks: marked == null ? null : _controller.reviews.finalMarks(marked),
                onPrevious: index > 0
                    ? () => setState(() => _questionId = all[index - 1].questionId)
                    : null,
                onNext: index < all.length - 1
                    ? () => setState(() => _questionId = all[index + 1].questionId)
                    : null,
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final Widget evidence = _EvidenceColumn(
                      assessment: assessment,
                      question: question,
                      answer: answer,
                      marked: marked,
                      controller: _controller,
                    );
                    final Widget marking = _MarkingColumn(
                      assessment: assessment,
                      marked: marked,
                      controller: _controller,
                      questionId: _questionId,
                    );
                    if (constraints.maxWidth < 980) {
                      return ListView(
                        padding: const EdgeInsets.all(AppTheme.pagePadding),
                        children: <Widget>[evidence, const SizedBox(height: AppTheme.gap), marking],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          flex: 6,
                          child: ListView(
                            padding: const EdgeInsets.all(AppTheme.pagePadding),
                            children: <Widget>[evidence],
                          ),
                        ),
                        Expanded(
                          flex: 5,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(
                              0,
                              AppTheme.pagePadding,
                              AppTheme.pagePadding,
                              AppTheme.pagePadding,
                            ),
                            children: <Widget>[marking],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Header
// ----------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.question,
    required this.marked,
    required this.review,
    required this.finalMarks,
    required this.onPrevious,
    required this.onNext,
  });

  final Question question;
  final QuestionResult? marked;
  final TeacherReview? review;
  final double? finalMarks;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(bottom: BorderSide(color: context.colors.border)),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Back to the results',
            icon: const Icon(Icons.arrow_back, size: 18),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 4),
          Text('Question ${question.displayNumber}', style: theme.textTheme.titleLarge),
          if (question.sectionId != null) ...<Widget>[
            const SizedBox(width: 10),
            Text('Section ${question.sectionId}',
                style: context.text.caption),
          ],
          const Spacer(),
          if (marked != null) ...<Widget>[
            if (review?.isOverride ?? false)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Text(
                  'AI ${formatMarks(marked!.awardedMarks)} → yours',
                  style: theme.textTheme.bodySmall?.copyWith(color: context.colors.primary),
                ),
              ),
            if (marked!.needsReview && review == null)
              const Padding(
                padding: EdgeInsets.only(right: 10),
                child: StatusPill(label: 'Needs your review', icon: Icons.flag_outlined, tone: ToneKind.warning),
              ),
            MarksBadge(
              awarded: finalMarks!,
              maximum: marked!.maximumMarks,
              bonus: marked!.syllabusBadge != SyllabusBadge.none,
            ),
          ] else
            Text('Not marked', style: theme.textTheme.bodySmall),
          const SizedBox(width: 12),
          IconButton(
            tooltip: 'Previous question',
            icon: const Icon(Icons.chevron_left, size: 20),
            onPressed: onPrevious,
          ),
          IconButton(
            tooltip: 'Next question',
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Evidence: the question, and the student's answer as it was written and read
// ----------------------------------------------------------------------------

class _EvidenceColumn extends StatelessWidget {
  const _EvidenceColumn({
    required this.assessment,
    required this.question,
    required this.answer,
    required this.marked,
    required this.controller,
  });

  final ExamAssessment assessment;
  final Question question;
  final StudentAnswer answer;
  final QuestionResult? marked;
  final CorrectionController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Map<String, TextEvidenceItem> textById = <String, TextEvidenceItem>{
      for (final TextEvidenceItem item in answer.textEvidence) item.regionId: item,
    };
    final Map<String, VisualEvidence> visualById = <String, VisualEvidence>{
      for (final VisualEvidence visual in answer.visualEvidence) visual.regionId: visual,
    };
    final Set<String> crossed = <String>{
      for (final TextEvidenceItem item in answer.crossedOut) item.regionId,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppCard(
          title: 'Question',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SelectableText(
                question.questionText.isEmpty ? '(No wording was read for this question.)' : question.questionText,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 6),
              Text(
                question.maximumMarks == null
                    ? 'No marks are printed for this question.'
                    : 'Maximum marks: ${formatMarks(question.maximumMarks!)}'
                        '${question.marksStated ? '' : ' (inferred)'}',
                style: context.text.caption,
              ),
              if (marked?.syllabusReference case final String unit when unit.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    Icon(Icons.menu_book_outlined, size: 15, color: context.colors.textMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Syllabus: $unit${assessment.syllabus == null ? '' : ' · ${assessment.syllabus!.name}'}'
                        ' — marked against what this course teaches here',
                        style: context.text.caption,
                      ),
                    ),
                  ],
                ),
              ],
              if (assessment.questionPaper.choicesOf(question.questionId) case [final first, ...]) ...<Widget>[
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.alt_route, size: 15, color: context.colors.textMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'One alternative of a choice: '
                        '${assessment.questionPaper.describeChoice(first.choice)}.'
                        '${marked?.choiceNote.isNotEmpty ?? false ? ' ${marked!.choiceNote}' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: marked?.counted ?? true ? context.colors.textMuted : context.colors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (assessment.questionPaper.markSchemeFor(question) case final String scheme
            when scheme.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppTheme.gap),
          AppCard(
            title: 'Mark scheme',
            subtitle: 'Printed on the question paper',
            child: SelectableText(scheme, style: theme.textTheme.bodyMedium),
          ),
        ] else if (controller.teacherKey?.entries[question.questionId] case final TeacherKeyEntry own
            when !own.isEmpty) ...<Widget>[
          const SizedBox(height: AppTheme.gap),
          AppCard(
            key: const Key('your-answer-key'),
            title: 'Your answer key',
            subtitle: controller.teacherKey!.fileName,
            child: SelectableText(own.text, style: theme.textTheme.bodyMedium),
          ),
        ],
        const SizedBox(height: AppTheme.gap),
        AppCard(
          title: 'Student answer',
          subtitle: answer.isEmpty
              ? null
              : 'Page${answer.pages.length == 1 ? '' : 's'} ${answer.pages.join(', ')} · '
                  'read with ${(answer.answerConfidence * 100).round()}% confidence',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (answer.isEmpty)
                Text(
                  'No answer to this question was found on the answer sheet.',
                  style: context.text.muted,
                )
              else
                for (final String regionId in answer.regionIds)
                  if (!crossed.contains(regionId) &&
                      (textById.containsKey(regionId) ||
                          answer.visualRegionIds.contains(regionId)))
                    _RegionEvidence(
                      assessment: assessment,
                      regionId: regionId,
                      text: textById[regionId],
                      visual: visualById[regionId],
                      isVisual: answer.visualRegionIds.contains(regionId),
                      controller: controller,
                    ),
              _ChooseAnswerBar(
                assessment: assessment,
                questionId: question.questionId,
                noAnswer: answer.isEmpty,
                controller: controller,
              ),
            ],
          ),
        ),
        if (answer.crossedOut.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppTheme.gap),
          AppCard(
            title: 'Crossed out',
            subtitle: 'Not part of the final answer. Shown so you can check it.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final TextEvidenceItem item in answer.crossedOut)
                  _RegionEvidence(
                    assessment: assessment,
                    regionId: item.regionId,
                    text: item,
                    visual: null,
                    isVisual: false,
                    controller: controller,
                  ),
              ],
            ),
          ),
        ],
        if (marked != null && marked!.interpretedReadings.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppTheme.gap),
          AppCard(
            title: 'Read in context',
            subtitle: 'Where the marking relied on interpreting unclear writing. '
                'The raw transcription above is unchanged.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final InterpretedReading reading in marked!.interpretedReadings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text.rich(
                      TextSpan(children: <InlineSpan>[
                        TextSpan(
                          text: '“${reading.raw}”',
                          style: TextStyle(color: context.colors.textMuted),
                        ),
                        const TextSpan(text: '  →  '),
                        TextSpan(
                          text: '“${reading.interpreted}”',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: '   (${reading.basis.name})',
                          style: context.text.caption,
                        ),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (answer.flags.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppTheme.gap),
          AppCard(
            title: 'About this answer',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final String flag in answer.flags)
                  Text('• $flag', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// One region of the answer: its original image, and what was read from it.
class _RegionEvidence extends StatelessWidget {
  const _RegionEvidence({
    required this.assessment,
    required this.regionId,
    required this.text,
    required this.visual,
    required this.isVisual,
    required this.controller,
  });

  final ExamAssessment assessment;
  final String regionId;
  final TextEvidenceItem? text;
  final VisualEvidence? visual;
  final bool isVisual;
  final CorrectionController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PageRegion? region = assessment.region(regionId);
    if (region == null) return const SizedBox.shrink();
    final ExamPage? page = assessment.answerSheet.page(region.pageId);
    final TextEvidenceItem? item = text;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(color: context.colors.border),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
            color: context.colors.surfaceMuted,
            child: Row(
              children: <Widget>[
                Container(width: 8, height: 8, color: regionColor(region.type)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Page ${region.pageNumber} · Region ${region.readingOrder + 1} · '
                    '${region.type.displayName}'
                    '${item == null ? '' : ' · ${item.source.label}, ${(item.confidence * 100).round()}%'}',
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (page != null)
                  TextButton.icon(
                    onPressed: () => showRegionOnPage(
                      context,
                      page: page,
                      region: region,
                      marks: <NormalizedBox>[
                        for (final UncertainSpan span in item?.uncertainSpans ?? const <UncertainSpan>[])
                          if (span.box != null) span.box!,
                      ],
                    ),
                    icon: const Icon(Icons.open_in_full, size: 14),
                    label: const Text('Show on page'),
                  ),
              ],
            ),
          ),
          if (region.cropPath != null)
            GestureDetector(
              onTap: page == null ? null : () => showRegionOnPage(context, page: page, region: region),
              child: Container(
                color: Colors.white,
                constraints: BoxConstraints(maxHeight: isVisual ? 340 : 220),
                padding: const EdgeInsets.all(6),
                alignment: Alignment.centerLeft,
                child: Image.file(
                  File(region.cropPath!),
                  fit: BoxFit.contain,
                  cacheWidth: 1400,
                  // A skeleton line holds the place until the crop decodes.
                  frameBuilder: (BuildContext context, Widget child, int? frame, bool sync) =>
                      sync || frame != null ? child : const SizedBox(height: 60, child: SkeletonImage()),
                  errorBuilder: (_, _, _) => Text(
                    'The image of this region is missing.',
                    style: context.text.faint,
                  ),
                ),
              ),
            ),
          if (item != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: _RecognizedText(item: item, controller: controller),
            ),
          if (isVisual)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              child: _VisualDetails(visual: visual),
            ),
        ],
      ),
    );
  }
}

/// A region's transcription, uncertain words highlighted, with the teacher's
/// correction and the machine's original reading both in view.
class _RecognizedText extends StatelessWidget {
  const _RecognizedText({required this.item, required this.controller});

  final TextEvidenceItem item;
  final CorrectionController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool corrected = item.source == ReadingSource.teacher;
    final bool editable = item.source != ReadingSource.textLayer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          corrected ? 'Your reading' : 'Recognised text',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 2),
        SelectableText.rich(
          TextSpan(
            style: theme.textTheme.bodyMedium,
            children: _spans(item.text, corrected ? const <UncertainSpan>[] : item.uncertainSpans, context.colors.highlight),
          ),
        ),
        if (corrected)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Machine reading: ${item.rawText}',
              style: context.text.caption,
            ),
          ),
        if (item.alternativeReading != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'A second recogniser read: ${item.alternativeReading}',
              style: theme.textTheme.bodySmall?.copyWith(color: context.colors.warning),
            ),
          ),
        if (editable)
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 4,
              children: <Widget>[
                TextButton.icon(
                  onPressed: () => _edit(context),
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: Text(corrected ? 'Edit your reading' : 'Correct transcription'),
                ),
                if (corrected)
                  TextButton(
                    onPressed: () => controller.revertTranscription(item.regionId),
                    child: const Text('Use the machine reading'),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  static List<InlineSpan> _spans(String text, List<UncertainSpan> spans, Color highlight) {
    final List<UncertainSpan> located = <UncertainSpan>[
      for (final UncertainSpan span in spans)
        if (span.start != null &&
            span.end != null &&
            span.start! >= 0 &&
            span.end! <= text.length &&
            span.start! < span.end!)
          span,
    ]..sort((UncertainSpan a, UncertainSpan b) => a.start!.compareTo(b.start!));

    final List<InlineSpan> out = <InlineSpan>[];
    int cursor = 0;
    for (final UncertainSpan span in located) {
      if (span.start! < cursor) continue;
      out.add(TextSpan(text: text.substring(cursor, span.start)));
      out.add(TextSpan(
        text: text.substring(span.start!, span.end),
        style: TextStyle(backgroundColor: highlight),
      ));
      cursor = span.end!;
    }
    out.add(TextSpan(text: text.substring(cursor)));
    return out;
  }

  Future<void> _edit(BuildContext context) async {
    final String? corrected = await showAppDialog<String>(
      context: context,
      builder: (BuildContext context) => _TranscriptionDialog(initial: item.text),
    );
    if (corrected != null && corrected.trim() != item.text.trim()) {
      await controller.correctTranscription(item.regionId, corrected);
    }
  }
}

/// Owns its text field's controller, so the field outlives the dialog's
/// closing animation.
class _TranscriptionDialog extends StatefulWidget {
  const _TranscriptionDialog({required this.initial});

  final String initial;

  @override
  State<_TranscriptionDialog> createState() => _TranscriptionDialogState();
}

class _TranscriptionDialogState extends State<_TranscriptionDialog> {
  late final TextEditingController _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Correct the transcription'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Type what the student actually wrote. The machine reading is '
              'kept, and only this question is re-marked.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('transcription-field'),
              controller: _field,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _VisualDetails extends StatelessWidget {
  const _VisualDetails({required this.visual});

  final VisualEvidence? visual;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final VisualEvidence? evidence = visual;
    if (evidence == null || !evidence.analyzed) {
      return Text(
        evidence?.error == null
            ? 'Not analysed. The marker judged it from the image.'
            : 'Not analysed (${evidence!.error}). The marker judged it from the image.',
        style: theme.textTheme.bodySmall?.copyWith(color: context.colors.warning),
      );
    }

    Widget line(String label, String value) => value.trim().isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text.rich(TextSpan(children: <InlineSpan>[
              TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: value),
            ])),
          );

    return DefaultTextStyle.merge(
      style: theme.textTheme.bodySmall,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Visual analysis · ${(evidence.confidence * 100).round()}% confident',
            style: theme.textTheme.titleSmall,
          ),
          line('Description', evidence.description),
          ...switch (evidence) {
            DiagramEvidence() => <Widget>[
                line('Labels', evidence.labels.join('; ')),
                line('Components', evidence.components.join('; ')),
                line('Relationships', evidence.relationships.join('; ')),
              ],
            GraphEvidence() => <Widget>[
                line('x-axis', evidence.xAxis),
                line('y-axis', evidence.yAxis),
                line('Plotted', evidence.plottedElements.join('; ')),
                line('Values', evidence.approximateValues.join('; ')),
                line('Trend', evidence.trend),
              ],
            TableEvidence() => <Widget>[
                if (evidence.rows.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Table(
                      border: TableBorder.all(color: context.colors.border),
                      defaultColumnWidth: const IntrinsicColumnWidth(),
                      children: <TableRow>[
                        for (final List<String> row in _rectangular(evidence.rows))
                          TableRow(children: <Widget>[
                            for (final String cell in row)
                              Padding(padding: const EdgeInsets.all(4), child: Text(cell)),
                          ]),
                      ],
                    ),
                  ),
                line('Crossed-out cells', evidence.crossedOutCells.join('; ')),
              ],
            EquationEvidence() => <Widget>[
                line('LaTeX', evidence.latex),
                line('As text', evidence.plainText),
              ],
          },
          line('Relevance', evidence.relevance),
        ],
      ),
    );
  }

  static List<List<String>> _rectangular(List<List<String>> rows) {
    final int width = rows.fold<int>(0, (int w, List<String> r) => r.length > w ? r.length : w);
    return <List<String>>[
      for (final List<String> row in rows)
        <String>[...row, for (int i = row.length; i < width; i++) ''],
    ];
  }
}

// ----------------------------------------------------------------------------
// Marking: points, reasoning, confidence, and the teacher's decision
// ----------------------------------------------------------------------------

class _MarkingColumn extends StatelessWidget {
  const _MarkingColumn({
    required this.assessment,
    required this.marked,
    required this.controller,
    required this.questionId,
  });

  final ExamAssessment assessment;
  final QuestionResult? marked;
  final CorrectionController controller;
  final String questionId;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final QuestionResult? result = marked;
    if (result == null) {
      return const AppCard(
        title: 'Marking',
        child: Text('This question has not been marked yet.'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (result.syllabusAward case final SyllabusAward award) ...<Widget>[
          AppCard(
            key: const Key('syllabus-match-panel'),
            title: 'Syllabus match',
            subtitle: award.summary,
            tone: ToneKind.bonus,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (award.hasBadge) ...<Widget>[
                  SyllabusBadgeChip(badge: award.badge, bonus: award.bonus),
                  const SizedBox(height: 8),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('No badge — not close enough to the syllabus for this question.',
                        style: theme.textTheme.bodySmall),
                  ),
                if (award.matched.isNotEmpty)
                  Text('Covered: ${award.matched.join(', ')}',
                      style: theme.textTheme.bodySmall?.copyWith(color: context.colors.bonus)),
                if (award.missing.isNotEmpty)
                  Text('Not covered: ${award.missing.join(', ')}',
                      style: context.text.caption),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.gap),
        ],
        if (result.adjustments.isNotEmpty) ...<Widget>[
          AppCard(
            title: 'Marking standard',
            subtitle: 'The AI marked ${formatMarks(result.aiRawMarks ?? result.awardedMarks)}; '
                'the paper’s standard changed it:',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final String adjustment in result.adjustments)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      '•  $adjustment',
                      style: adjustment.contains('syllabus bonus')
                          ? theme.textTheme.bodySmall?.copyWith(color: context.colors.bonus, fontWeight: FontWeight.w600)
                          : theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.gap),
        ],
        if (result.qualityBand case final QualityBand band) ...<Widget>[
          Container(
            key: const Key('quality-band'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: context.colors.surfaceMuted,
              border: Border.all(color: context.colors.border),
              borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            ),
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(text: 'Quality: ${band.label}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: ' — ${result.bandReason.isEmpty ? band.description : result.bandReason}'),
                ],
              ),
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: AppTheme.gap),
        ],
        AppCard(
          title: 'Marking points',
          subtitle: switch (result.markingPointsSource) {
            MarkingPointSource.teacherGuidance => 'From your marking guidance',
            MarkingPointSource.markScheme =>
              'From the mark scheme on the question paper',
            MarkingPointSource.answerKey =>
              'From the AI\'s answer key, fixed before any script was read — '
                  'open Answer key to change it',
            MarkingPointSource.teacherKey =>
              'From your answer key — open Answer key to change it',
            MarkingPointSource.inferred =>
              'Inferred by the AI from the question — check that they are the '
                  'points you would reward',
          },
          child: result.markingPoints.isEmpty
              ? Text('No marking points.', style: theme.textTheme.bodySmall)
              : Column(
                  children: <Widget>[
                    for (final MarkingPoint point in result.markingPoints)
                      _PointRow(point: point, assessment: assessment),
                  ],
                ),
        ),
        const SizedBox(height: AppTheme.gap),
        AppCard(
          title: 'Reason',
          child: SelectableText(result.evaluation, style: theme.textTheme.bodyMedium),
        ),
        const SizedBox(height: AppTheme.gap),
        AppCard(
          title: 'Confidence: ${(result.confidence * 100).round()}%',
          subtitle: result.model.isEmpty ? null : 'Marked by ${result.model}',
          child: result.reviewReasons.isEmpty
              ? Text(
                  result.needsReview ? 'Flagged for review.' : 'Nothing was flagged for review.',
                  style: theme.textTheme.bodySmall,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final String reason in result.reviewReasons)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          '• $reason',
                          style: theme.textTheme.bodySmall?.copyWith(color: context.colors.warning),
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: AppTheme.gap),
        TeacherReviewPanel(
          key: ValueKey<String>('review-$questionId'),
          question: result,
          review: controller.reviews[questionId],
          onAccept: (String comment) => controller.acceptMark(questionId, comment: comment),
          onOverride: (double marks, String comment) =>
              controller.overrideMark(questionId, marks, comment: comment),
          onClear: () => controller.clearReview(questionId),
        ),
      ],
    );
  }
}

class _PointRow extends StatelessWidget {
  const _PointRow({required this.point, required this.assessment});

  final MarkingPoint point;
  final ExamAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color colour = point.satisfied ? context.colors.success : context.colors.danger;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 8),
            child: Icon(
              point.satisfied ? Icons.check_circle_outline : Icons.cancel_outlined,
              size: 16,
              color: colour,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(point.criterion, style: theme.textTheme.bodyMedium),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    if (point.basis != EvidenceBasis.observed || point.marks > 0)
                      _BasisTag(basis: point.basis),
                    for (final String regionId in point.evidenceRegionIds)
                      _EvidenceChip(assessment: assessment, regionId: regionId),
                  ],
                ),
                if (point.note.isNotEmpty)
                  Text(point.note,
                      style: context.text.caption),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${formatMarks(point.marks)}/${formatMarks(point.marksAvailable)}',
            style: TextStyle(color: colour, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _BasisTag extends StatelessWidget {
  const _BasisTag({required this.basis});

  final EvidenceBasis basis;

  @override
  Widget build(BuildContext context) {
    final (String label, ToneKind tone) = switch (basis) {
      EvidenceBasis.observed => ('observed', ToneKind.success),
      EvidenceBasis.inferred => ('inferred from context', ToneKind.warning),
      EvidenceBasis.uncertain => ('uncertain', ToneKind.danger),
    };
    return Text(label, style: context.text.caption.copyWith(color: context.colors.tone(tone).foreground));
  }
}

/// "Page 4 → Region 17": click to see it on the page.
class _EvidenceChip extends StatelessWidget {
  const _EvidenceChip({required this.assessment, required this.regionId});

  final ExamAssessment assessment;
  final String regionId;

  @override
  Widget build(BuildContext context) {
    final PageRegion? region = assessment.region(regionId);
    final ExamPage? page = assessment.pageOf(regionId);
    if (region == null || page == null) return const SizedBox.shrink();
    return ActionChip(
      key: ValueKey<String>('evidence-$regionId'),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
      avatar: Icon(Icons.crop_free, size: 12, color: regionColor(region.type)),
      label: Text(
        'Page ${region.pageNumber} → Region ${region.readingOrder + 1}',
        style: context.text.caption.copyWith(color: context.colors.text),
      ),
      onPressed: () => showRegionOnPage(context, page: page, region: region),
    );
  }
}

/// The teacher's decision on one question. The AI's mark is never
/// overwritten: both are shown and both are kept.
class TeacherReviewPanel extends StatefulWidget {
  const TeacherReviewPanel({
    super.key,
    required this.question,
    required this.review,
    required this.onAccept,
    required this.onOverride,
    required this.onClear,
  });

  final QuestionResult question;
  final TeacherReview? review;
  final ValueChanged<String> onAccept;
  final void Function(double marks, String comment) onOverride;
  final VoidCallback onClear;

  @override
  State<TeacherReviewPanel> createState() => _TeacherReviewPanelState();
}

class _TeacherReviewPanelState extends State<TeacherReviewPanel> {
  late final TextEditingController _marks = TextEditingController(
    text: formatMarks(widget.review?.teacherMarks ?? widget.question.awardedMarks),
  );
  late final TextEditingController _comment =
      TextEditingController(text: widget.review?.comment ?? '');
  String? _error;

  @override
  void dispose() {
    _marks.dispose();
    _comment.dispose();
    super.dispose();
  }

  void _save() {
    final double? value = double.tryParse(_marks.text.trim());
    if (value == null || value < 0 || value > widget.question.maximumMarks) {
      setState(() => _error =
          'Enter a mark from 0 to ${formatMarks(widget.question.maximumMarks)}.');
      return;
    }
    setState(() => _error = null);
    if ((value - widget.question.awardedMarks).abs() < 0.0001) {
      widget.onAccept(_comment.text.trim());
    } else {
      widget.onOverride(value, _comment.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final TeacherReview? review = widget.review;
    final String status = switch (review?.status) {
      ReviewStatus.accepted => 'You accepted the AI mark.',
      ReviewStatus.overridden =>
        'You changed the mark from ${formatMarks(review!.aiMarks)} to ${formatMarks(review.teacherMarks!)}.',
      _ => 'Not reviewed yet.',
    };

    return AppCard(
      title: 'Your review',
      subtitle: status,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('AI: ${formatMarks(widget.question.awardedMarks)} / '
              '${formatMarks(widget.question.maximumMarks)}'),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              const Text('Teacher:  '),
              SizedBox(
                width: 72,
                child: TextField(
                  key: const Key('teacher-mark'),
                  controller: _marks,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                ),
              ),
              Text('  / ${formatMarks(widget.question.maximumMarks)}'),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_error!, style: context.text.caption.copyWith(color: context.colors.danger)),
            ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('teacher-comment'),
            controller: _comment,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(hintText: 'Reason (optional)'),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              OutlinedButton.icon(
                key: const Key('accept-mark'),
                onPressed: () {
                  _marks.text = formatMarks(widget.question.awardedMarks);
                  widget.onAccept(_comment.text.trim());
                },
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Accept'),
              ),
              FilledButton.icon(
                key: const Key('save-mark'),
                onPressed: _save,
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('Save mark'),
              ),
              if (review != null)
                TextButton(onPressed: widget.onClear, child: const Text('Clear review')),
            ],
          ),
          if (review != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Recorded ${review.timestamp.toLocal().toString().substring(0, 16)}',
                style: context.text.caption,
              ),
            ),
        ],
      ),
    );
  }
}

/// The teacher's way to put right an answer the app did not find, or found
/// in the wrong place: choose the writing on the sheet that answers this
/// question.
class _ChooseAnswerBar extends StatelessWidget {
  const _ChooseAnswerBar({
    required this.assessment,
    required this.questionId,
    required this.noAnswer,
    required this.controller,
  });

  final ExamAssessment assessment;
  final String questionId;
  final bool noAnswer;
  final CorrectionController controller;

  Future<void> _choose(BuildContext context) async {
    final List<String>? chosen = await showAppDialog<List<String>>(
      context: context,
      builder: (BuildContext context) => _ChooseAnswerDialog(
        assessment: assessment,
        questionId: questionId,
        assignments: controller.assignments,
        preselectUnmatched: noAnswer,
      ),
    );
    if (chosen != null) await controller.assignRegions(questionId, chosen);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int chosen =
        controller.assignments.values.where((String q) => q == questionId).length;
    final bool busy = controller.isBusy;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (noAnswer && chosen == 0)
            FilledButton.tonalIcon(
              key: const Key('choose-answer'),
              onPressed: busy ? null : () => _choose(context),
              icon: const Icon(Icons.touch_app_outlined, size: 16),
              label: const Text('Choose the answer on the page…'),
            )
          else
            TextButton.icon(
              key: const Key('choose-answer'),
              onPressed: busy ? null : () => _choose(context),
              icon: const Icon(Icons.touch_app_outlined, size: 16),
              label: Text(chosen == 0 ? 'Choose the answer on the page…' : 'Change your choice…'),
            ),
          if (chosen > 0) ...<Widget>[
            Text(
              'You chose $chosen piece${chosen == 1 ? '' : 's'} of writing for this answer'
              '${controller.hasPendingCorrections ? ' — re-mark to apply.' : '.'}',
              style: theme.textTheme.bodySmall?.copyWith(color: context.colors.primary),
            ),
            TextButton(
              onPressed: busy ? null : () => controller.clearAssignments(questionId),
              child: const Text('Undo'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Lists the answer sheet's writing, page by page, with where the app put
/// each piece, for the teacher to tick what answers this question.
class _ChooseAnswerDialog extends StatefulWidget {
  const _ChooseAnswerDialog({
    required this.assessment,
    required this.questionId,
    required this.assignments,
    required this.preselectUnmatched,
  });

  final ExamAssessment assessment;
  final String questionId;
  final Map<String, String> assignments;
  final bool preselectUnmatched;

  @override
  State<_ChooseAnswerDialog> createState() => _ChooseAnswerDialogState();
}

class _ChooseAnswerDialogState extends State<_ChooseAnswerDialog> {
  late final Set<String> _selected;
  late final List<PageRegion> _unmatched;
  late final List<PageRegion> _others;

  ExamAssessment get _a => widget.assessment;

  @override
  void initState() {
    super.initState();
    final Set<String> loose = <String>{
      ..._a.alignment.unassignedRegionIds,
      ..._a.alignment.preambleRegionIds,
    };
    final List<PageRegion> regions = <PageRegion>[
      for (final ExamPage page in _a.answerSheet.pages)
        for (final PageRegion region in List<PageRegion>.of(page.regions)
          ..sort((PageRegion x, PageRegion y) => x.readingOrder.compareTo(y.readingOrder)))
          if (_offerable(region)) region,
    ];
    _unmatched = <PageRegion>[
      for (final PageRegion r in regions)
        if (loose.contains(r.regionId) && !widget.assignments.containsKey(r.regionId)) r,
    ];
    _others = <PageRegion>[
      for (final PageRegion r in regions)
        if (!_unmatched.contains(r)) r,
    ];
    _selected = <String>{
      for (final MapEntry<String, String> e in widget.assignments.entries)
        if (e.value == widget.questionId) e.key,
      if (widget.preselectUnmatched)
        for (final PageRegion r in _unmatched)
          if (r.type.isAnswerContent) r.regionId,
    };
  }

  bool _offerable(PageRegion region) {
    if (region.type == RegionType.header || region.type == RegionType.footer) return false;
    if (region.parentRegionId != null &&
        (region.type == RegionType.label || region.type == RegionType.equation)) {
      return false;
    }
    // A block split at a label is offered as its parts, not as a whole.
    return !_a.answerSheet.regions
        .any((PageRegion other) => other.parentRegionId == region.regionId && other.origin == RegionOrigin.derived && other.type == region.type);
  }

  String _preview(PageRegion region) {
    final String? text =
        _a.evidence.handwriting[region.regionId]?.effectiveText ?? region.detectedText;
    if (text != null && text.trim().isNotEmpty) return text.replaceAll('\n', ' / ');
    return '[${region.type.displayName.toLowerCase()}]';
  }

  String _where(PageRegion region) {
    final String? chosenFor = widget.assignments[region.regionId];
    if (chosenFor != null) {
      return chosenFor == widget.questionId
          ? 'Chosen by you for this question'
          : 'Chosen by you for question ${_a.questionPaper.byId(chosenFor)?.displayNumber ?? chosenFor}';
    }
    if (_a.alignment.preambleRegionIds.contains(region.regionId)) return 'Before the first question';
    final List<String>? questions = _a.alignment.questionsByRegion[region.regionId];
    if (questions == null || questions.isEmpty) return 'Not matched to any question';
    return 'Question ${questions.map((String id) => _a.questionPaper.byId(id)?.displayNumber ?? id).join(', ')}';
  }

  Widget _tile(PageRegion region) {
    final String id = region.regionId;
    return ToggleRow(child: CheckboxListTile(
      key: ValueKey<String>('choose-$id'),
      dense: true,
      value: _selected.contains(id),
      controlAffinity: ListTileControlAffinity.leading,
      onChanged: toggled((bool? on) => setState(() => on ?? false ? _selected.add(id) : _selected.remove(id))),
      title: Text(_preview(region), maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('Page ${region.pageNumber} · ${_where(region)}'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String number = _a.questionPaper.byId(widget.questionId)?.displayNumber ?? widget.questionId;
    return AlertDialog(
      title: Text('Choose the answer to question $number'),
      content: SizedBox(
        width: 600,
        height: 460,
        child: ListView(
          children: <Widget>[
            Text(
              'Tick the writing that answers this question. It is taken away from '
              'wherever the app put it, and used the next time you re-mark.',
              style: context.text.caption,
            ),
            if (_unmatched.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Text('Not matched to any question', style: theme.textTheme.titleSmall),
              for (final PageRegion region in _unmatched) _tile(region),
            ],
            const SizedBox(height: 10),
            Text('Everything else, page by page', style: theme.textTheme.titleSmall),
            for (final PageRegion region in _others) _tile(region),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('choose-answer-save'),
          onPressed: () => Navigator.of(context).pop(<String>[
            for (final PageRegion r in <PageRegion>[..._unmatched, ..._others])
              if (_selected.contains(r.regionId)) r.regionId,
          ]),
          child: const Text('Use as the answer'),
        ),
      ],
    );
  }
}

