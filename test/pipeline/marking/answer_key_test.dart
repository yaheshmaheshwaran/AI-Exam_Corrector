import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/pipeline/marking/marking_prompt.dart';
import 'package:exam_corrector/pipeline/marking/marking_validator.dart';

import '../pipeline_fakes.dart';
import 'marking_test.dart' show answerWith, marked;

void main() {
  final List<AnswerKeyTask> tasks = <AnswerKeyTask>[
    AnswerKeyTask(question: question('11', text: 'Explain MQTT with a neat diagram.', marks: 13)),
    AnswerKeyTask(question: question('2', text: 'Define IoT.', marks: 2)),
  ];

  group('reading the answer key', () {
    test('matches each key to its question, however the model names it', () {
      final Map<String, AnswerKeyEntry> keys = ModelAnswerKeyEngine.parse(<String, Object?>{
        'keys': <Object?>[
          <String, Object?>{
            'question_id': '11',
            'points': <Object?>[
              <String, Object?>{'description': 'Publish–subscribe model', 'marks': 4, 'full_credit': 'Explained with the broker.'},
              <String, Object?>{'description': 'Architecture diagram', 'marks': 5, 'full_credit': 'Labelled.'},
              <String, Object?>{'description': 'QoS levels', 'marks': 4, 'full_credit': 'All three, explained.'},
            ],
            'expected_words': 320,
            'diagram_expected': true,
            'example_expected': false,
            'notes': '',
          },
          <String, Object?>{
            'question_id': 'Q 2',
            'points': <Object?>[
              <String, Object?>{'description': 'Network of connected devices', 'marks': 1, 'full_credit': ''},
            ],
            'expected_words': 30,
            'diagram_expected': false,
            'example_expected': false,
            'notes': '',
          },
          <String, Object?>{'question_id': '99', 'points': <Object?>[]},
        ],
      }, tasks);

      expect(keys.keys, <String>['Q11', 'Q2']);
      final AnswerKeyEntry long = keys['Q11']!;
      expect(long.expectedWords, 320);
      expect(long.text, contains('- Publish–subscribe model [4] — full credit: Explained with the broker.'));
      expect(long.text, contains('A full answer: about 320 words, a labelled diagram.'));
      // Worth 1 where the question is worth 2: scaled to add up.
      expect(keys['Q2']!.points.single.marks, 2);
    });

    test("the teacher's key replaces the AI's, and may state a length", () {
      final AnswerKey key = AnswerKey(
        entries: <String, AnswerKeyEntry>{
          'Q11': const AnswerKeyEntry(questionId: 'Q11', maximum: 13, expectedWords: 320, points: <AnswerKeyPoint>[
            AnswerKeyPoint(criterion: 'MQTT', marks: 13),
          ]),
        },
        edits: const <String, String>{'Q11': 'My key. A full answer is about 250 words.'},
      );
      expect(key.textFor('Q11'), 'My key. A full answer is about 250 words.');
      expect(key.expectedWordsFor('Q11'), 250);
      expect(const AnswerKey(entries: <String, AnswerKeyEntry>{}).textFor('Q11'), isEmpty);
      final Map<String, AnswerKeyEntry> back = AnswerKey.entriesFromJson(key.toJson());
      expect(back['Q11']!.text, key.entries['Q11']!.text);
    });

    test('is asked for from the questions alone, at the paper’s standard', () {
      final String request = ModelAnswerKeyEngine.buildRequest(
        tasks,
        guidance: 'Q11: the diagram is essential.',
        course: 'Internet of Things',
        standard: const MarkingStandard(level: MarkingLevel.strict),
      );
      expect(request, contains('=== QUESTION Q11'));
      expect(request, contains('Maximum marks: 13'));
      expect(request, contains('MARKING STANDARD: Strict'));
      expect(request, contains('the diagram is essential'));
      expect(ModelAnswerKeyEngine.systemPrompt, contains('You will not see any answers'));
    });
  });

  group('marking against it', () {
    test('the key goes to the marker in place of invented points, with the depth rules', () {
      final String prompt = MarkingPrompt.buildBatch(
        tasks: <MarkingTask>[
          MarkingTask(
            question: question('1'),
            answer: answerWith(),
            answerKey: '- Names the mitochondrion [2]',
          ),
        ],
        aliases: <String, String>{},
        guidance: '',
        typedAnswerSheet: false,
      );
      expect(prompt, contains('ANSWER KEY (fixed before marking'));
      expect(prompt, contains('- Names the mitochondrion [2]'));
      expect(MarkingPrompt.version, 'marking:v8');
      expect(MarkingPrompt.systemPrompt, contains('only named, listed or mentioned: at most a quarter'));
      expect(MarkingPrompt.systemPrompt, contains('Full marks are rare'));
      expect(MarkingPrompt.systemPrompt, contains('When you are torn between two marks, give the lower one'));
      expect(MarkingPrompt.systemPrompt, contains('a 2-mark question: 2 only for a precise, complete answer'));
      expect(MarkingPrompt.systemPrompt, contains('35–55%'));
      final Map<String, Object?> item = ((MarkingPrompt.schema['properties']! as Map<String, Object?>)['questions']!
          as Map<String, Object?>)['items']! as Map<String, Object?>;
      expect(item['required'], containsAll(<String>['quality_band', 'band_reason']));
    });

    test('a printed mark scheme wins over the key', () {
      final String prompt = MarkingPrompt.buildBatch(
        tasks: <MarkingTask>[
          MarkingTask(question: question('1'), answer: answerWith(), markScheme: 'Mitochondrion (2)', answerKey: 'unused'),
        ],
        aliases: <String, String>{},
        guidance: '',
        typedAnswerSheet: false,
      );
      expect(prompt, isNot(contains('ANSWER KEY')));
    });

    test("the marker's quality band and key-sourced points are read", () {
      final QuestionResult result = const MarkingValidator(reviewThreshold: 0.7).validate(
        task: MarkingTask(question: question('1'), answer: answerWith()),
        raw: <String, Object?>{
          ...marked(),
          'marking_points_source': 'key',
          'quality_band': 'weak',
          'band_reason': 'Mostly listed.',
        },
        aliasToRegion: const <String, String>{'R1': 'r1'},
        model: 'model-a',
      );
      expect(result.qualityBand, QualityBand.weak);
      expect(result.bandReason, 'Mostly listed.');
      expect(result.markingPointsSource, MarkingPointSource.answerKey);
      final QuestionResult back = QuestionResult.fromJson(result.toJson())!;
      expect(back.qualityBand, QualityBand.weak);
      expect(back.bandReason, 'Mostly listed.');
    });
  });
}
