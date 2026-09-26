import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/models/section_totals.dart';
import 'package:exam_corrector/services/export/report_exporter.dart';
import 'package:exam_corrector/state/marked_script.dart';
import 'package:exam_corrector/widgets/class_results_view.dart';
import 'package:exam_corrector/widgets/results_view.dart';

import '../pipeline/pipeline_fakes.dart';

/// Section A: 1 [2], 2 [2]. Section B: 3 [10] OR 4 [10].
final QuestionPaper paper = QuestionPaper(
  documentId: 'paper',
  sections: const <QuestionSection>[
    QuestionSection(sectionId: 'A', title: 'Section-A', instructions: 'Answer all questions', statedMarks: 4),
    QuestionSection(sectionId: 'B', title: 'Long answers', statedMarks: 10),
  ],
  questions: <Question>[
    question('1', section: 'A'),
    question('2', section: 'A'),
    question('3', marks: 10, section: 'B'),
    question('4', marks: 10, section: 'B'),
  ],
  choices: const <QuestionChoice>[
    QuestionChoice(options: <List<String>>[<String>['Q3'], <String>['Q4']]),
  ],
);

QuestionResult marked(String n, double awarded, double maximum, String section,
        {bool counted = true, bool review = false}) =>
    QuestionResult(
      questionNumber: n,
      questionId: 'Q$n',
      section: section,
      maximumMarks: maximum,
      awardedMarks: awarded,
      studentAnswer: 'answer',
      evaluation: 'ok',
      needsReview: review,
      counted: counted,
    );

final CorrectionResult result = CorrectionResult.fromQuestions(<QuestionResult>[
  marked('1', 2, 2, 'A'),
  marked('2', 1, 2, 'A', review: true),
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
  group('section totals', () {
    test('add up each section, leaving out the OR alternative that does not count', () {
      final List<SectionTotal> sections =
          SectionTotal.of(result, const TeacherReviewBook(), paper);

      expect(sections.map((SectionTotal s) => s.sectionId), <String>['A', 'B']);
      expect(sections.first.awarded, 3);
      expect(sections.first.maximum, 4);
      expect(sections.first.toReview, 1);
      expect(sections.last.awarded, 7);
      expect(sections.last.maximum, 10);
      expect(sections.last.questionIds, <String>['Q3', 'Q4']);
      // They add up to the paper's total.
      expect(sections.fold<double>(0, (double a, SectionTotal s) => a + s.awarded), result.totalMarks);
    });

    test("use the teacher's mark where it replaced the AI's", () {
      final TeacherReviewBook reviews = const TeacherReviewBook().withReview(
        TeacherReview(
          questionId: 'Q2',
          status: ReviewStatus.overridden,
          aiMarks: 1,
          teacherMarks: 2,
          timestamp: DateTime(2026),
        ),
      );
      final SectionTotal a = SectionTotal.of(result, reviews, paper).first;
      expect(a.awarded, 4);
      expect(a.aiAwarded, 3);
      expect(a.toReview, 0);
    });

    test('name sections without repeating themselves', () {
      expect(SectionTotal.titleFor('A', paper.section('A')), 'Section A');
      expect(SectionTotal.titleFor('B', paper.section('B')), 'Section B · Long answers');
      expect(SectionTotal.titleFor('C', const QuestionSection(sectionId: 'C', title: 'PART - C')), 'Part C');
      expect(SectionTotal.titleFor(null, null), 'Other questions');
    });

    test('a paper without sections has none to show', () {
      final QuestionPaper plain = paperOf(<Question>[question('1'), question('2')]);
      final CorrectionResult plainResult = CorrectionResult.fromQuestions(<QuestionResult>[
        const QuestionResult(questionNumber: '1', questionId: 'Q1', maximumMarks: 2, awardedMarks: 1, studentAnswer: '', evaluation: ''),
      ]);
      expect(SectionTotal.of(plainResult, const TeacherReviewBook(), plain), isEmpty);
      expect(SectionTotal.ofPaper(plain), isEmpty);
    });

    test('before marking, a section is worth one OR alternative', () {
      final List<SectionTotal> sections = SectionTotal.ofPaper(paper);
      expect(sections.map((SectionTotal s) => s.maximum), <double>[4, 10]);
    });
  });

  group('exports', () {
    const ReportExporter exporter = ReportExporter();

    test('the CSV has a subtotal after each section', () {
      final List<String> lines =
          exporter.export(assessment(), const TeacherReviewBook(), ReportFormat.csv).trim().split('\n');
      expect(lines[3], startsWith('answers.pdf,SUBTOTAL,A,4,3,,3'));
      expect(lines[6], startsWith('answers.pdf,SUBTOTAL,B,10,7,,7'));
      expect(lines.last, contains('TOTAL'));
    });

    test('the JSON lists the sections', () {
      final Map<String, Object?> json = jsonDecode(
        exporter.export(assessment(), const TeacherReviewBook(), ReportFormat.json),
      ) as Map<String, Object?>;
      final List<Object?> sections = json['sections']! as List<Object?>;
      expect(sections, hasLength(2));
      expect((sections.first! as Map<String, Object?>)['awarded'], 3);
    });

    test('the HTML heads each section with its total', () {
      final String html = exporter.export(assessment(), const TeacherReviewBook(), ReportFormat.html);
      expect(html, contains('<tr class="section"><td colspan="4">Section A</td><td class="n">3 / 4</td></tr>'));
      expect(html, contains('Section B · Long answers: 7 / 10'));
    });

    test('the class CSV has a column per section', () {
      final List<String> lines = exporter.exportClass(<ClassReportRow>[
        ClassReportRow(fileName: 'amy.pdf', result: result, reviews: const TeacherReviewBook(), paper: paper),
        const ClassReportRow(fileName: 'ben.pdf', result: null, reviews: TeacherReviewBook()),
      ]).trim().split('\n');
      expect(lines.first, contains('Section A (/4),Section B (/10),Total'));
      expect(lines[1], contains(',3,7,10,'));
    });
  });

  group('the correction result', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ResultsView(
            assessment: assessment(),
            reviews: const TeacherReviewBook(),
            onOpenQuestion: (_) {},
          ),
        ),
      ));
    }

    testWidgets('groups questions under their sections, each with its total', (WidgetTester tester) async {
      await pump(tester);

      expect(find.text('Section A  ·  2 questions'), findsOneWidget);
      expect(find.text('Section B · Long answers  ·  2 questions'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('section-total-A')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey<String>('section-total-A'))).data,
        '3 / 4',
      );
      expect(tester.widget<Text>(find.byKey(const ValueKey<String>('section-total-B'))).data, '7 / 10');
      expect(find.text('1 to review'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('section-breakdown'))).data, 'A 3/4   ·   B 7/10');
    });

    testWidgets('a section folds away and back', (WidgetTester tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey<String>('question-row-Q1')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('section-A')));
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('question-row-Q1')), findsNothing);
      expect(find.byKey(const ValueKey<String>('question-row-Q3')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('section-A')));
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('question-row-Q1')), findsOneWidget);
    });
  });

  group('the class table', () {
    Future<void> pump(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final MarkedScript script = MarkedScript(const SelectedDocument(
        role: DocumentRole.answerSheet,
        filePath: '/amy.pdf',
        fileName: 'amy.pdf',
        contentHash: 'amy',
        byteCount: 1,
        pageCount: 1,
        source: DocumentSource.scanned,
      ))
        ..assessment = assessment();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ClassResultsView(scripts: <MarkedScript>[script], onOpen: (_) {}),
        ),
      ));
    }

    testWidgets('has a column for each section when there is room', (WidgetTester tester) async {
      await pump(tester, 1000);
      expect(find.text('Section A'), findsOneWidget);
      expect(find.text('Section B'), findsOneWidget);
      expect(find.text('3/4'), findsOneWidget);
      expect(find.text('7/10'), findsOneWidget);
    });

    testWidgets('fits the sections under the name when there is not', (WidgetTester tester) async {
      await pump(tester, 560);
      expect(find.text('Section A'), findsNothing);
      expect(find.text('A 3  ·  B 7'), findsOneWidget);
    });
  });
}
