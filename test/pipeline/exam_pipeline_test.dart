import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/alignment/label_boundary_detector.dart';
import 'package:exam_corrector/pipeline/alignment/paper_question_aligner.dart';
import 'package:exam_corrector/pipeline/cache/artifact_store.dart';
import 'package:exam_corrector/pipeline/document/page_analyzer.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/exam_pipeline.dart';
import 'package:exam_corrector/pipeline/layout/text_layer_region_detector.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/services/review/teacher_work_store.dart';
import 'package:exam_corrector/pipeline/recognition/ensemble_handwriting_recognizer.dart';
import 'package:exam_corrector/pipeline/visual/visual_evidence_engine.dart';
import 'package:exam_corrector/services/pdf_service.dart';

import 'pipeline_fakes.dart';

class _Paper implements QuestionPaperExtractor {
  int calls = 0;
  List<QuestionChoice> choices = const <QuestionChoice>[];

  @override
  String get fingerprint => 'fake-paper';

  @override
  Future<QuestionPaper> extract(
    QuestionPaperSourceData source, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    calls++;
    return QuestionPaper(
      documentId: 'paper',
      questions: <Question>[question('1'), question('2'), question('3')],
      choices: choices,
    );
  }
}

/// Counts how often answers are found afresh rather than from the cache.
class _CountingBoundaries implements AnswerBoundaryDetector {
  int calls = 0;

  @override
  BoundaryResult detect(ExamDocument document, EvidenceSet evidence, QuestionPaper paper) {
    calls++;
    return const LabelBoundaryDetector().detect(document, evidence, paper);
  }
}

class _Renderer implements DocumentRenderer {
  _Renderer({this.unavailable = false});

  final bool unavailable;
  int calls = 0;

  @override
  String get fingerprint => 'fake-render';

  @override
  Future<ExamDocument> render(
    SelectedDocument document, {
    required Directory outputDirectory,
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    calls++;
    if (unavailable) {
      throw const OcrException('not installed', sidecarUnavailable: true);
    }
    // Real files: a cached render whose images have gone is re-rendered.
    final File image = File('${outputDirectory.path}/page_1.png');
    await image.writeAsString('png');
    return ExamDocument(
      documentId: document.contentHash,
      role: document.role,
      filePath: document.filePath,
      fileName: document.fileName,
      source: document.source,
      pages: <ExamPage>[
        ExamPage(
          pageId: ExamPage.idFor(document.contentHash, 1),
          pageNumber: 1,
          width: 100,
          height: 140,
          imagePath: image.path,
        ),
        ExamPage(
          pageId: ExamPage.idFor(document.contentHash, 2),
          pageNumber: 2,
          width: 100,
          height: 140,
          imagePath: image.path,
          isBlank: true,
        ),
      ],
    );
  }
}

class _Detector implements RegionDetector {
  int calls = 0;

  @override
  String get fingerprint => 'fake-detect';

  @override
  Future<RegionDetection> detect(
    ExamDocument document,
    List<ExamPage> pages, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    calls++;
    return RegionDetection(pages: <ExamPage>[
      for (final ExamPage page in pages)
        page.copyWith(regions: <PageRegion>[
          for (int i = 0; i < 3; i++)
            PageRegion(
              regionId: '${page.pageId}:r$i',
              pageId: page.pageId,
              pageNumber: page.pageNumber,
              type: i == 2 ? RegionType.diagram : RegionType.handwrittenAnswer,
              box: region('x').box,
              confidence: 0.8,
              readingOrder: i,
            ),
        ]),
    ]);
  }
}

class _Recognizer implements HandwritingRecognizer {
  int calls = 0;

  /// The first run cannot reach its second opinion for region r1.
  bool secondOpinionDown = false;
  final List<List<String>> asked = <List<String>>[];

  @override
  String get fingerprint => 'fake-read';

  @override
  Future<Map<String, HandwritingEvidence>> recognize(
    ExamDocument document,
    List<PageRegion> regions, {
    Map<String, HandwritingReading> priorReadings = const <String, HandwritingReading>{},
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    calls++;
    asked.add(regions.map((PageRegion r) => r.regionId).toList());
    return <String, HandwritingEvidence>{
      for (final PageRegion r in regions)
        r.regionId: secondOpinionDown && r.regionId.endsWith('r1')
            ? HandwritingEvidence(
                regionId: r.regionId,
                readings: const <HandwritingReading>[
                  HandwritingReading(source: ReadingSource.trocr, text: '2 Because enegy.', confidence: 0.6),
                ],
                error: '${EnsembleHandwritingRecognizer.secondOpinionUnavailable}: quota',
              )
            : priorReadings[r.regionId] != null
            ? HandwritingEvidence(
                regionId: r.regionId,
                readings: <HandwritingReading>[priorReadings[r.regionId]!],
              )
            : reading(
          r.regionId,
          r.regionId.endsWith('r0') ? '1 The mitochondrion.' : '2 Because energy.',
        ),
    };
  }
}

class _Visuals implements DiagramAnalyzer {
  int calls = 0;

  /// Calls that fail as if rate limited, before analysis starts working.
  int failing = 0;

  @override
  Future<Map<String, VisualEvidence>> analyzeDiagrams(
    List<VisualTask> tasks, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    calls++;
    if (failing > 0) {
      failing--;
      throw const CorrectionException('rate limited', transient: true);
    }
    return <String, VisualEvidence>{
      for (final VisualTask t in tasks)
        t.region.regionId: DiagramEvidence(
          regionId: t.region.regionId,
          description: 'A mitochondrion',
          confidence: 0.9,
        ),
    };
  }
}

class _Marker implements MarkingEngine {
  AppException? error;
  int calls = 0;
  final List<String> marked = <String>[];
  final List<MarkingTask> tasks = <MarkingTask>[];

  @override
  String get fingerprint => 'fake-mark';

  @override
  Future<List<QuestionResult>> mark(
    List<MarkingTask> tasks, {
    required String guidance,
    required bool typedAnswerSheet,
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    calls++;
    if (error != null) throw error!;
    this.tasks.addAll(tasks);
    return <QuestionResult>[
      for (final MarkingTask task in tasks)
        () {
          marked.add(task.question.questionId);
          return QuestionResult(
            questionNumber: task.question.displayNumber,
            questionId: task.question.questionId,
            maximumMarks: 2,
            awardedMarks: task.answer.isEmpty ? 0 : 1,
            studentAnswer: task.answer.text,
            evaluation: 'ok',
            model: task.answer.isEmpty ? '' : 'model-a',
            needsReview: task.question.questionId == 'Q2',
          );
        }(),
    ];
  }
}

class _Keys implements AnswerKeyEngine {
  int calls = 0;
  CorrectionException? error;
  final List<String> asked = <String>[];

  @override
  String get fingerprint => 'fake-key';

  @override
  Future<Map<String, AnswerKeyEntry>> prepare(
    List<AnswerKeyTask> tasks, {
    required String guidance,
    required String course,
    required MarkingStandard standard,
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    calls++;
    if (error != null) throw error!;
    asked.addAll(tasks.map((AnswerKeyTask t) => t.question.questionId));
    return <String, AnswerKeyEntry>{
      for (final AnswerKeyTask t in tasks)
        t.question.questionId: AnswerKeyEntry(
          questionId: t.question.questionId,
          maximum: t.question.maximumMarks!,
          points: <AnswerKeyPoint>[AnswerKeyPoint(criterion: 'Key point for ${t.question.questionId}', marks: t.question.maximumMarks!)],
          expectedWords: 40,
        ),
    };
  }
}

class _Pdf extends PdfService {
  const _Pdf();

  @override
  Future<String?> extractTextIfPresent(String path) async =>
      '1 Name it. [2 marks]\n2 Explain it. [2 marks]\n3 Draw it. [2 marks]';
}

class _TextLayer implements TextLayerReader {
  @override
  Future<List<TextLayerPage>> read(String path) async => const <TextLayerPage>[
        TextLayerPage(
          pageNumber: 1,
          width: 595,
          height: 842,
          lines: <TextLayerLine>[
            TextLayerLine(text: '1 Name the organelle.', left: 50, top: 100, width: 300, height: 12),
            TextLayerLine(text: 'Answer: The mitochondrion.', left: 60, top: 140, width: 300, height: 12),
            TextLayerLine(text: '2 Explain why.', left: 50, top: 200, width: 300, height: 12),
            TextLayerLine(text: 'Answer: Muscles need energy.', left: 60, top: 240, width: 300, height: 12),
          ],
        ),
      ];
}

void main() {
  late Directory workspace;
  late ArtifactStore store;
  late _Paper paper;
  late _Renderer renderer;
  late _Detector detector;
  late _Recognizer recognizer;
  late _Visuals visuals;
  late _Marker marker;
  late SelectedDocument answers;
  late SelectedDocument questions;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('pipeline_test');
    store = ArtifactStore(Directory('${workspace.path}/cache'));
    paper = _Paper();
    renderer = _Renderer();
    detector = _Detector();
    recognizer = _Recognizer();
    visuals = _Visuals();
    marker = _Marker();
    answers = await selected(workspace, 'answers.pdf', DocumentRole.answerSheet);
    questions = await selected(workspace, 'questions.pdf', DocumentRole.questionPaper);
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  ExamPipeline build({
    AppConfig config = pipelineConfig,
    AnswerBoundaryDetector boundaries = const LabelBoundaryDetector(),
    AnswerKeyEngine? keys,
  }) =>
      ExamPipeline(
        pdf: const _Pdf(),
        config: () => config,
        store: store,
        renderer: renderer,
        textLayer: _TextLayer(),
        pageAnalyzer: const DefaultPageAnalyzer(),
        regionDetector: detector,
        textLayerDetector: TextLayerRegionDetector(_TextLayer()),
        cropper: null,
        recognizer: recognizer,
        visuals: VisualEvidenceEngine(diagrams: visuals),
        visualFingerprint: 'fake-visual',
        questionExtractor: paper,
        boundaries: boundaries,
        aligner: const PaperQuestionAligner(),
        marker: marker,
        answerKeys: keys,
      );

  group('the answer key', () {
    test('is prepared once per paper, before marking, and every script is marked against it', () async {
      final _Keys keys = _Keys();
      await build(keys: keys).run(answerSheet: answers, questionPaper: questions);
      expect(keys.calls, 1);
      expect(keys.asked, isNotEmpty);
      expect(marker.tasks.first.answerKey, startsWith('- Key point for ${marker.tasks.first.question.questionId}'));
      expect(marker.tasks.first.expectedWords, 40);

      // Another student's script: the same key, no new request.
      final SelectedDocument other = await selected(workspace, 'other_answers.pdf', DocumentRole.answerSheet);
      await build(keys: keys).run(answerSheet: other, questionPaper: questions);
      expect(keys.calls, 1);

      // The teacher can read the key the paper was marked against.
      final JsonMap? saved = await TeacherWorkStore(store).answerKey(questions.contentHash);
      expect(AnswerKey.entriesFromJson(saved), isNotEmpty);
    });

    test("the teacher's correction replaces the AI's key and re-marks", () async {
      final _Keys keys = _Keys();
      await build(keys: keys).run(answerSheet: answers, questionPaper: questions);
      final int first = marker.calls;
      final String id = marker.tasks.first.question.questionId;

      await TeacherWorkStore(store).saveAnswerKeyEdits(questions.contentHash, <String, String>{
        id: '- The organelle named correctly [2]\nA full answer: about 10 words.',
      });
      await build(keys: keys).run(answerSheet: answers, questionPaper: questions);
      expect(marker.calls, greaterThan(first));
      final MarkingTask remarked = marker.tasks.lastWhere((MarkingTask t) => t.question.questionId == id);
      expect(remarked.answerKey, startsWith('- The organelle named correctly'));
      expect(remarked.expectedWords, 10);
      expect(keys.calls, 1);
    });

    test('a key that cannot be prepared does not stop marking', () async {
      final _Keys keys = _Keys()..error = const CorrectionException('The AI is busy.');
      final ExamAssessment assessment = await build(keys: keys).run(answerSheet: answers, questionPaper: questions);
      expect(assessment.result, isNotNull);
      expect(assessment.warnings.join(), contains('The answer key could not be prepared'));
      expect(marker.tasks.every((MarkingTask t) => t.answerKey.isEmpty), isTrue);
    });
  });

  test('runs every stage and marks every question in the paper', () async {
    final List<ProcessingStage> seen = <ProcessingStage>[];
    final ExamAssessment assessment = await build().run(
      answerSheet: answers,
      questionPaper: questions,
      onUpdate: (ProcessingJob job) {
        if (seen.isEmpty || seen.last != job.stage) seen.add(job.stage);
      },
    );

    expect(seen, containsAllInOrder(<ProcessingStage>[
      ProcessingStage.extractingQuestions,
      ProcessingStage.rendering,
      ProcessingStage.analyzingPages,
      ProcessingStage.detectingRegions,
      ProcessingStage.recognizingHandwriting,
      ProcessingStage.aligningQuestions,
      ProcessingStage.analyzingVisuals,
      ProcessingStage.reconstructingAnswers,
      ProcessingStage.marking,
      ProcessingStage.reviewRequired,
    ]));
    expect(assessment.result!.questions.map((QuestionResult q) => q.questionId),
        <String>['Q1', 'Q2', 'Q3']);
    expect(assessment.answers['Q1']!.regionIds, hasLength(1));
    expect(assessment.answers['Q2']!.diagrams.single.description, 'A mitochondrion');
    expect(assessment.answers['Q3']!.isEmpty, isTrue);
    expect(assessment.job.stage, ProcessingStage.reviewRequired);
    expect(assessment.job.overallFraction, 1);
    // The blank page was never sent for detection.
    expect(assessment.answerSheet.pageNumbered(2)!.isBlank, isTrue);
  });

  test('of an OR, the alternative answered is the one that counts', () async {
    paper.choices = const <QuestionChoice>[
      QuestionChoice(options: <List<String>>[<String>['Q2'], <String>['Q3']]),
    ];
    final ExamAssessment assessment =
        await build().run(answerSheet: answers, questionPaper: questions);

    final CorrectionResult result = assessment.result!;
    expect(result.question('Q2')!.counted, isTrue);
    expect(result.question('Q3')!.counted, isFalse);
    expect(result.question('Q3')!.choiceNote, contains('2 was answered instead'));
    expect(result.maximumTotalMarks, 4);
    expect(result.totalMarks, 2);
  });

  test('the same answer sheet against another question paper is aligned afresh', () async {
    final _CountingBoundaries boundaries = _CountingBoundaries();
    await build(boundaries: boundaries).run(answerSheet: answers, questionPaper: questions);
    final int first = boundaries.calls;
    expect(first, greaterThan(0));

    final SelectedDocument other =
        await selected(workspace, 'other_questions.pdf', DocumentRole.questionPaper);
    await build(boundaries: boundaries).run(answerSheet: answers, questionPaper: other);
    expect(boundaries.calls, greaterThan(first));

    // And the first paper again comes straight from the cache.
    final int second = boundaries.calls;
    await build(boundaries: boundaries).run(answerSheet: answers, questionPaper: questions);
    expect(boundaries.calls, second);
  });

  test('rounding and penalties reuse the cached marks; a stricter level marks again', () async {
    await build().run(answerSheet: answers, questionPaper: questions);
    final int first = marker.calls;
    expect(first, greaterThan(0));

    final ExamAssessment rounded = await build().run(
      answerSheet: answers,
      questionPaper: questions,
      standard: const MarkingStandard(markStep: 1, totalRounding: TotalRounding.up, mcqPenalty: 0.25),
    );
    expect(marker.calls, first);
    expect(rounded.result!.totalRounding, TotalRounding.up);
    expect(rounded.result!.standard, contains('whole marks'));

    await build().run(
      answerSheet: answers,
      questionPaper: questions,
      standard: const MarkingStandard(level: MarkingLevel.strict),
    );
    expect(marker.calls, greaterThan(first));
    expect(marker.tasks.last.standard.level, MarkingLevel.strict);
  });

  group('the syllabus', () {
    const Syllabus biology = Syllabus(
      id: 'bio',
      fileName: 'bio.txt',
      courseTitle: 'Cell biology',
      units: <SyllabusUnit>[
        SyllabusUnit(number: 'I', title: 'Cells', topics: <String>['Explain something about cells', 'Organelles']),
      ],
    );

    test("the teacher's choice is used, and each question gets its unit", () async {
      final ExamAssessment assessment = await build().run(
        answerSheet: answers,
        questionPaper: questions,
        syllabi: const <Syllabus>[biology],
        syllabusChoice: 'bio',
      );

      expect(assessment.syllabus?.name, 'Cell biology');
      expect(assessment.syllabus?.how, 'chosen by you');
      expect(marker.tasks.first.syllabusCourse, startsWith('Cell biology'));
      expect(marker.tasks.first.syllabus, startsWith('Unit I — Cells'));
      expect(assessment.result!.questions.first.syllabusReference, 'Unit I — Cells');
    });

    test('the syllabus bonus is measured from cached marks, with no re-marking', () async {
      await build().run(
        answerSheet: answers,
        questionPaper: questions,
        syllabi: const <Syllabus>[biology],
        syllabusChoice: 'bio',
      );
      final int first = marker.calls;
      expect(marker.tasks.first.syllabusFocus, 'Explain something about cells');

      final ExamAssessment withBonus = await build().run(
        answerSheet: answers,
        questionPaper: questions,
        syllabi: const <Syllabus>[biology],
        syllabusChoice: 'bio',
        standard: const MarkingStandard(syllabusBonus: SyllabusBonus(enabled: true)),
      );
      expect(marker.calls, first);
      expect(withBonus.result!.standard, contains('syllabus bonus'));
      expect(
        withBonus.result!.questions.every((QuestionResult q) => q.awardedMarks <= q.maximumMarks),
        isTrue,
      );
    });

    test('with no match the paper is marked without one, and the teacher is told', () async {
      const Syllabus unrelated = Syllabus(
        id: 'law',
        fileName: 'law.txt',
        courseTitle: 'Contract law',
        units: <SyllabusUnit>[SyllabusUnit(number: 'I', title: 'Offer', topics: <String>['Acceptance'])],
      );
      final ExamAssessment assessment = await build().run(
        answerSheet: answers,
        questionPaper: questions,
        syllabi: const <Syllabus>[unrelated],
      );

      expect(assessment.syllabus, isNull);
      expect(assessment.warnings.join(), contains('No saved syllabus matches'));
      expect(marker.tasks.every((MarkingTask t) => t.syllabusCourse.isEmpty), isTrue);
    });

    test('"No syllabus" is respected, silently', () async {
      final ExamAssessment assessment = await build().run(
        answerSheet: answers,
        questionPaper: questions,
        syllabi: const <Syllabus>[biology],
        syllabusChoice: SyllabusLibrary.none,
      );
      expect(assessment.syllabus, isNull);
      expect(assessment.warnings.join(), isNot(contains('syllabus')));
    });
  });

  test('a second run reuses every stage from the cache', () async {
    await build().run(answerSheet: answers, questionPaper: questions);
    // The scanned question paper is rendered too, once.
    expect(renderer.calls, 2);
    final ExamAssessment again =
        await build().run(answerSheet: answers, questionPaper: questions);

    expect(paper.calls, 1);
    expect(renderer.calls, 2);
    expect(detector.calls, 1);
    expect(recognizer.calls, 1);
    expect(visuals.calls, 1);
    expect(marker.calls, 1);
    expect(again.job.reusedStages, containsAll(<ProcessingStage>[
      ProcessingStage.rendering,
      ProcessingStage.detectingRegions,
      ProcessingStage.recognizingHandwriting,
      ProcessingStage.marking,
    ]));
    expect(again.result!.questions, hasLength(3));
  });

  test('analysis that failed is retried on the next run, and only that', () async {
    visuals.failing = 1;
    final ExamAssessment first =
        await build().run(answerSheet: answers, questionPaper: questions);
    expect(first.answers['Q2']!.visualEvidence.single.status, AnalysisStatus.failed);

    final ExamAssessment second =
        await build().run(answerSheet: answers, questionPaper: questions);

    expect(visuals.calls, 2);
    expect(second.answers['Q2']!.diagrams.single.description, 'A mitochondrion');
    expect(renderer.calls, 2, reason: 'nothing before it was repeated');
  });

  test('a reading that missed its second opinion is retried, and only that', () async {
    recognizer.secondOpinionDown = true;
    await build().run(answerSheet: answers, questionPaper: questions);
    recognizer.secondOpinionDown = false;

    final ExamAssessment second =
        await build().run(answerSheet: answers, questionPaper: questions);

    expect(recognizer.asked.last, hasLength(1));
    expect(recognizer.asked.last.single, endsWith('r1'));
    expect(second.answers['Q2']!.text, contains('Because energy'));
  });

  test('when marking fails, the extracted answers are kept and resumable', () async {
    marker.error = const CorrectionException('quota gone', quotaExhausted: true);

    final ExamAssessment failed =
        await build().run(answerSheet: answers, questionPaper: questions);

    expect(failed.result, isNull);
    expect(failed.job.stage, ProcessingStage.failed);
    expect(failed.job.failedStage, ProcessingStage.marking);
    expect(failed.answers['Q1']!.text, contains('mitochondrion'));
    expect(failed.warnings.last, contains('Marking stopped'));

    marker.error = null;
    final ExamAssessment resumed =
        await build().run(answerSheet: answers, questionPaper: questions);

    expect(resumed.result, isNotNull);
    expect(renderer.calls, 2, reason: 'rendering was not repeated');
    expect(detector.calls, 1, reason: 'detection was not repeated');
    expect(recognizer.calls, 1, reason: 'recognition was not repeated');
  });

  test('a teacher correction re-marks only the question it belongs to', () async {
    final ExamAssessment first =
        await build().run(answerSheet: answers, questionPaper: questions);
    marker.marked.clear();

    final String q2Region = first.answers['Q2']!.textEvidence.first.regionId;
    await build().run(
      answerSheet: answers,
      questionPaper: questions,
      teacherTranscriptions: <String, String>{q2Region: '2 Because muscles respire.'},
    );

    expect(marker.marked, <String>['Q2']);
    expect(recognizer.calls, 1);
  });

  test('cancelling stops the run and reports it', () async {
    final CancellationToken token = CancellationToken()..cancel();
    await expectLater(
      build().run(answerSheet: answers, questionPaper: questions, cancel: token),
      throwsA(isA<CancelledException>()),
    );
  });

  test('cancelling mid-run keeps what finished, so starting again resumes', () async {
    final CancellationToken token = CancellationToken();
    await expectLater(
      build().run(
        answerSheet: answers,
        questionPaper: questions,
        cancel: token,
        onUpdate: (ProcessingJob job) {
          if (job.stage == ProcessingStage.aligningQuestions) token.cancel();
        },
      ),
      throwsA(isA<CancelledException>()),
    );
    expect(marker.calls, 0);

    await build().run(answerSheet: answers, questionPaper: questions);
    expect(recognizer.calls, 1);
    expect(marker.calls, 1);
  });

  test('a stage failure names the stage it stopped at', () async {
    final ExamPipeline pipeline = ExamPipeline(
      pdf: const _Pdf(),
      config: () => pipelineConfig,
      store: store,
      renderer: _Renderer(unavailable: true),
      textLayer: _TextLayer(),
      pageAnalyzer: const DefaultPageAnalyzer(),
      regionDetector: detector,
      textLayerDetector: TextLayerRegionDetector(_TextLayer()),
      cropper: null,
      recognizer: recognizer,
      visuals: const VisualEvidenceEngine(),
      visualFingerprint: 'none',
      questionExtractor: paper,
      boundaries: const LabelBoundaryDetector(),
      aligner: const PaperQuestionAligner(),
      marker: marker,
    );

    final SelectedDocument typedPaper = await selected(
      workspace,
      'typed_questions.pdf',
      DocumentRole.questionPaper,
      source: DocumentSource.textLayer,
    );
    await expectLater(
      pipeline.run(answerSheet: answers, questionPaper: typedPaper),
      throwsA(isA<PipelineException>().having(
        (PipelineException e) => e.message,
        'message',
        contains('is a scan'),
      )),
    );
    final ProcessingJob? saved = await pipeline.lastJob(answers, typedPaper);
    expect(saved!.stage, ProcessingStage.failed);
    expect(saved.failedStage, ProcessingStage.rendering);
  });

  test('a typed answer sheet works from its text layer with no recogniser', () async {
    final SelectedDocument typed = await selected(
      workspace,
      'typed.pdf',
      DocumentRole.answerSheet,
      source: DocumentSource.textLayer,
    );
    final SelectedDocument typedPaper = await selected(
      workspace,
      'typed_questions.pdf',
      DocumentRole.questionPaper,
      source: DocumentSource.textLayer,
    );
    renderer = _Renderer(unavailable: true);

    final ExamAssessment assessment =
        await build().run(answerSheet: typed, questionPaper: typedPaper);

    expect(assessment.result, isNotNull);
    expect(assessment.answers['Q1']!.text, contains('The mitochondrion'));
    expect(assessment.answers['Q2']!.text, contains('Muscles need energy'));
    expect(assessment.warnings.join(), contains('Page images are unavailable'));
    expect(recognizer.calls, 1, reason: 'the ensemble sees text-layer readings');
    expect(detector.calls, 0, reason: 'no page needed layout analysis');
  });
}
