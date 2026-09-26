import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/widgets/page_viewer.dart';

/// A published page as the page viewer draws it.
ExamPage _page(PublishedPage page) => ExamPage(
      pageId: 'published:p${page.number}',
      pageNumber: page.number,
      width: page.width,
      height: page.height,
      imagePath: page.imagePath,
    );

List<NormalizedBox> _boxesOn(PublishedQuestion question, int page) => <NormalizedBox>[
      for (final AnswerBox box in question.answerBoxes)
        if (box.page == page) NormalizedBox(x: box.x, y: box.y, width: box.width, height: box.height),
    ];

/// Said where an answer sheet was published before pages were kept.
const String notKept = 'The answer sheet was not kept for this result — ask your teacher to publish it again.';

/// One question's answer, as both the student and the teacher see it: what
/// was asked, what was read, and the student's own pages with the answer
/// outlined. Read-only.
class QuestionAnswerView extends StatelessWidget {
  const QuestionAnswerView({
    super.key,
    required this.question,
    required this.pages,
    this.pageHeight = 420,
  });

  final PublishedQuestion question;
  final List<PublishedPage> pages;

  /// How tall each page is drawn.
  final double pageHeight;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? label = theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600);
    final List<PublishedPage> on = <PublishedPage>[
      for (final int number in question.answerPages)
        ...pages.where((PublishedPage p) => p.number == number),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (question.questionText.isNotEmpty) ...<Widget>[
          Text('Question', style: label),
          Text(question.questionText, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 10),
        ],
        Text('The answer, as read', style: label),
        const SizedBox(height: 4),
        Container(
          key: ValueKey<String>('answer-text-${question.questionId}'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.pageBackground,
            border: Border.all(color: AppTheme.stroke),
            borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          ),
          child: SelectableText(
            question.answerText.trim().isEmpty ? 'No answer was found for this question.' : question.answerText,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        const SizedBox(height: 10),
        if (pages.isEmpty)
          Text(notKept, style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary))
        else if (on.isNotEmpty) ...<Widget>[
          Text(
            'Written on page${on.length == 1 ? '' : 's'} ${on.map((PublishedPage p) => p.number).join(', ')}'
            ' — outlined, click to enlarge',
            style: label,
          ),
          const SizedBox(height: 6),
          for (final PublishedPage page in on)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                key: ValueKey<String>('answer-page-${question.questionId}-${page.number}'),
                onTap: () => showPage(context, page, highlight: _boxesOn(question, page.number)),
                child: SizedBox(
                  height: pageHeight,
                  child: PageViewer(page: _page(page), highlightBoxes: _boxesOn(question, page.number)),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// A page, large, with zoom.
Future<void> showPage(BuildContext context, PublishedPage page, {List<NormalizedBox> highlight = const <NormalizedBox>[]}) =>
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: <Widget>[
                  Text('Page ${page.number}', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            Expanded(
              child: InteractiveViewer(
                maxScale: 5,
                child: PageViewer(page: _page(page), highlightBoxes: highlight),
              ),
            ),
          ],
        ),
      ),
    );

/// The whole answer sheet, page after page, each one zoomable.
class AnswerSheetView extends StatelessWidget {
  const AnswerSheetView({super.key, required this.pages});

  final List<PublishedPage> pages;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (pages.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppTheme.pagePadding),
        child: Text(notKept, key: const Key('sheet-not-kept'), style: theme.textTheme.bodyMedium),
      );
    }
    return ListView.builder(
      key: const Key('answer-sheet'),
      padding: const EdgeInsets.all(AppTheme.pagePadding),
      itemCount: pages.length,
      itemBuilder: (BuildContext context, int index) {
        final PublishedPage page = pages[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('Page ${page.number} of ${pages.length}', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              InkWell(
                key: ValueKey<String>('sheet-page-${page.number}'),
                onTap: () => showPage(context, page),
                child: AspectRatio(
                  aspectRatio: page.width > 0 && page.height > 0 ? page.width / page.height : 0.7,
                  child: PageViewer(page: _page(page)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The first page an answer is on, small, with the answer outlined — shown
/// while a student writes a correction request, so they can point at it.
class AnswerPagePreview extends StatelessWidget {
  const AnswerPagePreview({super.key, required this.question, required this.pages, this.height = 220});

  final PublishedQuestion question;
  final List<PublishedPage> pages;
  final double height;

  @override
  Widget build(BuildContext context) {
    final int? first = question.answerPages.firstOrNull;
    final PublishedPage? page =
        first == null ? null : pages.where((PublishedPage p) => p.number == first).firstOrNull;
    if (page == null) return const SizedBox.shrink();
    return SizedBox(
      key: const Key('answer-preview'),
      height: height,
      child: PageViewer(page: _page(page), highlightBoxes: _boxesOn(question, page.number)),
    );
  }
}

