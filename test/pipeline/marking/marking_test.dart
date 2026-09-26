import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/marking_prompt.dart';
import 'package:exam_corrector/pipeline/marking/marking_validator.dart';
import 'package:exam_corrector/pipeline/marking/model_marking_engine.dart';
import 'package:exam_corrector/pipeline/reconstruction/evidence_answer_reconstructor.dart';
import 'package:exam_corrector/services/ai/model_client.dart';

import '../pipeline_fakes.dart';

StudentAnswer answerWith({
  List<String> regions = const <String>['r1'],
  double confidence = 0.95,
  double alignment = 1,
  List<String> flags = const <String>[],
}) =>
    StudentAnswer(
      questionId: 'Q1',
      pages: const <int>[1],
      regionIds: regions,
      textEvidence: <TextEvidenceItem>[
        for (final String id in regions)
          TextEvidenceItem(
            regionId: id,
            pageNumber: 1,
            type: RegionType.handwrittenAnswer,
            text: 'The mitochondrion makes ATP.',
            rawText: 'The mitochondrion makes ATP.',
            confidence: confidence,
            source: ReadingSource.trocr,
          ),
      ],
      answerConfidence: confidence,
      alignmentConfidence: alignment,
      flags: flags,
    );

Map<String, Object?> markingPoint(
  String description,
  num available,
  num awarded, {
  List<String> evidence = const <String>['R1'],
  String basis = 'observed',
}) =>
    <String, Object?>{
      'id': 'MP',
      'description': description,
      'source': 'inferred',
      'marks_available': available,
      'marks_awarded': awarded,
      'evidence': evidence,
      'basis': basis,
      'note': '',
    };

Map<String, Object?> marked({
  String id = 'Q1',
  num maximum = 2,
  List<Map<String, Object?>>? points,
  num awarded = 2,
  num confidence = 0.9,
  bool review = false,
}) =>
    <String, Object?>{
      'question_id': id,
      'maximum_marks': maximum,
      'marking_points_source': 'inferred',
      'marking_points': points ??
          <Map<String, Object?>>[
            markingPoint('Names the mitochondrion', 1, 1),
            markingPoint('States ATP', 1, 1),
          ],
      'awarded_marks': awarded,
      'student_answer': 'The mitochondrion makes ATP.',
      'explanation': 'Both points made.',
      'confidence': confidence,
      'needs_review': review,
      'review_reasons': <String>[],
      'interpreted_readings': <Object?>[],
    };

void main() {
  const MarkingValidator validator = MarkingValidator(reviewThreshold: 0.7);
  final Map<String, String> aliases = <String, String>{'R1': 'r1', 'R2': 'r2'};

  MarkingTask task({StudentAnswer? answer, double? marks = 2}) => MarkingTask(
        question: question('1', marks: marks),
        answer: answer ?? answerWith(),
      );

  QuestionResult validate(Map<String, Object?> raw, {MarkingTask? on}) =>
      validator.validate(task: on ?? task(), raw: raw, aliasToRegion: aliases, model: 'model-a');

  group('the marking validator', () {
    test('accepts a full-marks answer, with evidence mapped back to regions', () {
      final QuestionResult result = validate(marked());

      expect(result.awardedMarks, 2);
      expect(result.maximumMarks, 2);
      expect(result.needsReview, isFalse);
      expect(result.markingPoints.first.evidenceRegionIds, <String>['r1']);
      expect(result.confidence, closeTo(0.9, 1e-9));
    });

    test('partial credit is the sum of the points awarded', () {
      final QuestionResult result = validate(marked(
        awarded: 1,
        points: <Map<String, Object?>>[
          markingPoint('Names the mitochondrion', 1, 1),
          markingPoint('States ATP', 1, 0, evidence: const <String>[]),
        ],
      ));
      expect(result.awardedMarks, 1);
      expect(result.markingPoints.last.satisfied, isFalse);
      expect(result.needsReview, isFalse);
    });

    test('points taken from the printed mark scheme are labelled so', () {
      Map<String, Object?> point(String source) =>
          <String, Object?>{...markingPoint('Names the mitochondrion', 1, 1), 'source': source};

      final QuestionResult paper = validate(<String, Object?>{
        ...marked(points: <Map<String, Object?>>[point('paper'), point('paper')]),
        'marking_points_source': 'paper',
      });
      expect(paper.markingPointsSource, MarkingPointSource.markScheme);
      expect(paper.markingPoints.first.source, MarkingPointSource.markScheme);

      final QuestionResult mixed = validate(<String, Object?>{
        ...marked(points: <Map<String, Object?>>[point('paper'), point('inferred')]),
        'marking_points_source': 'mixed',
      });
      expect(mixed.markingPointsSource, MarkingPointSource.markScheme);
      expect(MarkingPointSource.fromWire(MarkingPointSource.markScheme.wireName),
          MarkingPointSource.markScheme);
    });

    test('the paper\'s maximum wins over the model\'s', () {
      final QuestionResult result = validate(marked(maximum: 5));
      expect(result.maximumMarks, 2);
      expect(result.reviewReasons.join(), contains("paper's 2 was used"));
    });

    test('an inferred scheme worth more than the question is capped and flagged', () {
      final QuestionResult result = validate(marked(
        awarded: 3,
        points: <Map<String, Object?>>[
          markingPoint('A', 1, 1),
          markingPoint('B', 1, 1),
          markingPoint('C', 1, 1),
        ],
      ));
      expect(result.awardedMarks, 2);
      expect(result.needsReview, isTrue);
      expect(result.reviewReasons.join(), contains('more than the 2 available'));
    });

    test('a point cannot award more than it is worth, or less than zero', () {
      final QuestionResult result = validate(marked(
        points: <Map<String, Object?>>[
          markingPoint('A', 1, 3),
          markingPoint('B', 1, -2),
        ],
      ));
      expect(result.markingPoints.map((MarkingPoint p) => p.marks), <double>[1, 0]);
      expect(result.awardedMarks, 1);
    });

    test('a total that disagrees with the points is recomputed', () {
      final QuestionResult result = validate(marked(awarded: 1.5));
      expect(result.awardedMarks, 2);
      expect(result.reviewReasons.join(), contains('points were used'));
    });

    test('evidence that is not part of this answer is dropped', () {
      final QuestionResult result = validate(marked(
        points: <Map<String, Object?>>[
          markingPoint('A', 1, 1, evidence: const <String>['R1', 'R2', 'R99']),
          markingPoint('B', 1, 1),
        ],
      ));
      expect(result.markingPoints.first.evidenceRegionIds, <String>['r1']);
      expect(result.reviewReasons.join(), contains('did not belong'));
    });

    test('a mark with no evidence at all goes to the teacher', () {
      final QuestionResult result = validate(marked(
        points: <Map<String, Object?>>[
          markingPoint('A', 1, 1, evidence: const <String>[]),
          markingPoint('B', 1, 1),
        ],
      ));
      expect(result.needsReview, isTrue);
      expect(result.markingPoints.first.basis, EvidenceBasis.uncertain);
    });

    test('a mark resting on uncertain evidence goes to the teacher', () {
      final QuestionResult result = validate(marked(
        points: <Map<String, Object?>>[
          markingPoint('A', 1, 1, basis: 'uncertain'),
          markingPoint('B', 1, 1),
        ],
      ));
      expect(result.needsReview, isTrue);
    });

    test('poor handwriting pulls confidence below the threshold', () {
      final QuestionResult result = validate(
        marked(confidence: 0.95),
        on: task(answer: answerWith(confidence: 0.5, flags: <String>['1 region(s) were read with low confidence.'])),
      );
      expect(result.confidence, 0.5);
      expect(result.needsReview, isTrue);
      expect(result.reviewReasons, contains('1 region(s) were read with low confidence.'));
    });

    test('an uncertain question mapping pulls confidence down too', () {
      final QuestionResult result = validate(
        marked(),
        on: task(answer: answerWith(alignment: 0.6)),
      );
      expect(result.needsReview, isTrue);
    });

    test('the model asking for review is honoured', () {
      final QuestionResult result = validate(marked(review: true));
      expect(result.needsReview, isTrue);
    });

    test('an unprinted maximum is taken from the model, and flagged', () {
      final QuestionResult result = validate(
        marked(maximum: 3),
        on: task(marks: null),
      );
      expect(result.maximumMarks, 3);
      expect(result.needsReview, isTrue);
    });

    test('a question with no answer scores zero without a request', () {
      final QuestionResult result = validator.unanswered(
        MarkingTask(question: question('5'), answer: const StudentAnswer.none('Q5')),
      );
      expect(result.awardedMarks, 0);
      expect(result.studentAnswer, 'No answer found');
      expect(result.needsReview, isFalse);
    });

    test('an unanswered question is flagged when stray writing exists', () {
      final QuestionResult result = validator.unanswered(
        MarkingTask(
          question: question('5'),
          answer: const StudentAnswer.none('Q5', flags: <String>['stray writing']),
        ),
      );
      expect(result.needsReview, isTrue);
    });
  });

  group('the marking prompt', () {
    test('cites regions by short alias and marks uncertain words', () {
      final Map<String, String> aliasMap = <String, String>{};
      final String text = MarkingPrompt.buildBatch(
        tasks: <MarkingTask>[
          MarkingTask(
            question: question('1'),
            answer: StudentAnswer(
              questionId: 'Q1',
              pages: const <int>[1],
              regionIds: const <String>['doc:p1:r0', 'doc:p1:v1', 'doc:p1:r2'],
              textEvidence: const <TextEvidenceItem>[
                TextEvidenceItem(
                  regionId: 'doc:p1:r0',
                  pageNumber: 1,
                  type: RegionType.handwrittenAnswer,
                  text: 'The chloroplost absorbs light',
                  rawText: 'The chloroplost absorbs light',
                  confidence: 0.6,
                  source: ReadingSource.trocr,
                  uncertainSpans: <UncertainSpan>[
                    UncertainSpan(text: 'chloroplost', confidence: 0.4, start: 4, end: 15),
                  ],
                ),
              ],
              visualRegionIds: const <String>['doc:p1:v1'],
              visualEvidence: const <VisualEvidence>[
                DiagramEvidence(
                  regionId: 'doc:p1:v1',
                  description: 'A leaf cell',
                  confidence: 0.8,
                  labels: <String>['chloroplast'],
                ),
              ],
              crossedOut: const <TextEvidenceItem>[
                TextEvidenceItem(
                  regionId: 'doc:p1:r2',
                  pageNumber: 1,
                  type: RegionType.crossedOut,
                  text: 'mitochondria',
                  rawText: 'mitochondria',
                  confidence: 0.9,
                  source: ReadingSource.trocr,
                ),
              ],
            ),
          ),
        ],
        aliases: aliasMap,
        guidance: 'Award one mark per organelle.',
        typedAnswerSheet: false,
      );

      expect(aliasMap, <String, String>{
        'doc:p1:r0': 'R1',
        'doc:p1:v1': 'R2',
        'doc:p1:r2': 'R3',
      });
      expect(text, contains('The {?chloroplost?} absorbs light'));
      expect(text, contains('labels: chloroplast'));
      expect(text, contains('Crossed out (not part of the final answer)'));
      expect(text, contains("TEACHER'S MARKING GUIDANCE"));
      expect(text, isNot(contains('doc:p1')));
    });
  });

  test('the mark scheme printed on the question paper reaches the prompt', () {
    final String text = MarkingPrompt.buildBatch(
      tasks: <MarkingTask>[
        MarkingTask(
          question: question('1'),
          answer: answerWith(),
          markScheme: '1. Names the mitochondrion (1)\n2. States ATP (1)',
          paperGuidance: 'Ignore spelling errors.',
        ),
        MarkingTask(question: question('2', text: ''), answer: answerWith()),
      ],
      aliases: <String, String>{},
      guidance: 'Accept "powerhouse".',
      typedAnswerSheet: false,
    );

    expect(text, contains('GENERAL GUIDANCE (printed on the question paper):\nIgnore spelling errors.'));
    expect(text, contains('Mark scheme (printed on the question paper):\n  1. Names the mitochondrion (1)'));
    expect(text, contains("TEACHER'S MARKING GUIDANCE"));
    expect(text, contains('Question: (not printed'));
    expect(MarkingPrompt.systemPrompt, contains('source "paper"'));
    // Printed once, not per question.
    expect('GENERAL GUIDANCE'.allMatches(text), hasLength(1));
  });

  test('equations, graphs and tables reach the prompt in structured form', () {
    final String text = MarkingPrompt.buildBatch(
      tasks: <MarkingTask>[
        MarkingTask(
          question: question('3'),
          answer: const StudentAnswer(
            questionId: 'Q3',
            pages: <int>[2],
            regionIds: <String>['e', 'g', 't', 'x'],
            visualRegionIds: <String>['e', 'g', 't', 'x'],
            visualEvidence: <VisualEvidence>[
              EquationEvidence(regionId: 'e', description: '', confidence: 0.7, latex: r'\frac{100}{0.05} = 200', plainText: '100/0.05 = 200'),
              GraphEvidence(regionId: 'g', description: 'Rate against temperature', confidence: 0.8, xAxis: 'temperature / °C', yAxis: 'rate', trend: 'rises then falls'),
              TableEvidence(regionId: 't', description: 'Results', confidence: 0.9, rows: <List<String>>[<String>['t', 'rate'], <String>['20', '4']]),
            ],
          ),
          images: const <MarkingImage>[MarkingImage(regionId: 'x', path: '/x.png', reason: 'diagram')],
        ),
      ],
      aliases: <String, String>{},
      guidance: '',
      typedAnswerSheet: false,
    );

    expect(text, contains(r'LaTeX \frac{100}{0.05} = 200'));
    expect(text, contains('x-axis: temperature / °C'));
    expect(text, contains('trend: rises then falls'));
    expect(text, contains('| 20 | 4 |'));
    expect(text, contains('[R4] visual region — not analysed; see its image.'));
    expect(text, contains('Images attached: [R4] (diagram)'));
  });

  group('the marking engine', () {
    List<MarkingTask> tasks(int count, {int images = 0}) => <MarkingTask>[
          for (int i = 1; i <= count; i++)
            MarkingTask(
              question: question('$i'),
              answer: StudentAnswer(
                questionId: 'Q$i',
                pages: const <int>[1],
                regionIds: <String>['r$i'],
                textEvidence: <TextEvidenceItem>[
                  TextEvidenceItem(
                    regionId: 'r$i',
                    pageNumber: 1,
                    type: RegionType.handwrittenAnswer,
                    text: 'answer $i',
                    rawText: 'answer $i',
                    confidence: 0.95,
                    source: ReadingSource.trocr,
                  ),
                ],
                answerConfidence: 0.95,
                alignmentConfidence: 1,
              ),
              images: <MarkingImage>[
                for (int k = 0; k < images; k++)
                  MarkingImage(regionId: 'r$i', path: '/missing/$i-$k.png', reason: 'diagram'),
              ],
            ),
        ];

    Map<String, Object?> answerAll(ModelRequest request) {
      final Iterable<RegExpMatch> ids =
          RegExp(r'=== QUESTION (Q\w+)').allMatches((request.parts.first as TextPart).text);
      return <String, Object?>{
        'questions': <Object?>[
          for (final RegExpMatch id in ids)
            marked(
              id: id.group(1)!,
              points: <Map<String, Object?>>[
                markingPoint('A', 1, 1),
                markingPoint('B', 1, 0, evidence: const <String>[]),
              ],
            ),
        ],
      };
    }

    test('batches questions and marks every one', () async {
      final FakeModelClient client =
          FakeModelClient((ModelRequest r, List<String> m) => answerAll(r));
      final ModelMarkingEngine engine = ModelMarkingEngine(
        client,
        () => pipelineConfig.copyWith(questionsPerMarkingRequest: 3),
      );

      final List<QuestionResult> results = await engine.mark(
        tasks(7),
        guidance: '',
        typedAnswerSheet: false,
      );

      expect(client.requests, hasLength(3));
      expect(results.map((QuestionResult r) => r.questionId),
          <String>['Q1', 'Q2', 'Q3', 'Q4', 'Q5', 'Q6', 'Q7']);
      expect(results.every((QuestionResult r) => r.awardedMarks == 1), isTrue);
      expect(results.first.model, 'model-a');
    });

    test('the image budget splits batches too', () async {
      final FakeModelClient client =
          FakeModelClient((ModelRequest r, List<String> m) => answerAll(r));
      final ModelMarkingEngine engine = ModelMarkingEngine(
        client,
        () => pipelineConfig.copyWith(maxImagesPerRequest: 4),
      );

      await engine.mark(tasks(4, images: 2), guidance: '', typedAnswerSheet: false);

      expect(client.requests, hasLength(2));
    });

    test('an unanswered question costs no request', () async {
      final FakeModelClient client =
          FakeModelClient((ModelRequest r, List<String> m) => answerAll(r));
      final ModelMarkingEngine engine = ModelMarkingEngine(client, () => pipelineConfig);

      final List<QuestionResult> results = await engine.mark(
        <MarkingTask>[
          MarkingTask(question: question('1'), answer: const StudentAnswer.none('Q1')),
        ],
        guidance: '',
        typedAnswerSheet: false,
      );

      expect(client.requests, isEmpty);
      expect(results.single.studentAnswer, 'No answer found');
    });

    test('question IDs are resolved as labels, however the model wrote them', () {
      final List<MarkingTask> batch = <MarkingTask>[
        MarkingTask(question: question('2(a)'), answer: answerWith()),
        MarkingTask(question: question('8'), answer: answerWith()),
      ];
      final Map<String, Map<String, Object?>> matched = ModelMarkingEngine.matchToQuestions(
        <Map<String, Object?>>[
          <String, Object?>{'question_id': '8'},
          <String, Object?>{'question_id': 'Q2 (a)'},
        ],
        batch,
      );
      expect(matched.keys, unorderedEquals(<String>['Q8', 'Q2a']));

      // One question asked alone is paired with one answer, whatever its ID.
      expect(
        ModelMarkingEngine.matchToQuestions(
          <Map<String, Object?>>[<String, Object?>{'question_id': '1'}],
          <MarkingTask>[batch.last],
        ).keys,
        <String>['Q8'],
      );
    });

    test('a question the model skips is retried, then handed to the teacher', () async {
      final FakeModelClient client = FakeModelClient(
        (ModelRequest r, List<String> m) => <String, Object?>{'questions': <Object?>[]},
      );
      final ModelMarkingEngine engine = ModelMarkingEngine(client, () => pipelineConfig);

      final List<QuestionResult> results =
          await engine.mark(tasks(1), guidance: '', typedAnswerSheet: false);

      expect(client.requests, hasLength(2));
      expect(results.single.needsReview, isTrue);
      expect(results.single.reviewReasons.single, contains('mark this question yourself'));
    });

    test('a model that is unavailable surfaces its error', () async {
      final FakeModelClient client = FakeModelClient(
        (ModelRequest r, List<String> m) =>
            const CorrectionException('quota gone', quotaExhausted: true),
      );
      final ModelMarkingEngine engine = ModelMarkingEngine(client, () => pipelineConfig);

      await expectLater(
        engine.mark(tasks(1), guidance: '', typedAnswerSheet: false),
        throwsA(isA<CorrectionException>()),
      );
    });

    test('teacher guidance reaches the prompt', () async {
      final FakeModelClient client =
          FakeModelClient((ModelRequest r, List<String> m) => answerAll(r));
      final ModelMarkingEngine engine = ModelMarkingEngine(client, () => pipelineConfig);

      await engine.mark(tasks(1), guidance: 'One mark each.', typedAnswerSheet: false);

      expect((client.requests.single.parts.first as TextPart).text, contains('One mark each.'));
    });
  });

  group('answer reconstruction', () {
    const EvidenceAnswerReconstructor reconstructor =
        EvidenceAnswerReconstructor(uncertainBelow: 0.8);

    ExamDocument doc() => document(<ExamPage>[
          page(1, regions: <PageRegion>[
            region('a', order: 0),
            region('x', type: RegionType.crossedOut, order: 1, confidence: 0.9),
            region('weak', type: RegionType.crossedOut, order: 2, confidence: 0.5),
            region('d', type: RegionType.diagram, order: 3),
          ]),
          page(2, regions: <PageRegion>[region('b', page: 2, order: 0)]),
        ]);

    AlignmentResult alignment() => AlignmentResult(
          segments: const <AnswerSegment>[
            AnswerSegment(segmentId: 's0', regionIds: <String>['a', 'x', 'weak', 'd'], pageNumbers: <int>[1]),
            AnswerSegment(segmentId: 's1', regionIds: <String>['b'], pageNumbers: <int>[2], continuesPrevious: true),
          ],
          alignments: const <String, QuestionAlignment>{
            'Q1': QuestionAlignment(
              questionId: 'Q1',
              segmentIds: <String>['s0', 's1'],
              confidence: 0.85,
              methods: <AlignmentMethod>[AlignmentMethod.label, AlignmentMethod.continuation],
              notes: <String>['Continued onto page 2 without a label.'],
            ),
          },
        );

    test('a question with no answer is flagged when writing before the first label was not matched', () {
      final ExamDocument sheet = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('head', order: 0, type: RegionType.printedText),
          region('lost', order: 1),
          region('a2', order: 2),
        ]),
      ]);
      const AlignmentResult aligned = AlignmentResult(
        segments: <AnswerSegment>[
          AnswerSegment(segmentId: 's0', regionIds: <String>['a2'], pageNumbers: <int>[1], labelKey: '2'),
        ],
        alignments: <String, QuestionAlignment>{
          'Q2': QuestionAlignment(
            questionId: 'Q2',
            segmentIds: <String>['s0'],
            confidence: 0.9,
            methods: <AlignmentMethod>[AlignmentMethod.label],
          ),
        },
        preambleRegionIds: <String>['head', 'lost'],
      );

      final Map<String, StudentAnswer> answers = reconstructor.reconstruct(
        document: sheet,
        evidence: EvidenceSet(handwriting: <String, HandwritingEvidence>{
          'lost': reading('lost', 'Q No l [b] A dedicated application.'),
          'a2': reading('a2', '2 Data processing.'),
        }),
        alignment: aligned,
        paper: paperOf(<Question>[question('1'), question('2')]),
      );

      expect(answers['Q1']!.isEmpty, isTrue);
      expect(answers['Q1']!.flags.single, contains('writing on page 1 was not matched'));
      final QuestionResult marked = validator.unanswered(
        MarkingTask(question: question('1'), answer: answers['Q1']!),
      );
      expect(marked.needsReview, isTrue);
    });

    test('writing before the first label raises no flag on a question after the first answered', () {
      final Map<String, StudentAnswer> answers = reconstructor.reconstruct(
        document: document(<ExamPage>[
          page(1, regions: <PageRegion>[region('title', order: 0), region('a1', order: 1)]),
        ]),
        evidence: EvidenceSet(handwriting: <String, HandwritingEvidence>{
          'title': reading('title', 'Northgate Academy Year 10 Biology'),
          'a1': reading('a1', '1 The mitochondrion.'),
        }),
        alignment: const AlignmentResult(
          segments: <AnswerSegment>[
            AnswerSegment(segmentId: 's0', regionIds: <String>['a1'], pageNumbers: <int>[1], labelKey: '1'),
          ],
          alignments: <String, QuestionAlignment>{
            'Q1': QuestionAlignment(questionId: 'Q1', segmentIds: <String>['s0'], confidence: 0.9, methods: <AlignmentMethod>[AlignmentMethod.label]),
          },
          preambleRegionIds: <String>['title'],
        ),
        paper: paperOf(<Question>[question('1'), question('2')]),
      );
      expect(answers['Q2']!.isEmpty, isTrue);
      expect(answers['Q2']!.flags, isEmpty);
    });

    test('a printed heading before the first label raises no flag', () {
      final Map<String, StudentAnswer> answers = reconstructor.reconstruct(
        document: document(<ExamPage>[
          page(1, regions: <PageRegion>[region('head', order: 0, type: RegionType.printedText)]),
        ]),
        evidence: const EvidenceSet(handwriting: <String, HandwritingEvidence>{}),
        alignment: const AlignmentResult(
          segments: <AnswerSegment>[],
          alignments: <String, QuestionAlignment>{},
          preambleRegionIds: <String>['head'],
        ),
        paper: paperOf(<Question>[question('1')]),
      );
      expect(answers['Q1']!.flags, isEmpty);
    });

    test('assembles text, visuals and crossed-out work across pages', () {
      final Map<String, StudentAnswer> answers = reconstructor.reconstruct(
        document: doc(),
        evidence: EvidenceSet(
          handwriting: <String, HandwritingEvidence>{
            'a': reading('a', '1 The nucleus'),
            'x': reading('x', 'mitochondria'),
            'weak': reading('weak', 'contains DNA'),
            'b': reading('b', 'controls the cell', confidence: 0.6),
          },
          visuals: const <String, VisualEvidence>{
            'd': DiagramEvidence(regionId: 'd', description: 'A cell', confidence: 0.8),
          },
        ),
        alignment: alignment(),
        paper: paperOf(<Question>[question('1'), question('2')]),
      );

      final StudentAnswer one = answers['Q1']!;
      expect(one.pages, <int>[1, 2]);
      expect(one.textEvidence.map((TextEvidenceItem t) => t.regionId), <String>['a', 'weak', 'b']);
      expect(one.crossedOut.single.text, 'mitochondria');
      expect(one.diagrams.single.description, 'A cell');
      expect(one.flags.join(' '), contains('may be crossed out'));
      expect(one.flags.join(' '), contains('low confidence'));
      expect(one.answerConfidence, lessThan(0.95));
      expect(answers['Q2']!.isEmpty, isTrue);
    });

    test('a diagram whose analysis failed keeps its image and caps confidence', () {
      final Map<String, StudentAnswer> answers = reconstructor.reconstruct(
        document: doc(),
        evidence: EvidenceSet(
          handwriting: <String, HandwritingEvidence>{'a': reading('a', '1 The nucleus')},
          visuals: <String, VisualEvidence>{
            'd': VisualEvidence.unanalysed(
              regionId: 'd',
              kind: RegionType.diagram,
              status: AnalysisStatus.failed,
              error: 'quota',
            ),
          },
        ),
        alignment: alignment(),
        paper: paperOf(<Question>[question('1')]),
      );

      final StudentAnswer one = answers['Q1']!;
      expect(one.visualRegionIds, <String>['d']);
      expect(one.answerConfidence, lessThanOrEqualTo(0.65));
      expect(one.flags.join(' '), contains('could not be analysed'));
    });

    test('printed question wording on the booklet is context, not the answer', () {
      expect(
        EvidenceAnswerReconstructor.isQuestionEcho(
          '1 Name the organelle that carries out aerobic respiration , and\n'
              'state the molecule it produces . ( 2 marks )',
          'Name the organelle that carries out aerobic respiration, and state '
              'the molecule it produces.',
        ),
        isTrue,
      );
      expect(
        EvidenceAnswerReconstructor.isQuestionEcho(
          'The mitochondrion. It makes ATP.',
          'Name the organelle that carries out aerobic respiration, and state '
              'the molecule it produces.',
        ),
        isFalse,
      );

      final Map<String, StudentAnswer> answers = reconstructor.reconstruct(
        document: doc(),
        evidence: EvidenceSet(
          handwriting: <String, HandwritingEvidence>{
            'a': reading('a', '1 Explain something about cells in detail.'),
            'b': reading('b', 'Cells divide by mitosis.', confidence: 0.9),
          },
          visuals: const <String, VisualEvidence>{
            'd': DiagramEvidence(regionId: 'd', description: 'A cell', confidence: 0.9),
          },
        ),
        alignment: alignment(),
        paper: paperOf(<Question>[question('1', text: 'Explain something about cells in detail.')]),
      );
      final StudentAnswer one = answers['Q1']!;
      expect(one.textEvidence.first.type, RegionType.printedText);
      expect(one.answerConfidence, closeTo(0.9, 0.05),
          reason: 'printing does not count towards how well the answer read');
    });

    test('a teacher correction is what marking reads, and the raw is kept', () {
      final Map<String, StudentAnswer> answers = reconstructor.reconstruct(
        document: doc(),
        evidence: EvidenceSet(handwriting: <String, HandwritingEvidence>{
          'a': reading('a', '1 The nucleas', confidence: 0.5).withTeacherText('1 The nucleus'),
        }),
        alignment: alignment(),
        paper: paperOf(<Question>[question('1')]),
      );
      final TextEvidenceItem item = answers['Q1']!.textEvidence.first;
      expect(item.text, '1 The nucleus');
      expect(item.rawText, '1 The nucleas');
      expect(item.source, ReadingSource.teacher);
      expect(item.confidence, 1);
    });
  });
}
