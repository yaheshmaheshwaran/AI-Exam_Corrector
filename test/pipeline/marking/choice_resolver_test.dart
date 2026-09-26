import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/marking/choice_resolver.dart';

import '../pipeline_fakes.dart';

/// Question 1 [2], then 11: (a)(i)[6] (ii)[6] OR (b)(i)[4] (ii)[8].
QuestionPaper orPaper() => QuestionPaper(
      documentId: 'paper',
      questions: <Question>[
        question('1', marks: 2),
        question('11', marks: null, parts: <Question>[
          question('11(a)', marks: null, parts: <Question>[
            question('11(a)(i)', marks: 6),
            question('11(a)(ii)', marks: 6),
          ]),
          question('11(b)', marks: null, parts: <Question>[
            question('11(b)(i)', marks: 4),
            question('11(b)(ii)', marks: 8),
          ]),
        ]),
      ],
      choices: const <QuestionChoice>[
        QuestionChoice(options: <List<String>>[<String>['Q11a'], <String>['Q11b']]),
      ],
    );

QuestionResult result(String id, double awarded, double maximum) => QuestionResult(
      questionNumber: id.substring(1),
      questionId: id,
      maximumMarks: maximum,
      awardedMarks: awarded,
      studentAnswer: awarded > 0 ? 'answer' : 'No answer found',
      evaluation: '',
    );

List<QuestionResult> marks(Map<String, double> awarded) => <QuestionResult>[
      result('Q1', awarded['Q1'] ?? 0, 2),
      result('Q11ai', awarded['Q11ai'] ?? 0, 6),
      result('Q11aii', awarded['Q11aii'] ?? 0, 6),
      result('Q11bi', awarded['Q11bi'] ?? 0, 4),
      result('Q11bii', awarded['Q11bii'] ?? 0, 8),
    ];

Set<String> counted(List<QuestionResult> results) => <String>{
      for (final QuestionResult r in results)
        if (r.counted) r.questionId,
    };

void main() {
  const ChoiceResolver resolver = ChoiceResolver();
  final QuestionPaper paper = orPaper();

  test('the paper is worth one option of the OR, not both', () {
    expect(paper.byId('Q11')!.subQuestions, hasLength(2));
    expect(paper.totalMarks, 14);
    expect(paper.describeChoice(paper.choices.single), '11(a) or 11(b)');
    expect(paper.choicesOf('Q11bii').single.option, 1);
  });

  test('only the option answered counts', () {
    final List<QuestionResult> resolved = resolver.resolve(
      paper,
      marks(<String, double>{'Q1': 2, 'Q11bi': 3, 'Q11bii': 7}),
      <String, int>{'Q1': 0, 'Q11bi': 5, 'Q11bii': 6},
    );
    expect(counted(resolved), <String>{'Q1', 'Q11bi', 'Q11bii'});
    expect(resolved[1].choiceNote, contains('11(b) was answered instead'));

    final CorrectionResult total = CorrectionResult.fromQuestions(resolved);
    expect(total.totalMarks, 12);
    expect(total.maximumTotalMarks, 14);
  });

  test('when both are answered the first counts, even if the other scores more', () {
    final List<QuestionResult> resolved = resolver.resolve(
      paper,
      marks(<String, double>{'Q11ai': 1, 'Q11aii': 1, 'Q11bi': 4, 'Q11bii': 8}),
      <String, int>{'Q11ai': 3, 'Q11aii': 4, 'Q11bi': 7, 'Q11bii': 8},
    );
    expect(counted(resolved), <String>{'Q1', 'Q11ai', 'Q11aii'});
    expect(resolved[3].choiceNote, contains('11(a) was answered first'));
    expect(resolved[1].choiceNote, startsWith('Counted.'));
    expect(CorrectionResult.fromQuestions(resolved).totalMarks, 2);
  });

  test('with neither answered the maximum is still one option', () {
    final List<QuestionResult> resolved =
        resolver.resolve(paper, marks(const <String, double>{}), const <String, int>{});
    expect(counted(resolved), <String>{'Q1', 'Q11ai', 'Q11aii'});
    expect(CorrectionResult.fromQuestions(resolved).maximumTotalMarks, 14);
    expect(resolved[3].choiceNote, contains('none was answered'));
  });

  test('options answered together under one label: the better one counts', () {
    final List<QuestionResult> resolved = resolver.resolve(
      paper,
      marks(<String, double>{'Q11ai': 1, 'Q11bi': 3, 'Q11bii': 6}),
      <String, int>{'Q11ai': 4, 'Q11aii': 4, 'Q11bi': 4, 'Q11bii': 4},
    );
    expect(counted(resolved), <String>{'Q1', 'Q11bi', 'Q11bii'});
    expect(resolved[1].choiceNote, contains('answered together under one label'));
  });

  test('answer any two of four', () {
    final QuestionPaper any = QuestionPaper(
      documentId: 'paper',
      questions: <Question>[
        for (final String n in <String>['1', '2', '3', '4']) question(n, marks: 10),
      ],
      choices: const <QuestionChoice>[
        QuestionChoice(
          options: <List<String>>[<String>['Q1'], <String>['Q2'], <String>['Q3'], <String>['Q4']],
          choose: 2,
        ),
      ],
    );
    expect(any.totalMarks, 20);
    final List<QuestionResult> resolved = resolver.resolve(
      any,
      <QuestionResult>[
        result('Q1', 0, 10),
        result('Q2', 5, 10),
        result('Q3', 9, 10),
        result('Q4', 8, 10),
      ],
      <String, int>{'Q4': 1, 'Q2': 2, 'Q3': 3},
    );
    expect(counted(resolved), <String>{'Q2', 'Q4'});
    final CorrectionResult total = CorrectionResult.fromQuestions(resolved);
    expect(total.totalMarks, 13);
    expect(total.maximumTotalMarks, 20);
  });

  test('a teacher override on an option that is not counted changes no total', () {
    final List<QuestionResult> resolved = resolver.resolve(
      paper,
      marks(<String, double>{'Q11ai': 5}),
      <String, int>{'Q11ai': 1, 'Q11bi': 2},
    );
    final CorrectionResult total = CorrectionResult.fromQuestions(resolved);
    final TeacherReviewBook reviews = const TeacherReviewBook().withReview(
      TeacherReview(
        questionId: 'Q11bi',
        status: ReviewStatus.overridden,
        aiMarks: 0,
        teacherMarks: 4,
        timestamp: DateTime(2026),
      ),
    );
    expect(reviews.finalTotal(total), 5);
    expect(total.needsReviewCount, 0);
  });

  test('which options count survives the cache', () {
    final QuestionResult uncounted = result('Q11bi', 0, 4).copyWith(counted: false, choiceNote: 'Not counted.');
    final QuestionResult back = QuestionResult.fromJson(uncounted.toJson())!;
    expect(back.counted, isFalse);
    expect(back.choiceNote, 'Not counted.');

    final QuestionPaper restored = QuestionPaper.fromJson(paper.toJson())!;
    expect(restored.choices.single.options, <List<String>>[<String>['Q11a'], <String>['Q11b']]);
    expect(restored.totalMarks, 14);
  });
}
