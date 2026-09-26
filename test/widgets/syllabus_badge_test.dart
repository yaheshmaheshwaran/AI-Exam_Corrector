import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/services/export/report_exporter.dart';
import 'package:exam_corrector/widgets/marking_standard_dialog.dart';
import 'package:exam_corrector/widgets/results_view.dart';
import 'package:exam_corrector/widgets/syllabus_badge.dart';

import '../models/section_totals_test.dart' show marked, paper;
import '../pipeline/pipeline_fakes.dart';

const SyllabusAward matchAward = SyllabusAward(
  badge: SyllabusBadge.exact,
  coverage: 0.9,
  bonus: 1,
  matched: <String>['broker', 'mqtt'],
  missing: <String>['qos'],
);

final CorrectionResult result = CorrectionResult.fromQuestions(<QuestionResult>[
  marked('1', 2, 2, 'A').copyWith(syllabusAward: () => matchAward, adjustments: <String>['+1 syllabus bonus']),
  marked('2', 1, 2, 'A'),
  marked('3', 7, 10, 'B'),
  marked('4', 9, 10, 'B', counted: false),
]);

ExamAssessment assessment() => ExamAssessment(
      job: const ProcessingJob(jobId: 'job', stage: ProcessingStage.completed),
      answerSheet: document(<ExamPage>[page(1)]),
      questionPaper: paper,
      evidence: const EvidenceSet(handwriting: <String, HandwritingEvidence>{}),
      alignment: const AlignmentResult(segments: <AnswerSegment>[], alignments: <String, QuestionAlignment>{}),
      answers: const <String, StudentAnswer>{},
      result: result,
    );

void main() {
  testWidgets('the badge shows its level and the bonus given; no badge shows nothing', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            SyllabusBadgeChip(badge: SyllabusBadge.exact, bonus: 1),
            SyllabusBadgeChip(badge: SyllabusBadge.almost),
            SyllabusBadgeChip(badge: SyllabusBadge.none, bonus: 1),
          ],
        ),
      ),
    ));
    expect(find.text('Syllabus match +1'), findsOneWidget);
    expect(find.text('Close to syllabus'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('syllabus-badge-none')), findsNothing);
  });

  testWidgets('a question row carries its badge', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ResultsView(assessment: assessment(), reviews: const TeacherReviewBook(), onOpenQuestion: (_) {}),
      ),
    ));
    final Finder row = find.byKey(const ValueKey<String>('question-row-Q1'));
    expect(find.descendant(of: row, matching: find.text('Syllabus match +1')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey<String>('question-row-Q2')), matching: find.byType(SyllabusBadgeChip)),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('syllabus-badge-exact')), findsOneWidget);

    // The bonus, and the marks it went into, are gold; other marks are not.
    MarksBadge marks(String id) => tester.widget<MarksBadge>(
        find.descendant(of: find.byKey(ValueKey<String>('question-row-$id')), matching: find.byType(MarksBadge)));
    expect(marks('Q1').gold, isTrue);
    expect(marks('Q2').gold, isFalse);
    final Text label = tester.widget<Text>(find.text('Syllabus match +1'));
    expect(label.style?.color, AppTheme.gold);
  });

  test('the badge is published with the result, and exported', () {
    final PublishedResult published = PublishedResult.of(
      assessment(),
      const TeacherReviewBook(),
      student: 'Priya',
      rollNo: '21CS045',
      subjectCode: 'CCS356',
    );
    expect(published.questions.first.badge, SyllabusBadge.exact);
    expect(published.questions.first.bonus, 1);
    expect(published.questions[1].badge, SyllabusBadge.none);

    const ReportExporter exporter = ReportExporter();
    final String csv = exporter.export(assessment(), const TeacherReviewBook(), ReportFormat.csv);
    expect(csv.split('\n').first, contains('Syllabus badge'));
    expect(csv, contains('Syllabus match (90%) +1'));
    expect(
      exporter.export(assessment(), const TeacherReviewBook(), ReportFormat.html),
      contains('<span class="tag gold">★ Syllabus match +1</span>'),
    );
  });

  testWidgets('the rules dialog turns the bonus on and keeps a match above close', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ({MarkingStandard standard, bool asDefault})? chosen;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () async => chosen = await MarkingStandardDialog.show(context, const MarkingStandard()),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dialog-almost-threshold')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('dialog-syllabus-bonus')));
    await tester.tap(find.byKey(const Key('dialog-syllabus-bonus')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dialog-almost-threshold')), findsOneWidget);
    expect(find.textContaining('never takes a question above its maximum'), findsOneWidget);

    // Close pushed all the way up: a match must still need more.
    await tester.ensureVisible(find.byKey(const Key('dialog-almost-threshold')));
    await tester.drag(find.byKey(const Key('dialog-almost-threshold')), const Offset(600, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('dialog-apply')));
    await tester.pumpAndSettle();
    final SyllabusBonus bonus = chosen!.standard.syllabusBonus;
    expect(bonus.enabled, isTrue);
    expect(bonus.almostThreshold, closeTo(0.95, 1e-9));
    expect(bonus.exactThreshold, closeTo(1, 1e-9));
    expect(chosen!.standard.changesJudgement, isFalse);
  });
}
