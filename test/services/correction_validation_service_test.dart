import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/services/correction_validation_service.dart';

Map<String, dynamic> _question({
  String number = '1',
  num maximum = 5,
  num awarded = 4,
  List<Map<String, dynamic>>? points,
}) {
  return <String, dynamic>{
    'question_number': number,
    'maximum_marks': maximum,
    'awarded_marks': awarded,
    'student_answer': 'The student wrote something.',
    'evaluation': 'Three of the four points were made.',
    'marking_points': points ??
        <Map<String, dynamic>>[
          <String, dynamic>{
            'criterion': 'States the definition',
            'satisfied': true,
            'marks': 1,
          },
        ],
  };
}

void main() {
  const CorrectionValidationService validator = CorrectionValidationService();

  group('structure', () {
    test('rejects a non-object payload', () {
      expect(
        () => validator.validate(<Object>['not', 'an', 'object']),
        throwsA(isA<ResultValidationException>()),
      );
    });

    test('rejects a payload with no questions list', () {
      expect(
        () => validator.validate(<String, dynamic>{'total_marks': 10}),
        throwsA(isA<ResultValidationException>()),
      );
    });

    test('rejects an empty questions list', () {
      expect(
        () => validator.validate(<String, dynamic>{
          'questions': <Object>[],
          'total_marks': 0,
          'maximum_total_marks': 0,
          'percentage': 0,
        }),
        throwsA(isA<ResultValidationException>()),
      );
    });

    test('rejects a missing question number', () {
      final Map<String, dynamic> question = _question()
        ..['question_number'] = '  ';
      expect(
        () => validator.validate(<String, dynamic>{
          'questions': <Object>[question],
        }),
        throwsA(isA<ResultValidationException>()),
      );
    });

    test('rejects non-numeric marks', () {
      final Map<String, dynamic> question = _question()
        ..['awarded_marks'] = 'four';
      expect(
        () => validator.validate(<String, dynamic>{
          'questions': <Object>[question],
        }),
        throwsA(isA<ResultValidationException>()),
      );
    });

    test('rejects a non-boolean satisfied flag', () {
      final Map<String, dynamic> question = _question(
        points: <Map<String, dynamic>>[
          <String, dynamic>{
            'criterion': 'States the definition',
            'satisfied': 'yes',
            'marks': 1,
          },
        ],
      );
      expect(
        () => validator.validate(<String, dynamic>{
          'questions': <Object>[question],
        }),
        throwsA(isA<ResultValidationException>()),
      );
    });
  });

  group('marks', () {
    test('caps awarded marks at the question maximum and warns', () {
      final CorrectionResult result = validator.validate(<String, dynamic>{
        'questions': <Object>[_question(maximum: 5, awarded: 9)],
        'total_marks': 9,
        'maximum_total_marks': 5,
        'percentage': 180,
      });

      expect(result.questions.single.awardedMarks, 5);
      expect(result.totalMarks, 5);
      expect(result.percentage, 100);
      expect(
        result.warnings.any((String w) => w.contains('capped')),
        isTrue,
      );
    });

    test('raises negative awarded marks to zero and warns', () {
      final CorrectionResult result = validator.validate(<String, dynamic>{
        'questions': <Object>[_question(maximum: 5, awarded: -3)],
      });

      expect(result.questions.single.awardedMarks, 0);
      expect(
        result.warnings.any((String w) => w.contains('negative')),
        isTrue,
      );
    });

    test('zeroes marks on unsatisfied marking points', () {
      final CorrectionResult result = validator.validate(<String, dynamic>{
        'questions': <Object>[
          _question(
            points: <Map<String, dynamic>>[
              <String, dynamic>{
                'criterion': 'Mentions the exception',
                'satisfied': false,
                'marks': 2,
              },
            ],
          ),
        ],
      });

      expect(result.questions.single.markingPoints.single.marks, 0);
    });

    test('recomputes totals and percentage from the questions', () {
      final CorrectionResult result = validator.validate(<String, dynamic>{
        'questions': <Object>[
          _question(number: '1', maximum: 5, awarded: 4),
          _question(number: '2', maximum: 5, awarded: 3),
        ],
        // Deliberately wrong arithmetic from the model.
        'total_marks': 99,
        'maximum_total_marks': 99,
        'percentage': 99,
      });

      expect(result.totalMarks, 7);
      expect(result.maximumTotalMarks, 10);
      expect(result.percentage, 70);
      expect(result.warnings.length, 2);
    });

    test('accepts a clean response without warnings', () {
      final CorrectionResult result = validator.validate(<String, dynamic>{
        'questions': <Object>[_question(maximum: 5, awarded: 4)],
        'total_marks': 4,
        'maximum_total_marks': 5,
        'percentage': 80,
      });

      expect(result.warnings, isEmpty);
      expect(result.hasQuestions, isTrue);
      expect(result.percentage, 80);
    });

    test('substitutes placeholder text for a missing answer', () {
      final Map<String, dynamic> question = _question()
        ..['student_answer'] = '  '
        ..['evaluation'] = '';

      final CorrectionResult result = validator.validate(<String, dynamic>{
        'questions': <Object>[question],
      });

      expect(result.questions.single.studentAnswer, 'No answer found');
      expect(result.questions.single.evaluation, 'No evaluation provided.');
    });
  });
}
