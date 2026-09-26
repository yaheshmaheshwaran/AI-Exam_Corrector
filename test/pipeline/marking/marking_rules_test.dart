import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/marking_prompt.dart';
import 'package:exam_corrector/pipeline/marking/marking_rules.dart';
import 'package:exam_corrector/services/review/marking_standard_store.dart';

import '../pipeline_fakes.dart';
import 'marking_test.dart' show answerWith;

QuestionResult result(
  double awarded, {
  double maximum = 5,
  double confidence = 0.9,
  List<MarkingPoint> points = const <MarkingPoint>[],
  List<String> reasons = const <String>[],
  bool review = false,
}) =>
    QuestionResult(
      questionNumber: '1',
      questionId: 'Q1',
      maximumMarks: maximum,
      awardedMarks: awarded,
      studentAnswer: 'answer',
      evaluation: 'ok',
      confidence: confidence,
      markingPoints: points,
      reviewReasons: reasons,
      needsReview: review,
    );

MarkingTask task({String text = 'Explain something.', String? section, bool answered = true}) => MarkingTask(
      question: question('1', text: text, section: section),
      answer: answered ? answerWith() : const StudentAnswer.none('Q1'),
    );

/// The realism checks are tested on their own; here they would cap every
/// one-line answer to a 5-mark question.
const RealismRules noRealism =
    RealismRules(bandCap: false, lengthCap: false, fullMarksGate: false, strictness: RealismStrictness.standard);

QuestionResult apply(MarkingStandard standard, QuestionResult r, {MarkingTask? on}) =>
    MarkingRules(standard.copyWith(realism: noRealism), defaultReviewThreshold: 0.7).apply(r, on ?? task());

void main() {
  group('the usual standard', () {
    test('changes nothing for whole and half marks', () {
      for (final double marks in <double>[0, 1, 1.5, 2, 5]) {
        final QuestionResult out = apply(const MarkingStandard(), result(marks));
        expect(out.awardedMarks, marks);
        expect(out.adjustments, isEmpty);
        expect(out.aiRawMarks, isNull);
      }
    });

    test('gives the AI no extra instructions, so marks already made stay valid', () {
      expect(const MarkingStandard().changesJudgement, isFalse);
      expect(const MarkingStandard(markStep: 1, mcqPenalty: 0.25, totalRounding: TotalRounding.up)
          .changesJudgement, isFalse);
      expect(const MarkingStandard(level: MarkingLevel.strict).changesJudgement, isTrue);
      expect(const MarkingStandard(collegeRules: 'Diagrams are compulsory.').changesJudgement, isTrue);
    });
  });

  test('each level rounds its own way, and says so', () {
    expect(apply(const MarkingStandard(level: MarkingLevel.lenient), result(3.3)).awardedMarks, 3.5);
    expect(apply(const MarkingStandard(), result(3.3)).awardedMarks, 3.5);
    final QuestionResult strict = apply(const MarkingStandard(level: MarkingLevel.strict), result(3.3));
    expect(strict.awardedMarks, 3);
    expect(strict.aiRawMarks, 3.3);
    expect(strict.adjustments.single, 'Rounded down from 3.3 to 3 — half marks (Strict).');

    // Whole marks, never above the maximum.
    expect(apply(const MarkingStandard(level: MarkingLevel.lenient, markStep: 1), result(4.2, maximum: 4.5))
        .awardedMarks, 4.5);
  });

  test('strict gives nothing for uncertain readings or part-met points, and flags them', () {
    const List<MarkingPoint> points = <MarkingPoint>[
      MarkingPoint(criterion: 'Names the organelle', satisfied: true, marks: 1, marksAvailable: 1),
      MarkingPoint(
        criterion: 'States ATP',
        satisfied: true,
        marks: 1,
        marksAvailable: 1,
        basis: EvidenceBasis.uncertain,
      ),
      MarkingPoint(criterion: 'Explains why', satisfied: true, marks: 1, marksAvailable: 2),
    ];
    final QuestionResult out = apply(const MarkingStandard(level: MarkingLevel.strict), result(3, points: points));

    expect(out.awardedMarks, 1);
    expect(out.markingPoints.map((MarkingPoint p) => p.marks), <double>[1, 0, 0]);
    expect(out.needsReview, isTrue);
    expect(out.adjustments, hasLength(2));
    expect(out.adjustments.first, contains('uncertain reading'));

    // The usual standard leaves the same marks alone.
    expect(apply(const MarkingStandard(), result(3, points: points)).awardedMarks, 3);
  });

  group('multiple-choice penalty', () {
    const String mcq = 'An embedded system is designed to perform ____\na) General tasks b) A specific task c) Gaming d) None';
    const MarkingStandard penalty = MarkingStandard(mcqPenalty: 0.25);

    test('only for a wrong answer, never an unanswered one', () {
      final QuestionResult wrong = apply(penalty, result(0, maximum: 1), on: task(text: mcq));
      expect(wrong.awardedMarks, -0.25);
      expect(wrong.adjustments.single, contains('wrong multiple-choice'));

      expect(apply(penalty, result(0, maximum: 1), on: task(text: mcq, answered: false)).awardedMarks, 0);
      expect(apply(penalty, result(1, maximum: 1), on: task(text: mcq)).awardedMarks, 1);
      // Not a multiple-choice question.
      expect(apply(penalty, result(0, maximum: 1)).awardedMarks, 0);
    });

    test('a section the teacher marks as multiple choice counts too', () {
      const MarkingStandard sectioned = MarkingStandard(mcqPenalty: 0.5, mcqSections: <String>['A']);
      expect(apply(sectioned, result(0, maximum: 1), on: task(section: 'A')).awardedMarks, -0.5);
    });
  });

  test('each level flags for review at its own confidence', () {
    const String low = 'Confidence 65% is below the review threshold of 70%.';
    final QuestionResult lenient =
        apply(const MarkingStandard(level: MarkingLevel.lenient), result(2, confidence: 0.65, reasons: <String>[low], review: true));
    expect(lenient.needsReview, isFalse);
    expect(lenient.reviewReasons, isEmpty);

    final QuestionResult strict = apply(const MarkingStandard(level: MarkingLevel.strict), result(2, confidence: 0.75));
    expect(strict.needsReview, isTrue);
    expect(strict.reviewReasons.single, contains('Strict review threshold of 80%'));
  });

  test("the total is rounded as the college rounds it, the teacher's marks included", () {
    final CorrectionResult marked = CorrectionResult.fromQuestions(
      <QuestionResult>[
        result(3.5),
        const QuestionResult(questionNumber: '2', questionId: 'Q2', maximumMarks: 5, awardedMarks: 2, studentAnswer: '', evaluation: ''),
      ],
      totalRounding: TotalRounding.up,
      standard: 'Balanced · half marks · total rounded up',
    );
    expect(marked.totalMarks, 6);
    final TeacherReviewBook reviews = const TeacherReviewBook().withReview(TeacherReview(
      questionId: 'Q1',
      status: ReviewStatus.overridden,
      aiMarks: 3.5,
      teacherMarks: 4.5,
      timestamp: DateTime(2026),
    ));
    // 4.5 + 2 = 6.5, rounded up.
    expect(reviews.finalTotal(marked), 7);
    expect(CorrectionResult.fromJson(marked.toJson()).totalRounding, TotalRounding.up);
    expect(TotalRounding.down.apply(6.5), 6);
    expect(TotalRounding.nearest.apply(6.5), 7);
  });

  test('the AI is told the level and the college rules only when they differ', () {
    String prompt(MarkingStandard standard) => MarkingPrompt.buildBatch(
          tasks: <MarkingTask>[
            MarkingTask(question: question('1'), answer: answerWith(), standard: standard),
          ],
          aliases: <String, String>{},
          guidance: '',
          typedAnswerSheet: false,
        );

    expect(prompt(const MarkingStandard()), isNot(contains('MARKING STANDARD')));
    final String strict = prompt(const MarkingStandard(
      level: MarkingLevel.strict,
      collegeRules: 'Section C answers without a diagram get at most 70%.',
    ));
    expect(strict, contains('MARKING STANDARD: Strict'));
    expect(strict, contains('- Units: A missing or wrong unit loses the answer mark.'));
    expect(strict, isNot(contains('- Rounding:')));
    expect(strict, contains('COLLEGE RULES (binding'));
    expect(strict, contains('at most 70%'));
  });

  test("a paper's standard, and the teacher's default, are kept", () async {
    final Directory dir = await Directory.systemTemp.createTemp('standards');
    addTearDown(() => dir.delete(recursive: true));
    final MarkingStandardStore store = MarkingStandardStore(File('${dir.path}/marking-standards.json'));

    expect((await store.forPaper('p1')).level, MarkingLevel.balanced);
    await store.save('p1', const MarkingStandard(level: MarkingLevel.strict, mcqPenalty: 0.25));
    expect((await store.forPaper('p1')).mcqPenalty, 0.25);
    expect((await store.forPaper('p2')).level, MarkingLevel.balanced);

    await store.save('p2', const MarkingStandard(level: MarkingLevel.lenient), asDefault: true);
    expect((await store.forPaper('p3')).level, MarkingLevel.lenient);
    expect((await store.forPaper('p1')).level, MarkingLevel.strict);
  });
}
