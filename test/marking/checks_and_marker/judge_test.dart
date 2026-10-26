import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/marking/contracts.dart';
import 'package:exam_corrector/marking/marking_pipeline.dart';
import 'package:exam_corrector/marking/script/marker/keyed_mcq_marker.dart';
import 'package:exam_corrector/marking/script/marker/model_marking_engine.dart';
import 'package:exam_corrector/ai/model_request.dart';

import '../marking_fakes.dart';
import 'marking_test.dart' show marked;

/// Answers every request, as the model [answeredBy] says, and remembers
/// which models each request was allowed to use.
class _Client implements ModelClient {
  _Client(this.answeredBy, {this.maxQuestions = 99});

  final String Function(int call, List<String> models) answeredBy;

  /// More questions than this in one request are cut off at the output limit.
  final int maxQuestions;
  final List<List<String>> allowed = <List<String>>[];

  @override
  bool get isAvailable => true;

  @override
  Future<ModelResponse> requestJson(
    ModelRequest request, {
    required List<String> models,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) async {
    allowed.add(models);
    final String model = answeredBy(allowed.length, models);
    if (model.isEmpty) {
      throw const CorrectionException('No quota left.', quotaExhausted: true, dailyQuota: true);
    }
    final String text = request.parts.whereType<TextPart>().map((TextPart p) => p.text).join();
    if (RegExp(r'\bQ\d\b').allMatches(text).map((RegExpMatch m) => m.group(0)).toSet().length > maxQuestions) {
      throw CorrectionException(request.truncationHint, truncated: true);
    }
    return ModelResponse(
      payload: <String, Object?>{
        'questions': <Object?>[marked(id: text.contains('Q2') ? 'Q2' : 'Q1')],
      },
      model: model,
    );
  }
}

StudentAnswer answer(String id) => StudentAnswer(
      questionId: id,
      pages: const <int>[1],
      regionIds: <String>['$id-r'],
      textEvidence: <TextEvidenceItem>[
        TextEvidenceItem(
          regionId: '$id-r',
          pageNumber: 1,
          type: RegionType.handwrittenAnswer,
          text: 'The mitochondrion makes ATP.',
          rawText: 'The mitochondrion makes ATP.',
          confidence: 0.95,
          source: ReadingSource.vision,
        ),
      ],
      answerConfidence: 0.95,
      alignmentConfidence: 1,
    );

void main() {
  final List<MarkingTask> tasks = <MarkingTask>[
    for (final String n in <String>['1', '2'])
      MarkingTask(question: question(n, marks: 2), answer: answer('Q$n')),
  ];
  // One question per request, so one script takes two requests.
  ModelMarkingEngine engine(ModelClient client) =>
      ModelMarkingEngine(client, () => pipelineSettings.withLimits(questionsPerRequest: 1));

  test('the model that marks the first batch marks the rest of the script', () async {
    // The main model is busy for the first request, so the backup marks it.
    final _Client client = _Client((int call, List<String> models) => call == 1 ? 'model-b' : models.first);

    final List<QuestionResult> results =
        await engine(client).mark(tasks, guidance: '', typedAnswerSheet: false);

    expect(client.allowed.first, <String>['model-a', 'model-b']);
    expect(client.allowed[1], <String>['model-b']);
    expect(results.map((QuestionResult r) => r.model), <String>['model-b', 'model-b']);
  });

  test('a batch cut off at the output limit is marked in halves, by one marker', () async {
    final _Client client = _Client((int call, List<String> models) => models.first, maxQuestions: 1);

    final List<QuestionResult> results = await ModelMarkingEngine(client, () => pipelineSettings)
        .mark(tasks, guidance: '', typedAnswerSheet: false);

    expect(client.allowed, hasLength(3), reason: 'the whole batch, then each half');
    expect(client.allowed.last, <String>['model-a'], reason: 'the second half keeps the first half\'s marker');
    expect(results.map((QuestionResult r) => r.model), <String>['model-a', 'model-a']);
  });

  test('a resumed script is finished by the model that began it', () async {
    final _Client client = _Client((int call, List<String> models) => models.first);

    await engine(client).mark(tasks, guidance: '', typedAnswerSheet: false, judge: 'model-b');

    expect(client.allowed, everyElement(<String>['model-b']));
  });

  test('when the judge is out of quota the script waits instead of changing marker', () async {
    final _Client client = _Client((int call, List<String> models) => '');

    expect(
      () => engine(client).mark(tasks, guidance: '', typedAnswerSheet: false, judge: 'model-b'),
      throwsA(isA<CorrectionException>()
          .having((CorrectionException e) => e.quotaExhausted, 'quotaExhausted', isTrue)
          .having((CorrectionException e) => e.message, 'message', contains('one marker marks the whole script'))),
    );
  });

  test('the judge is read from earlier marks, ignoring the teacher\'s key', () {
    QuestionResult by(String model) => QuestionResult(
          questionNumber: '1',
          questionId: 'Q1',
          maximumMarks: 1,
          awardedMarks: 1,
          studentAnswer: '',
          evaluation: '',
          model: model,
        );
    expect(MarkingPipeline.judgeOf(<QuestionResult>[]), isNull);
    expect(MarkingPipeline.judgeOf(<QuestionResult>[by(KeyedMcqMarker.markedBy), by('')]), isNull);
    expect(
      MarkingPipeline.judgeOf(<QuestionResult>[by('model-a'), by('model-b'), by('model-b'), by(KeyedMcqMarker.markedBy)]),
      'model-b',
    );
  });
}
