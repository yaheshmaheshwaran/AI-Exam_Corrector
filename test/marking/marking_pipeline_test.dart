import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:exam_corrector/ai/model_request.dart';
import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/marking/contracts.dart';
import 'package:exam_corrector/marking/marking_pipeline.dart';
import 'package:exam_corrector/marking/script/pages.dart';
import 'package:exam_corrector/marking/stage_store.dart';
import 'package:exam_corrector/models/question_result.dart';

import 'marking_fakes.dart';

/// Two pages of plain JPEGs, without PDFium.
class _Renderer extends PageRenderer {
  int calls = 0;

  @override
  Future<List<ExamPage>> render(
    String pdfPath, {
    required String documentId,
    required Directory folder,
    void Function(int done, int total)? onPage,
    CancellationToken? cancel,
  }) async {
    calls++;
    await folder.create(recursive: true);
    return <ExamPage>[
      for (int n = 1; n <= 2; n++)
        ExamPage(
          pageId: ExamPage.idFor(documentId, n),
          pageNumber: n,
          width: 100,
          height: 140,
          imagePath: (File('${folder.path}/page_$n.jpg')
                ..writeAsBytesSync(img.encodeJpg(img.Image(width: 100, height: 140))))
              .path,
        ),
    ];
  }
}

/// The paper: two questions of 2 marks, no printed scheme.
class _Paper implements QuestionPaperExtractor {
  int calls = 0;

  @override
  String get fingerprint => 'fake-paper';

  @override
  Future<QuestionPaper> extract(QuestionPaperSourceData source,
      {StageProgress? onProgress, CancellationToken? cancel}) async {
    calls++;
    return paperOf(<Question>[question('1'), question('2')]);
  }
}

Map<String, Object?> _region(String type, List<String> lines, {String label = ''}) => <String, Object?>{
      'type': type,
      'box_2d': <int>[100, 100, 300, 900],
      'label': label,
      'lines': lines,
      'strike_kind': 'none',
      'confidence': 0.95,
    };

/// Page 1 answers question 1, page 2 question 2.
Map<String, Object?> _pages(ModelRequest request) => <String, Object?>{
      'pages': <Object?>[
        for (int i = 0; i < request.imageCount; i++)
          <String, Object?>{
            'page_index': i,
            'regions': <Object?>[
              _region('question_number', <String>['${i + 1})'], label: '${i + 1})'),
              _region('handwritten_answer', <String>['Answer to question ${i + 1}: sensors read data.']),
            ],
          },
      ],
    };

Map<String, Object?> _key() => <String, Object?>{
      'keys': <Object?>[
        for (final String id in <String>['Q1', 'Q2'])
          <String, Object?>{
            'question_id': id,
            'points': <Object?>[
              <String, Object?>{'description': 'Names what sensors do', 'marks': 2},
            ],
            'expected_words': 6,
          },
      ],
    };

/// Marks every question in the request, each citing its own first region.
Map<String, Object?> _marks(String text, double each) {
  final List<Object?> questions = <Object?>[];
  for (final String block in text.split('QUESTION ').skip(1)) {
    final String id = RegExp(r'^(Q\d+)').firstMatch(block)!.group(1)!;
    final String? alias = RegExp(r'\[(R\d+)\]').firstMatch(block)?.group(1);
    questions.add(<String, Object?>{
      'question_id': id,
      'maximum_marks': 2,
      'marking_points_source': 'answer_key',
      'marking_points': <Object?>[
        <String, Object?>{
          'id': 'p1',
          'description': 'Names what sensors do',
          'source': 'answer_key',
          'marks_available': 2,
          'marks_awarded': each,
          'evidence': <String>[?alias],
          'basis': 'observed',
        },
      ],
      'awarded_marks': each,
      'explanation': 'Names what sensors do.',
      'confidence': 0.9,
      'needs_review': false,
      'student_answer': 'sensors read data',
    });
  }
  return <String, Object?>{'questions': questions};
}

void main() {
  late Directory dir;
  late SelectedDocument script;
  late SelectedDocument paper;
  late _Renderer renderer;
  late _Paper paperReader;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pipeline');
    script = await selected(dir, 'script.pdf', DocumentRole.answerSheet);
    paper = await selected(dir, 'paper.pdf', DocumentRole.questionPaper);
    renderer = _Renderer();
    paperReader = _Paper();
  });
  tearDown(() => dir.delete(recursive: true));

  /// A model answering each kind of request; [marking] decides the marks.
  FakeModelClient client({Object? Function(String text)? marking}) => FakeModelClient(
        (ModelRequest request, List<String> models) => switch (request.purpose) {
          'page reading' => _pages(request),
          'answer key' => _key(),
          'marking' => (marking ?? (String text) => _marks(text, 1.5))(
              request.parts.whereType<TextPart>().map((TextPart p) => p.text).join('\n'),
            ),
          _ => throw StateError('unexpected ${request.purpose}'),
        },
      );

  MarkingPipeline pipeline(FakeModelClient model) => MarkingPipeline(
        settings: () => pipelineSettings,
        store: StageStore(Directory('${dir.path}/cache')),
        client: model,
        renderer: renderer,
        questionExtractor: paperReader,
      );

  int count(FakeModelClient model, String purpose) =>
      model.requests.where((ModelRequest r) => r.purpose == purpose).length;

  test('a script is read, matched, keyed and marked, stage by stage', () async {
    final FakeModelClient model = client();
    final List<ProcessingStage> seen = <ProcessingStage>[];
    final ExamAssessment assessment = await pipeline(model).run(
      answerSheet: script,
      questionPaper: paper,
      onUpdate: (ProcessingJob job) {
        if (seen.isEmpty || seen.last != job.stage) seen.add(job.stage);
      },
    );

    expect(assessment.result!.totalMarks, 3);
    expect(assessment.answers['Q1']!.pages, <int>[1]);
    expect(assessment.answers['Q2']!.pages, <int>[2]);
    expect(assessment.answers['Q2']!.text, contains('Answer to question 2'));
    expect(assessment.result!.questions.map((QuestionResult q) => q.model), everyElement('model-a'));
    expect(seen, containsAllInOrder(ProcessingStage.pipeline));
    expect(assessment.job.stage, isIn(<ProcessingStage>[ProcessingStage.completed, ProcessingStage.reviewRequired]));
    expect(assessment.job.overallFraction, 1);
    expect(count(model, 'page reading'), 1, reason: 'both pages in one request');
    expect(count(model, 'answer key'), 1);
    expect(count(model, 'marking'), 1);
  });

  test('a second run reuses every stage and spends nothing', () async {
    await pipeline(client()).run(answerSheet: script, questionPaper: paper);
    final FakeModelClient again = client();
    final ExamAssessment assessment = await pipeline(again).run(answerSheet: script, questionPaper: paper);

    expect(again.requests, isEmpty);
    expect(assessment.result!.totalMarks, 3);
    expect(assessment.job.reusedStages,
        containsAll(<ProcessingStage>[ProcessingStage.extractingQuestions, ProcessingStage.readingPages, ProcessingStage.marking]));
    expect(paperReader.calls, 1);
  });

  test('the answer key is written once and shared by every script of the paper', () async {
    await pipeline(client()).run(answerSheet: script, questionPaper: paper);
    final SelectedDocument other = await selected(dir, 'other.pdf', DocumentRole.answerSheet);
    final FakeModelClient model = client();
    await pipeline(model).run(answerSheet: other, questionPaper: paper);

    expect(count(model, 'answer key'), 0);
    expect(count(model, 'marking'), 1);
  });

  test('a marking failure keeps everything read, and marking again resumes there', () async {
    final ExamAssessment stopped = await pipeline(
      client(marking: (String text) => const CorrectionException('out of allowance', quotaExhausted: true)),
    ).run(answerSheet: script, questionPaper: paper);

    expect(stopped.result, isNull);
    expect(stopped.job.stage, ProcessingStage.failed);
    expect(stopped.job.failedStage, ProcessingStage.marking);
    expect(stopped.answers['Q1']!.isEmpty, isFalse);
    expect(stopped.warnings.last, contains('resumes where it stopped'));

    final FakeModelClient model = client();
    final ExamAssessment resumed = await pipeline(model).run(answerSheet: script, questionPaper: paper);
    expect(count(model, 'page reading'), 0);
    expect(resumed.result!.totalMarks, 3);
  });

  test("a teacher's correction of one reading re-marks only that question", () async {
    final ExamAssessment first = await pipeline(client()).run(answerSheet: script, questionPaper: paper);
    final String regionId = first.answers['Q2']!.textEvidence.single.regionId;

    final FakeModelClient model = client();
    final ExamAssessment corrected = await pipeline(model).run(
      answerSheet: script,
      questionPaper: paper,
      teacherTranscriptions: <String, String>{regionId: 'Sensors read the temperature.'},
    );

    final String marked = model.requests.singleWhere((ModelRequest r) => r.purpose == 'marking').parts
        .whereType<TextPart>()
        .map((TextPart p) => p.text)
        .join();
    expect(marked, contains('QUESTION Q2'));
    expect(marked, isNot(contains('QUESTION Q1')));
    expect(corrected.answers['Q2']!.text, contains('Sensors read the temperature.'));
  });

  test('a backup run marks with the backup model only, every mark flagged', () async {
    final List<List<String>> asked = <List<String>>[];
    final FakeModelClient model = FakeModelClient((ModelRequest request, List<String> models) {
      if (request.purpose == 'marking') asked.add(models);
      return switch (request.purpose) {
        'page reading' => _pages(request),
        'answer key' => _key(),
        _ => _marks(request.parts.whereType<TextPart>().map((TextPart p) => p.text).join('\n'), 1),
      };
    });
    final ExamAssessment assessment =
        await pipeline(model).run(answerSheet: script, questionPaper: paper, backup: true);

    expect(asked.single, <String>['model-b']);
    expect(assessment.result!.questions.every((QuestionResult q) => q.needsReview), isTrue);
    expect(assessment.result!.questions.first.reviewReasons.join(), contains('backup model model-b'));
  });

  test('reading only stops before the key and the marks', () async {
    final FakeModelClient model = client();
    final ExamAssessment assessment =
        await pipeline(model).run(answerSheet: script, questionPaper: paper, prepareOnly: true);

    expect(assessment.result, isNull);
    expect(assessment.answers['Q1']!.isEmpty, isFalse);
    expect(count(model, 'answer key') + count(model, 'marking'), 0);
  });

  test('a cancelled run says so, and is saved as cancelled', () async {
    final CancellationToken cancel = CancellationToken()..cancel();
    final MarkingPipeline run = pipeline(client());

    await expectLater(
      run.run(answerSheet: script, questionPaper: paper, cancel: cancel),
      throwsA(isA<CancelledException>()),
    );
    expect((await run.lastJob(script, paper))!.stage, ProcessingStage.cancelled);
  });

  test('the judge of earlier marks ignores marks the teacher\'s key settled', () {
    QuestionResult by(String model) => QuestionResult(
          questionNumber: '1',
          questionId: 'Q1',
          maximumMarks: 1,
          awardedMarks: 1,
          studentAnswer: '',
          evaluation: '',
          model: model,
        );
    expect(MarkingPipeline.judgeOf(<QuestionResult>[by('model-b'), by('model-b'), by('model-a')]), 'model-b');
    expect(MarkingPipeline.flagBackup(by('model-a'), const <String>['model-a', 'model-b']).needsReview, isFalse);
    expect(MarkingPipeline.flagBackup(by('model-b'), const <String>['model-a', 'model-b']).needsReview, isTrue);
  });
}
