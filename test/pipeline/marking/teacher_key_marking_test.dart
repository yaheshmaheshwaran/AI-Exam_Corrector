import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/pipeline/marking/keyed_mcq_marker.dart';
import 'package:exam_corrector/pipeline/marking/marking_prompt.dart';
import 'package:exam_corrector/pipeline/marking/marking_validator.dart';
import 'package:exam_corrector/pipeline/marking/teacher_key.dart';
import 'package:exam_corrector/pipeline/marking/teacher_key_reader.dart';

import '../pipeline_fakes.dart';
import 'marking_test.dart' show answerWith, marked;

const String _options = 'Which organelle makes ATP? (a) nucleus (b) mitochondrion (c) ribosome (d) vacuole';

StudentAnswer _wrote(String text, {double confidence = 0.95, bool crossedOut = false}) => StudentAnswer(
      questionId: 'Q1',
      pages: const <int>[1],
      regionIds: const <String>['r1'],
      textEvidence: <TextEvidenceItem>[
        TextEvidenceItem(
          regionId: 'r1',
          pageNumber: 1,
          type: RegionType.handwrittenAnswer,
          text: text,
          rawText: text,
          confidence: confidence,
          source: ReadingSource.trocr,
        ),
      ],
      crossedOut: <TextEvidenceItem>[
        if (crossedOut)
          const TextEvidenceItem(
            regionId: 'r2',
            pageNumber: 1,
            type: RegionType.crossedOut,
            text: '(c)',
            rawText: '(c)',
            confidence: 0.9,
            source: ReadingSource.trocr,
          ),
      ],
      answerConfidence: confidence,
      alignmentConfidence: 1,
    );

MarkingTask _mcq(StudentAnswer answer, {String? option = 'b'}) => MarkingTask(
      question: question('1', marks: 1, text: _options),
      answer: answer,
      answerKey: 'Correct option: (b)',
      answerKeySource: AnswerKeySource.teacher,
      keyOption: option,
    );

const TeacherKeySource _source = TeacherKeySource(fileName: 'key.docx', hash: 'k1', text: 'Answers written as prose.');

void main() {
  group('the answer key, layered', () {
    test("the teacher's correction wins, then their key, then the AI's", () {
      final AnswerKey key = AnswerKey(
        entries: const <String, AnswerKeyEntry>{
          'Q1': AnswerKeyEntry(questionId: 'Q1', maximum: 2, points: <AnswerKeyPoint>[AnswerKeyPoint(criterion: 'AI point', marks: 2)]),
          'Q2': AnswerKeyEntry(questionId: 'Q2', maximum: 2, points: <AnswerKeyPoint>[AnswerKeyPoint(criterion: 'AI point', marks: 2)]),
        },
        teacher: const <String, TeacherKeyEntry>{
          'Q1': TeacherKeyEntry(questionId: 'Q1', answer: 'Mitochondrion'),
          'Q3': TeacherKeyEntry(questionId: 'Q3', option: 'c'),
        },
        edits: const <String, String>{'Q3': 'b'},
      );
      expect(key.textFor('Q1'), 'Mitochondrion');
      expect(key.sourceFor('Q1'), AnswerKeySource.teacher);
      expect(key.textFor('Q2'), startsWith('- AI point'));
      expect(key.sourceFor('Q2'), AnswerKeySource.ai);
      // A correction that is nothing but an option still marks directly.
      expect(key.optionFor('Q3'), 'b');
      expect(key.sourceFor('Q4'), isNull);
    });
  });

  group("marking against the teacher's key", () {
    test('reaches the marker as the teacher’s own key, credit for equivalents included', () {
      final String prompt = MarkingPrompt.buildBatch(
        tasks: <MarkingTask>[
          MarkingTask(
            question: question('1'),
            answer: answerWith(),
            answerKey: 'Mitochondrion',
            answerKeySource: AnswerKeySource.teacher,
          ),
        ],
        aliases: <String, String>{},
        guidance: '',
        typedAnswerSheet: false,
      );
      expect(prompt, contains("TEACHER'S ANSWER KEY"));
      expect(prompt, isNot(contains('ANSWER KEY (fixed before marking')));
      expect(MarkingPrompt.systemPrompt, contains('report key_match "equivalent"'));
    });

    test('a credited equivalent answer is flagged, and its points are the teacher’s', () {
      final QuestionResult result = const MarkingValidator(reviewThreshold: 0.7).validate(
        task: MarkingTask(
          question: question('1'),
          answer: answerWith(),
          answerKey: 'Mitochondrion',
          answerKeySource: AnswerKeySource.teacher,
        ),
        raw: <String, Object?>{...marked(), 'marking_points_source': 'key', 'key_match': 'equivalent'},
        aliasToRegion: const <String, String>{'R1': 'r1'},
        model: 'model-a',
      );
      expect(result.keyMatch, KeyMatch.equivalent);
      expect(result.needsReview, isTrue);
      expect(result.reviewReasons, contains('Credited an answer that differs from your answer key — check it.'));
      expect(result.markingPointsSource, MarkingPointSource.teacherKey);
      expect(QuestionResult.fromJson(result.toJson())!.keyMatch, KeyMatch.equivalent);
    });

    test("without the teacher's key, key_match is ignored", () {
      final QuestionResult result = const MarkingValidator(reviewThreshold: 0.7).validate(
        task: MarkingTask(question: question('1'), answer: answerWith(), answerKey: '- AI point [2]'),
        raw: <String, Object?>{...marked(), 'marking_points_source': 'key', 'key_match': 'equivalent'},
        aliasToRegion: const <String, String>{'R1': 'r1'},
        model: 'model-a',
      );
      expect(result.keyMatch, isNull);
      expect(result.markingPointsSource, MarkingPointSource.answerKey);
    });
  });

  group('multiple choice, marked from the key', () {
    const KeyedMcqMarker marker = KeyedMcqMarker(reviewThreshold: 0.7);

    test('reads the chosen option however it is written', () {
      for (final String written in <String>['b', '(b)', 'B)', 'Ans: B', 'Option (b)', '1. (b)', '(b) mitochondrion']) {
        expect(KeyedMcqMarker.chosenOption(written), 'b', reason: written);
      }
      expect(KeyedMcqMarker.chosenOption('(b) or (c)'), isNull);
      expect(KeyedMcqMarker.chosenOption('The mitochondrion makes ATP.'), isNull);
    });

    test('a clear right answer earns the marks, a clear wrong one none — with no model', () {
      final QuestionResult right = marker.mark(_mcq(_wrote('(b)')))!;
      expect(right.awardedMarks, 1);
      expect(right.keyMatch, KeyMatch.matches);
      expect(right.markingPointsSource, MarkingPointSource.teacherKey);
      expect(right.model, KeyedMcqMarker.markedBy);
      expect(right.markingPoints.single.evidenceRegionIds, <String>['r1']);

      final QuestionResult wrong = marker.mark(_mcq(_wrote('C')))!;
      expect(wrong.awardedMarks, 0);
      expect(wrong.evaluation, 'Chose (c); your key gives (b).');
    });

    test('anything unclear goes to the AI', () {
      expect(marker.mark(_mcq(_wrote('(b) or (c)'))), isNull);
      expect(marker.mark(_mcq(_wrote('(b)', confidence: 0.4))), isNull);
      expect(marker.mark(_mcq(_wrote('(b)', crossedOut: true))), isNull);
      expect(marker.mark(_mcq(_wrote('(b)'), option: null)), isNull);
      // Not a multiple-choice question: the AI marks it.
      expect(
        marker.mark(MarkingTask(
          question: question('1', marks: 1, text: 'Name the organelle.'),
          answer: _wrote('b'),
          answerKeySource: AnswerKeySource.teacher,
          keyOption: 'b',
        )),
        isNull,
      );
    });
  });

  group('matching a key the parser cannot', () {
    final QuestionPaper paper = paperOf(<Question>[
      question('1', marks: 2, text: 'Name the organelle that makes ATP.'),
      question('2', marks: 1, text: _options),
    ]);

    test('the model copies the teacher’s content onto the questions, checked against the paper', () {
      final TeacherKey key = ModelTeacherKeyReader.parse(<String, Object?>{
        'entries': <Object?>[
          <String, Object?>{
            'question_id': 'Q1',
            'answer': 'Mitochondrion',
            'points': <Object?>[],
            'alternatives': <String>['powerhouse of the cell'],
            'correct_option': '',
            'key_marks': 3,
            'notes': '',
          },
          <String, Object?>{
            'question_id': 'Q2',
            'answer': '',
            'points': <Object?>[],
            'alternatives': <String>[],
            'correct_option': 'B',
            'key_marks': -1,
            'notes': '',
          },
          <String, Object?>{'question_id': 'Q9', 'answer': 'Not on the paper'},
        ],
        'unmatched': <String>['21'],
      }, _source, paper);

      expect(key.matched, isTrue);
      expect(key.entries['Q1']!.alternatives, <String>['powerhouse of the cell']);
      expect(key.entries['Q2']!.option, 'b');
      expect(key.unmatched, <String>['21', 'Q9']);
      expect(key.warnings.single, contains('the paper says 2'));
    });

    test('is asked only when reading the key itself did not match enough', () async {
      final FakeModelClient client = FakeModelClient((_, _) => <String, Object?>{
            'entries': <Object?>[
              <String, Object?>{
                'question_id': 'Q1',
                'answer': 'Mitochondrion',
                'points': <Object?>[],
                'alternatives': <String>[],
                'correct_option': '',
                'key_marks': -1,
                'notes': '',
              },
            ],
            'unmatched': <String>[],
          });
      final CompositeTeacherKeyReader reader = CompositeTeacherKeyReader(
        model: ModelTeacherKeyReader(client, () => const AppConfig(apiKey: 'k', model: 'model-a', effort: 'low', maxTokens: 8000)),
      );

      // Numbered as the paper numbers it: read locally, no request.
      final TeacherKey typed = await reader.read(
        const TeacherKeySource(fileName: 'key.txt', hash: 'k2', text: '1. Mitochondrion\n2. B'),
        paper,
      );
      expect(typed.entries['Q2']!.option, 'b');
      expect(client.requests, isEmpty);

      // Prose with no numbering: the model matches it.
      final TeacherKey prose = await reader.read(_source, paper);
      expect(prose.entries['Q1']!.answer, 'Mitochondrion');
      expect(client.requests, hasLength(1));
    });

    test('without a model, what matched is kept and the teacher told', () async {
      final TeacherKey key = await const CompositeTeacherKeyReader().read(_source, paper);
      expect(key.entries, isEmpty);
      expect(key.warnings.single, contains('No numbered answers were found'));
    });
  });
}
