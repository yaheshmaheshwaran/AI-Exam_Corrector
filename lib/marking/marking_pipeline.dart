import 'dart:io';

import 'package:exam_corrector/ai/model_request.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/moderation.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/marking/contracts.dart';
import 'package:exam_corrector/marking/document_reader.dart';
import 'package:exam_corrector/marking/exam/answer_key.dart';
import 'package:exam_corrector/marking/exam/question_paper/model_question_paper_extractor.dart';
import 'package:exam_corrector/marking/exam/question_paper/question_paper_parser.dart';
import 'package:exam_corrector/marking/exam/syllabus/syllabus_index.dart';
import 'package:exam_corrector/marking/exam/syllabus/syllabus_matcher.dart';
import 'package:exam_corrector/marking/exam/teacher_key/teacher_key.dart';
import 'package:exam_corrector/marking/exam/teacher_key/teacher_key_reader.dart';
import 'package:exam_corrector/marking/hooks.dart';
import 'package:exam_corrector/marking/marking_settings.dart';
import 'package:exam_corrector/marking/script/answer_cleaner.dart';
import 'package:exam_corrector/marking/script/checks/choice_resolver.dart';
import 'package:exam_corrector/marking/script/checks/marking_rules.dart';
import 'package:exam_corrector/marking/script/marker/keyed_mcq_marker.dart';
import 'package:exam_corrector/marking/script/marker/model_marking_engine.dart';
import 'package:exam_corrector/marking/script/matching/label_boundary_detector.dart';
import 'package:exam_corrector/marking/script/matching/paper_question_aligner.dart';
import 'package:exam_corrector/marking/script/matching/teacher_assignments.dart';
import 'package:exam_corrector/marking/script/page_reader.dart';
import 'package:exam_corrector/marking/script/pages.dart';
import 'package:exam_corrector/marking/stage_store.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/services/review/teacher_work_store.dart';

/// The one pipeline: one student's whole answer script, marked.
///
/// ```
/// once per exam   question paper → questions · answer key (AI, or the teacher's)
/// every student   PDF → pages → read (whole pages) → answers matched to
///                 questions → cleaned answers → marked → checked
/// ```
///
/// Every stage saves its result under a key built from its inputs, so an
/// unchanged script is never read twice, a stopped run resumes where it
/// stopped, and a teacher's correction of one reading re-marks only the
/// question it belongs to.
class MarkingPipeline {
  MarkingPipeline({
    required MarkingSettings Function() settings,
    required StageStore store,
    required ModelClient client,
    PageRenderer? renderer,
    DocumentReader documents = const DocumentReader(),
    PageReader Function(MarkingSettings settings)? reader,
    QuestionPaperExtractor? questionExtractor,
    AnswerKeyEngine? answerKeys,
    bool writeAnswerKeys = true,
    TeacherKeyReader? teacherKeys,
    MarkingEngine? marker,
    AnswerBoundaryDetector boundaries = const LabelBoundaryDetector(),
    QuestionAligner aligner = const PaperQuestionAligner(),
    this.hooks = const <MarkingHook>[],
  })  : _settings = settings,
        _store = store,
        _renderer = renderer ?? PageRenderer(),
        _documents = documents,
        _reader = reader ??
            ((MarkingSettings s) => PageReader(
                  client,
                  models: s.chain(ModelRole.reader),
                  uncertainBelow: s.uncertainBelow,
                  selfHostedModel: selfHostedIn(s.ai.providers),
                )),
        _questionExtractor = questionExtractor ??
            CompositeQuestionPaperExtractor(
              parser: const HeuristicQuestionPaperParser(),
              model: ModelQuestionPaperExtractor(client, settings),
            ),
        _answerKeys = writeAnswerKeys ? answerKeys ?? ModelAnswerKeyEngine(client, settings) : null,
        _teacherKeys = teacherKeys ?? CompositeTeacherKeyReader(model: ModelTeacherKeyReader(client, settings)),
        _marker = marker ?? ModelMarkingEngine(client, settings),
        _boundaries = boundaries,
        _aligner = aligner;

  final MarkingSettings Function() _settings;
  final StageStore _store;
  final PageRenderer _renderer;
  final DocumentReader _documents;
  final PageReader Function(MarkingSettings settings) _reader;
  final QuestionPaperExtractor _questionExtractor;
  final AnswerKeyEngine? _answerKeys;
  final TeacherKeyReader _teacherKeys;
  final MarkingEngine _marker;
  final AnswerBoundaryDetector _boundaries;
  final QuestionAligner _aligner;

  /// Run in order just before marking; see [MarkingHook].
  final List<MarkingHook> hooks;

  StageStore get store => _store;

  /// Images attached per question for the marker, at most.
  static const int imagesPerQuestion = 6;

  /// The syllabus choice that means "mark without one".
  static const String noSyllabus = 'none';

  /// The version of the matching stage's logic: it is deterministic, so a
  /// saved result is only stale when the code that made it has changed.
  static const String matchingVersion = 'align:v9';

  /// Reads the question paper alone — the same stage, and the same cache, as
  /// a run — so the teacher's answer key can be matched to its questions
  /// before any script is marked.
  Future<QuestionPaper> readQuestionPaper(SelectedDocument paper, {CancellationToken? cancel}) async {
    final _Reporter job = _Reporter(
      ProcessingJob(jobId: 'paper-${paper.contentHash}', stage: ProcessingStage.extractingQuestions),
      null,
    );
    return (await _questions(paper, job, cancel)).paper;
  }

  /// The teacher's answer key matched to [paper]'s questions, saved under
  /// the paper: the same key against the same questions is matched once.
  Future<TeacherKey> alignTeacherKey(
    QuestionPaper paper,
    String paperHash,
    TeacherKeySource source, {
    MarkingStandard standard = const MarkingStandard(),
    CancellationToken? cancel,
  }) async {
    final String key = 'teacher-key-${StageStore.fingerprint(<Object?>[
          _teacherKeys.fingerprint,
          source.hash,
          paper.toJson(),
          standard.mcqSections,
        ])}';
    final TeacherKey? cached = TeacherKey.fromJson(await _store.read(paperHash, key));
    if (cached != null && cached.sourceHash == source.hash) return cached;
    final TeacherKey matched = await _teacherKeys.read(source, paper, standard: standard, cancel: cancel);
    await _store.write(paperHash, key, matched.toJson());
    return matched;
  }

  /// Runs every stage for one answer script against one question paper.
  ///
  /// Throws a [PipelineException] when a stage before marking fails, a
  /// [CancelledException] when cancelled. A marking failure does not throw:
  /// the assessment comes back with every answer read, no result, and a
  /// failed job saying why — marking again resumes where it stopped.
  ///
  /// [prepareOnly] stops before marking, so a class can read the next script
  /// while the current one is being marked.
  ///
  /// [backup] marks with the backup marking models only — while the first
  /// choice is out of allowance — every mark flagged for the teacher.
  Future<ExamAssessment> run({
    required SelectedDocument answerSheet,
    required SelectedDocument questionPaper,
    String guidance = '',
    Map<String, String> teacherTranscriptions = const <String, String>{},
    Map<String, String> teacherAssignments = const <String, String>{},
    List<Syllabus> syllabi = const <Syllabus>[],
    String? syllabusChoice,
    MarkingStandard standard = const MarkingStandard(),
    Moderation moderation = Moderation.none,
    void Function(ProcessingJob job)? onUpdate,
    CancellationToken? cancel,
    bool prepareOnly = false,
    bool backup = false,
  }) async {
    final MarkingSettings settings = _settings();
    final _Reporter job =
        _Reporter(ProcessingJob(jobId: jobIdFor(answerSheet, questionPaper), stage: ProcessingStage.uploaded), onUpdate);
    final String hash = answerSheet.contentHash;

    try {
      // 1. The question paper: the structural authority.
      final ({QuestionPaper paper, String key}) questions =
          await _stage(job, ProcessingStage.extractingQuestions, () => _questions(questionPaper, job, cancel));
      job.update(counts: job.counts.copyWith(questions: questions.paper.markable.length));
      job.warn(questions.paper.warnings);
      final ({Syllabus syllabus, String how})? syllabus = _syllabusFor(questions.paper, syllabi, syllabusChoice, job);

      // 2. Pages.
      final List<ExamPage> pages = await _stage(job, ProcessingStage.rendering, () => _render(answerSheet, job, cancel));
      job.update(counts: job.counts.copyWith(pagesTotal: pages.length, pagesDone: pages.length));

      // 3. Reading, whole pages at a time.
      final ({PageReadout readout, String key}) read =
          await _stage(job, ProcessingStage.readingPages, () => _read(answerSheet, pages, settings, job, cancel));
      job.warn(read.readout.warnings);
      final ExamDocument document = ExamDocument(
        documentId: hash,
        role: DocumentRole.answerSheet,
        filePath: answerSheet.filePath,
        fileName: answerSheet.fileName,
        source: answerSheet.source,
        pages: read.readout.pages,
      );
      job.update(counts: _countRegions(job.counts, document));
      final Map<String, HandwritingEvidence> handwriting =
          _withTeacherReadings(read.readout.handwriting, teacherTranscriptions);

      // 4. Answers matched to questions.
      final _Matched matched = await _stage(
        job,
        ProcessingStage.aligningQuestions,
        () => _match(
          document,
          handwriting,
          questions.paper,
          teacherTranscriptions,
          teacherAssignments,
          '${read.key}:${questions.key}:${StageStore.fingerprint(teacherTranscriptions)}'
              ':${StageStore.fingerprint(teacherAssignments)}',
          settings,
        ),
      );
      job.warn(matched.alignment.warnings);

      // 5. Each question's answer, cleaned.
      final EvidenceSet evidence = EvidenceSet(handwriting: matched.handwriting, visuals: read.readout.visuals);
      final Map<String, StudentAnswer> answers = await _stage(
        job,
        ProcessingStage.reconstructingAnswers,
        () async => EvidenceAnswerReconstructor(uncertainBelow: settings.uncertainBelow).reconstruct(
          document: matched.document,
          evidence: evidence,
          alignment: matched.alignment,
          paper: questions.paper,
        ),
      );

      ExamAssessment assessment = ExamAssessment(
        job: job.current,
        answerSheet: matched.document,
        questionPaper: questions.paper,
        evidence: evidence,
        alignment: matched.alignment,
        answers: answers,
        warnings: job.current.warnings,
        syllabus: syllabus == null ? null : (id: syllabus.syllabus.id, name: syllabus.syllabus.name, how: syllabus.how),
      );
      if (prepareOnly) return assessment;

      // 6–7. Marked by one model, then checked against the rules.
      try {
        final CorrectionResult result = await _stage(
          job,
          ProcessingStage.marking,
          () => _mark(assessment, questionPaper.contentHash, guidance, syllabus?.syllabus, standard, moderation,
              settings, job, cancel,
              backup: backup),
        );
        job.finish(
          result.needsReviewCount > 0 ? ProcessingStage.reviewRequired : ProcessingStage.completed,
          result.needsReviewCount > 0 ? '${result.needsReviewCount} question(s) need your review.' : 'Marked.',
        );
        assessment = assessment.copyWith(job: job.current, result: () => result, warnings: job.current.warnings);
      } on CorrectionException catch (error) {
        job.fail(ProcessingStage.marking, error.message);
        assessment = assessment.copyWith(
          job: job.current,
          warnings: <String>[
            ...job.current.warnings,
            'Marking stopped: ${error.message} Everything read from the script has been kept; '
                'marking again resumes where it stopped.',
          ],
        );
      }

      await _saveJob(hash, questionPaper.contentHash, job.current);
      return assessment;
    } on CancelledException {
      job.finish(ProcessingStage.cancelled, 'Cancelled.');
      await _saveJob(hash, questionPaper.contentHash, job.current);
      rethrow;
    } on AppException catch (error) {
      final ProcessingStage stage = job.current.stage;
      job.fail(stage, error.message);
      await _saveJob(hash, questionPaper.contentHash, job.current);
      if (error is PipelineException) rethrow;
      throw PipelineException(error.message, stage: stage.label);
    }
  }

  static String jobIdFor(SelectedDocument answers, SelectedDocument paper) =>
      '${answers.contentHash}_${paper.contentHash}';

  /// The last saved state of this pair of documents, for resuming.
  Future<ProcessingJob?> lastJob(SelectedDocument answers, SelectedDocument paper) async {
    final JsonMap? saved = await _store.read(answers.contentHash, 'job-${paper.contentHash}');
    return saved == null ? null : ProcessingJob.fromJson(saved);
  }

  Future<void> _saveJob(String hash, String paperHash, ProcessingJob job) async {
    try {
      await _store.write(hash, 'job-$paperHash', job.toJson());
    } on IOException {
      // The job record is a convenience; failing to save it loses nothing.
    }
  }

  // --------------------------------------------------------------------------
  // Stages
  // --------------------------------------------------------------------------

  Future<T> _stage<T>(_Reporter job, ProcessingStage stage, Future<T> Function() body) async {
    job.begin(stage);
    final T result = await body();
    job.complete(stage);
    return result;
  }

  Future<({QuestionPaper paper, String key})> _questions(
    SelectedDocument document,
    _Reporter job,
    CancellationToken? cancel,
  ) async {
    final String key = 'questions-${StageStore.fingerprint(<Object?>[_questionExtractor.fingerprint])}';
    final JsonMap? cached = await _store.read(document.contentHash, key);
    final QuestionPaper? restored = cached == null ? null : QuestionPaper.fromJson(cached);
    // What later stages are keyed on names this paper, not just how it was
    // read: the same script against another paper is matched and marked
    // afresh.
    final String identity = '${document.contentHash}:$key';
    if (restored != null && restored.markable.isNotEmpty) {
      job.reused(ProcessingStage.extractingQuestions);
      return (paper: restored, key: identity);
    }

    String? text;
    List<ExamPage> pages = const <ExamPage>[];
    if (document.source != DocumentSource.scanned && document.source != DocumentSource.image) {
      text = await _documents.textIfPresent(document.filePath);
    }
    if (text == null) pages = await _render(document, job, cancel);

    final QuestionPaper paper = await _questionExtractor.extract(
      QuestionPaperSourceData(document: document, text: text, pages: pages),
      onProgress: job.progress,
      cancel: cancel,
    );
    await _store.write(document.contentHash, key, paper.toJson());
    return (paper: paper, key: identity);
  }

  Future<List<ExamPage>> _render(SelectedDocument document, _Reporter job, CancellationToken? cancel) async {
    final String key = 'render-${StageStore.fingerprint(_renderer.fingerprint)}';
    // Rendered before, with every page image still there: the PDF need not
    // even be opened.
    final List<ExamPage> cached = readObjects(
      (await _store.read(document.contentHash, key))?['pages'],
      ExamPage.fromJson,
    );
    if (cached.isNotEmpty && cached.every((ExamPage p) => p.imagePath == null || File(p.imagePath!).existsSync())) {
      job.reused(ProcessingStage.rendering);
      return cached;
    }
    final Directory folder = await _store.folder(document.contentHash, key);
    try {
      final List<ExamPage> pages = await _renderer.render(
        document.filePath,
        documentId: document.contentHash,
        folder: folder,
        onPage: (int done, int total) => job.progress('Rendering page $done of $total…', done / total),
        cancel: cancel,
      );
      await _store.write(document.contentHash, key, <String, Object?>{
        'pages': <JsonMap>[for (final ExamPage page in pages) page.toJson()],
      });
      return pages;
    } on PipelineException {
      rethrow;
    } on CancelledException {
      rethrow;
    } on Object catch (error) {
      throw PipelineException('The ${document.role.label} could not be rendered: $error', stage: 'rendering');
    }
  }

  Future<({PageReadout readout, String key})> _read(
    SelectedDocument document,
    List<ExamPage> pages,
    MarkingSettings settings,
    _Reporter job,
    CancellationToken? cancel,
  ) async {
    final PageReader reader = _reader(settings);
    final String key = 'read-${StageStore.fingerprint(<Object?>[_renderer.fingerprint, reader.fingerprint])}';
    final PageReadout? cached = switch (await _store.read(document.contentHash, key)) {
      final JsonMap json => PageReadout.fromJson(json),
      null => null,
    };
    if (cached != null && cached.pages.length == pages.length) {
      job.reused(ProcessingStage.readingPages);
      return (readout: cached, key: key);
    }
    final PageReadout readout = await reader.read(
      pages,
      cropFolder: await _store.folder(document.contentHash, 'crops-${StageStore.fingerprint(key)}'),
      onProgress: (String message) => job.progress('$message…', 0.5),
      cancel: cancel,
    );
    // A page that could not be read is not saved as read: the next run asks
    // for the whole script again rather than marking around a gap.
    if (readout.models.length == pages.length) await _store.write(document.contentHash, key, readout.toJson());
    return (readout: readout, key: key);
  }

  /// Applies the teacher's corrected readings over the machine ones.
  Map<String, HandwritingEvidence> _withTeacherReadings(
    Map<String, HandwritingEvidence> evidence,
    Map<String, String> teacher,
  ) {
    if (teacher.isEmpty) return evidence;
    return <String, HandwritingEvidence>{
      for (final MapEntry<String, HandwritingEvidence> e in evidence.entries)
        e.key: teacher.containsKey(e.key) ? e.value.withTeacherText(teacher[e.key]) : e.value,
    };
  }

  Future<_Matched> _match(
    ExamDocument document,
    Map<String, HandwritingEvidence> handwriting,
    QuestionPaper paper,
    Map<String, String> teacherTranscriptions,
    Map<String, String> teacherAssignments,
    String upstream,
    MarkingSettings settings,
  ) async {
    final String key = 'alignment-${StageStore.fingerprint(<Object?>[matchingVersion, upstream])}';
    final JsonMap? cached = await _store.read(document.documentId, key);
    if (cached != null) {
      final ExamDocument? restored = ExamDocument.fromJson(readMap(cached['document']) ?? const <String, Object?>{});
      if (restored != null) {
        return _Matched(
          document: restored,
          handwriting: <String, HandwritingEvidence>{
            ...handwriting,
            for (final HandwritingEvidence e in readObjects(cached['splitEvidence'], HandwritingEvidence.fromJson))
              e.regionId: e,
          },
          alignment: AlignmentResult.fromJson(readMap(cached['alignment']) ?? const <String, Object?>{}),
        );
      }
    }

    BoundaryResult boundaries = _boundaries.detect(document, EvidenceSet(handwriting: handwriting), paper);
    // A block split at a label gets new regions, and the teacher may have
    // corrected one of those: their reading is applied, and the answers found
    // again from it.
    final Map<String, HandwritingEvidence> corrected =
        _withTeacherReadings(boundaries.evidence.handwriting, teacherTranscriptions);
    if (!identical(corrected, boundaries.evidence.handwriting)) {
      boundaries = _boundaries.detect(boundaries.document, EvidenceSet(handwriting: corrected), paper);
    }
    // The teacher's own choices of which writing answers which question come
    // last, over whatever was found.
    final AlignmentResult alignment = const TeacherAssignments().apply(
      _aligner.align(boundaries.segments, paper).withWarnings(boundaries.warnings),
      teacherAssignments,
      boundaries.document,
      paper,
    );
    final ExamDocument cropped = await _cropSplits(boundaries.document, boundaries.evidence.handwriting, key, settings);

    final Map<String, HandwritingEvidence> split = <String, HandwritingEvidence>{
      for (final MapEntry<String, HandwritingEvidence> e in boundaries.evidence.handwriting.entries)
        if (!handwriting.containsKey(e.key)) e.key: e.value,
    };
    await _store.write(document.documentId, key, <String, Object?>{
      'document': cropped.toJson(),
      'splitEvidence': <JsonMap>[for (final HandwritingEvidence e in split.values) e.toJson()],
      'alignment': alignment.toJson(),
    });
    return _Matched(document: cropped, handwriting: boundaries.evidence.handwriting, alignment: alignment);
  }

  /// A block split at a question label becomes new regions without crops of
  /// their own; the ones the marker should see as ink get them here.
  Future<ExamDocument> _cropSplits(
    ExamDocument document,
    Map<String, HandwritingEvidence> handwriting,
    String key,
    MarkingSettings settings,
  ) async {
    final Directory folder = await _store.folder(document.documentId, 'crops-${StageStore.fingerprint(key)}');
    final List<ExamPage> pages = <ExamPage>[];
    for (final ExamPage page in document.pages) {
      final String? image = page.imagePath;
      if (image == null || !page.regions.any((PageRegion r) => r.parentRegionId != null && r.cropPath == null)) {
        pages.add(page);
        continue;
      }
      final PageCropper cropper = PageCropper(image);
      final List<PageRegion> regions = <PageRegion>[];
      for (final PageRegion region in page.regions) {
        final bool wanted = region.parentRegionId != null &&
            region.cropPath == null &&
            (region.type.isVisual || (handwriting[region.regionId]?.confidence ?? 1) < settings.uncertainBelow);
        if (!wanted) {
          regions.add(region);
          continue;
        }
        final String file =
            '${folder.path}${Platform.pathSeparator}${region.regionId.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_')}.jpg';
        final String? crop = await cropper.crop(region.box, file);
        regions.add(region.copyWith(cropPath: () => crop));
      }
      pages.add(page.copyWith(regions: regions));
    }
    return document.withPages(pages);
  }

  /// The syllabus to mark against: the teacher's choice, or else the saved
  /// one that matches the paper.
  ({Syllabus syllabus, String how})? _syllabusFor(
    QuestionPaper paper,
    List<Syllabus> syllabi,
    String? choice,
    _Reporter job,
  ) {
    if (syllabi.isEmpty || choice == noSyllabus) return null;
    if (choice != null) {
      for (final Syllabus syllabus in syllabi) {
        if (syllabus.id == choice) return (syllabus: syllabus, how: 'chosen by you');
      }
    }
    final SyllabusMatch? match = const SyllabusMatcher().best(
      syllabi,
      title: paper.title,
      text: <String>[for (final Question question in paper.markable) question.questionText].join('\n'),
    );
    if (match == null) {
      job.warn(<String>[
        'No saved syllabus matches this question paper, so it was marked without one. '
            'Choose one on the question paper if it should be used.',
      ]);
      return null;
    }
    return (syllabus: match.syllabus, how: 'matched by ${match.reason}');
  }

  Future<CorrectionResult> _mark(
    ExamAssessment assessment,
    String paperHash,
    String guidance,
    Syllabus? syllabus,
    MarkingStandard standard,
    Moderation moderation,
    MarkingSettings settings,
    _Reporter job,
    CancellationToken? cancel, {
    bool backup = false,
  }) async {
    final QuestionPaper paper = assessment.questionPaper;
    final SyllabusIndex? index = syllabus == null ? null : SyllabusIndex(syllabus);
    SyllabusContext contextOf(Question question) =>
        index?.contextFor(question.questionText, markScheme: paper.markSchemeFor(question)) ?? SyllabusContext.none;
    final AnswerKey key = await _answerKey(
      paper,
      paperHash,
      contextOf,
      guidance: guidance,
      course: index?.courseHeader ?? '',
      standard: standard,
      job: job,
      cancel: cancel,
      prepare: !backup,
    );
    final bool typed = assessment.answerSheet.source == DocumentSource.textLayer;
    final String hash = assessment.answerSheet.documentId;
    List<MarkingTask> tasks = <MarkingTask>[
      for (final Question question in paper.markable)
        MarkingTask(
          question: question,
          section: paper.section(question.sectionId),
          answer: assessment.answers[question.questionId] ?? StudentAnswer.none(question.questionId),
          images: _imagesFor(assessment, question.questionId, settings),
          markScheme: paper.markSchemeFor(question),
          paperGuidance: paper.markingGuidance,
          choice: switch (paper.choicesOf(question.questionId)) {
            [final first, ...] => paper.describeChoice(first.choice),
            _ => '',
          },
          syllabus: contextOf(question).text,
          syllabusLabel: contextOf(question).label,
          syllabusFocus: contextOf(question).focus,
          syllabusCourse: index?.courseHeader ?? '',
          standard: standard,
          answerKey: paper.markSchemeFor(question).trim().isEmpty ? key.textFor(question.questionId) : '',
          answerKeySource: key.sourceFor(question.questionId) ?? AnswerKeySource.ai,
          keyOption: paper.markSchemeFor(question).trim().isEmpty ? key.optionFor(question.questionId) : null,
          expectedWords:
              paper.markSchemeFor(question).trim().isEmpty ? key.expectedWordsFor(question.questionId) : null,
        ),
    ];
    for (final MarkingHook hook in hooks) {
      tasks = await hook.beforeMarking(tasks, assessment);
    }
    final List<String> hookPrints = <String>[for (final MarkingHook hook in hooks) hook.fingerprint];

    String keyFor(MarkingTask task) => 'mark-${StageStore.fingerprint(<Object?>[
          _marker.fingerprint,
          guidance.trim(),
          typed,
          task.question.toJson(),
          task.markScheme,
          task.paperGuidance,
          task.choice,
          task.syllabus,
          task.syllabusCourse,
          task.answerKey,
          task.answerKeySource.name,
          // Only what changes the AI's judgement: rounding and penalties are
          // applied afterwards, to saved marks as well.
          if (standard.changesJudgement) standard.judgementKey,
          task.section?.toJson(),
          task.answer.toJson(),
          <String>[for (final MarkingImage image in task.images) image.regionId],
          hookPrints,
        ])}';

    final List<String> markers = settings.chain(ModelRole.marker);
    final List<String>? backupModels = backup ? markers.skip(1).toList() : null;
    if (backup && backupModels!.isEmpty) {
      throw const CorrectionException('No backup marking model is set, so marking waits for the first choice.');
    }

    final Map<String, QuestionResult> results = <String, QuestionResult>{};
    final List<MarkingTask> pending = <MarkingTask>[];
    // A multiple-choice answer the teacher's key settles without doubt is
    // marked here: no request, no wait.
    final KeyedMcqMarker keyed = KeyedMcqMarker(reviewThreshold: settings.reviewThreshold, standard: standard);
    for (final MarkingTask task in tasks) {
      if (keyed.mark(task) case final QuestionResult direct) {
        results[task.question.questionId] = direct;
        continue;
      }
      final JsonMap? cached = await _store.read(hash, keyFor(task));
      final QuestionResult? restored = cached == null ? null : QuestionResult.fromJson(cached);
      // A backup run keeps only backup marks, and a normal run only the first
      // choice's, so marking again once it is back replaces the backup's.
      if (restored != null && (restored.model.isEmpty || _isBackup(restored.model, markers) == backup)) {
        results[task.question.questionId] = restored;
      } else {
        pending.add(task);
      }
    }
    if (pending.isEmpty) job.reused(ProcessingStage.marking);

    // One script, one marker: a script resumed after an interruption is
    // finished by the model that began it.
    String? judge = judgeOf(results.values);
    final int chunk = settings.limitsForChain(backupModels ?? markers).questionsPerRequest;
    for (int start = 0; start < pending.length; start += chunk) {
      cancel?.throwIfCancelled();
      final List<MarkingTask> slice = pending.sublist(start, (start + chunk).clamp(0, pending.length));
      final List<QuestionResult> marked = (await _marker.mark(
        slice,
        guidance: guidance,
        typedAnswerSheet: typed,
        judge: judge,
        models: backupModels,
        onProgress: (String message, double fraction) =>
            job.progress(message, (results.length + fraction * slice.length) / tasks.length),
        cancel: cancel,
      ))
          .map((QuestionResult r) => flagBackup(r, markers))
          .toList();
      for (int i = 0; i < slice.length; i++) {
        results[slice[i].question.questionId] = marked[i];
        // An unmarked question is not saved, so the next attempt retries it.
        if (marked[i].model.isNotEmpty || slice[i].answer.isEmpty) {
          await _store.write(hash, keyFor(slice[i]), marked[i].toJson());
        }
      }
      judge ??= judgeOf(marked);
      job.update(counts: job.counts.copyWith(questionsMarked: results.length));
    }

    // The standard's arithmetic — rounding, the mark step, penalties — on
    // every mark, fresh or saved.
    final MarkingRules rules =
        MarkingRules(standard, defaultReviewThreshold: settings.reviewThreshold, moderation: moderation);
    // Which options of an OR count is decided from the script: the first
    // answered.
    final Map<String, int> firstSeen = <String, int>{
      for (final MapEntry<String, StudentAnswer> entry in assessment.answers.entries)
        if (!entry.value.isEmpty)
          if (_firstPosition(assessment, entry.value) case final int at) entry.key: at,
    };
    final List<QuestionResult> ordered = const ChoiceResolver().resolve(
      paper,
      <QuestionResult>[
        for (final MarkingTask task in tasks)
          rules.apply(results[task.question.questionId]!.copyWith(syllabusReference: task.syllabusLabel), task),
      ],
      firstSeen,
    );
    final Set<String> models = <String>{
      for (final QuestionResult q in ordered)
        if (q.model.isNotEmpty) q.model,
    };
    return CorrectionResult.fromQuestions(
      ordered,
      model: models.join(', '),
      totalRounding: standard.totalRounding,
      standard: standard.summary,
    );
  }

  static bool _isBackup(String model, List<String> markers) =>
      model.isNotEmpty && model != KeyedMcqMarker.markedBy && markers.isNotEmpty && model != markers.first;

  /// A mark given by a backup marking model, flagged so the teacher checks
  /// it.
  static QuestionResult flagBackup(QuestionResult result, List<String> markers) {
    if (!_isBackup(result.model, markers)) return result;
    final String reason = 'Marked by the backup model ${result.model} because ${markers.first} was not '
        'available — check this mark.';
    if (result.reviewReasons.contains(reason)) return result;
    return result.copyWith(needsReview: true, reviewReasons: <String>[...result.reviewReasons, reason]);
  }

  /// The model that marked [results]: the most frequent one, should an older
  /// run have mixed them. Null before anything was marked by a model.
  static String? judgeOf(Iterable<QuestionResult> results) {
    final Map<String, int> counts = <String, int>{};
    for (final QuestionResult result in results) {
      // Settled by the teacher's key, not by a model.
      if (result.model.isEmpty || result.model == KeyedMcqMarker.markedBy) continue;
      counts[result.model] = (counts[result.model] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    return counts.entries.reduce((MapEntry<String, int> a, MapEntry<String, int> b) => b.value > a.value ? b : a).key;
  }

  /// The paper's answer key: prepared once from the questions alone — never
  /// from an answer — and shared by every script of the paper, with the
  /// teacher's corrections over it. A key that cannot be prepared is not
  /// fatal: the paper is marked without one, and the teacher told.
  Future<AnswerKey> _answerKey(
    QuestionPaper paper,
    String paperHash,
    SyllabusContext Function(Question question) contextOf, {
    required String guidance,
    required String course,
    required MarkingStandard standard,
    required _Reporter job,
    CancellationToken? cancel,
    bool prepare = true,
  }) async {
    final TeacherWorkStore work = TeacherWorkStore(_store);
    final Map<String, String> edits = await work.answerKeyEdits(paperHash);
    final Map<String, TeacherKeyEntry> own = await _teacherKeyFor(paper, paperHash, work, standard, job, cancel);
    final AnswerKeyEngine? engine = _answerKeys;
    // The AI prepares a key only for questions nothing else covers: not the
    // printed scheme, and not the teacher's own key.
    final List<AnswerKeyTask> tasks = <AnswerKeyTask>[
      for (final Question question in paper.markable)
        if (paper.markSchemeFor(question).trim().isEmpty &&
            (question.maximumMarks ?? 0) > 0 &&
            !own.containsKey(question.questionId))
          AnswerKeyTask(
            question: question,
            section: paper.section(question.sectionId),
            syllabus: contextOf(question).text,
            choice: switch (paper.choicesOf(question.questionId)) {
              [final first, ...] => paper.describeChoice(first.choice),
              _ => '',
            },
          ),
    ];
    if (engine == null || tasks.isEmpty) return AnswerKey(teacher: own, edits: edits);

    final String cacheKey = 'answer-key-${StageStore.fingerprint(<Object?>[
          engine.fingerprint,
          guidance.trim(),
          course,
          standard.judgementKey,
          for (final AnswerKeyTask task in tasks) <Object?>[task.question.toJson(), task.syllabus, task.choice],
        ])}';
    final JsonMap? cached = await _store.read(paperHash, cacheKey);
    Map<String, AnswerKeyEntry> entries = AnswerKey.entriesFromJson(cached);
    if (cached == null && !prepare) {
      job.warn(<String>[
        'No answer key had been prepared for this paper yet, so the backup model marked without one.',
      ]);
      return AnswerKey(teacher: own, edits: edits);
    }
    if (cached == null) {
      try {
        entries = await engine.prepare(
          tasks,
          guidance: guidance,
          course: course,
          standard: standard,
          onProgress: (String message, double fraction) => job.progress(message, 0),
          cancel: cancel,
        );
        if (entries.isNotEmpty) await _store.write(paperHash, cacheKey, AnswerKey(entries: entries).toJson());
      } on CorrectionException catch (error) {
        job.warn(<String>[
          'The answer key could not be prepared (${error.message}); questions without a printed mark scheme '
              'were marked without one.',
        ]);
        return AnswerKey(teacher: own, edits: edits);
      }
    }
    final AnswerKey key = AnswerKey(entries: entries, teacher: own, edits: edits);
    try {
      await work.saveAnswerKey(paperHash, key.toJson());
    } on IOException {
      // Only the teacher's view of the key; marking has what it needs.
    }
    return key;
  }

  /// The teacher's own key, for the questions it may cover: those the paper
  /// prints no scheme for. A key saved before the paper could be read is
  /// matched now, and saved matched.
  Future<Map<String, TeacherKeyEntry>> _teacherKeyFor(
    QuestionPaper paper,
    String paperHash,
    TeacherWorkStore work,
    MarkingStandard standard,
    _Reporter job,
    CancellationToken? cancel,
  ) async {
    TeacherKey? key;
    try {
      key = TeacherKey.fromJson(await work.teacherKey(paperHash));
    } on IOException {
      return const <String, TeacherKeyEntry>{};
    }
    if (key == null) return const <String, TeacherKeyEntry>{};
    if (!key.matched) {
      try {
        job.progress('Matching your answer key to the questions…', 0);
        key = await alignTeacherKey(
          paper,
          paperHash,
          TeacherKeySource(fileName: key.fileName, hash: key.sourceHash, text: key.text),
          standard: standard,
          cancel: cancel,
        );
        await work.saveTeacherKey(paperHash, key.toJson());
      } on CorrectionException catch (error) {
        job.warn(<String>[
          'Your answer key could not be matched to the questions (${error.message}); the paper was marked without it.',
        ]);
        return const <String, TeacherKeyEntry>{};
      }
    }
    return <String, TeacherKeyEntry>{
      for (final Question question in paper.markable)
        if (key.entries[question.questionId] case final TeacherKeyEntry entry
            when !entry.isEmpty && paper.markSchemeFor(question).trim().isEmpty)
          question.questionId: entry,
    };
  }

  /// Where an answer begins on the script, as a sortable number.
  static int? _firstPosition(ExamAssessment assessment, StudentAnswer answer) {
    int? first;
    for (final String id in answer.regionIds) {
      final PageRegion? region = assessment.region(id);
      if (region == null) continue;
      final int at = region.pageNumber * 100000 + region.readingOrder;
      if (first == null || at < first) first = at;
    }
    return first;
  }

  /// What the marker sees besides text: every drawing, and the writing that
  /// could not be read with confidence.
  List<MarkingImage> _imagesFor(ExamAssessment assessment, String questionId, MarkingSettings settings) {
    final StudentAnswer? answer = assessment.answers[questionId];
    if (answer == null || answer.isEmpty) return const <MarkingImage>[];
    final List<MarkingImage> images = <MarkingImage>[];

    void add(String regionId, String reason) {
      if (images.length >= imagesPerQuestion) return;
      final String? crop = assessment.region(regionId)?.cropPath;
      if (crop == null || images.any((MarkingImage i) => i.regionId == regionId)) return;
      images.add(MarkingImage(regionId: regionId, path: crop, reason: reason));
    }

    for (final String id in answer.visualRegionIds) {
      add(id, assessment.region(id)?.type.displayName.toLowerCase() ?? 'visual');
    }
    for (final TextEvidenceItem item in answer.textEvidence) {
      if (item.source == ReadingSource.textLayer || item.source == ReadingSource.teacher) continue;
      if (item.type == RegionType.printedText) continue;
      if (item.illegible || item.confidence < settings.uncertainBelow || item.possiblyStruck) {
        add(item.regionId, item.possiblyStruck ? 'may be crossed out' : 'uncertain reading');
      }
    }
    return images;
  }

  ProcessingCounts _countRegions(ProcessingCounts counts, ExamDocument document) {
    int of(RegionType type) => document.countOf(type);
    return counts.copyWith(
      answerRegions: document.regions.where((PageRegion r) => r.type.isAnswerContent).length,
      handwritingRegions:
          document.regions.where((PageRegion r) => r.type.isTextual && r.type.isAnswerContent).length,
      diagrams: of(RegionType.diagram),
      graphs: of(RegionType.graph),
      tables: of(RegionType.table),
      equations: of(RegionType.equation),
      crossedOut: of(RegionType.crossedOut),
    );
  }
}

class _Matched {
  const _Matched({required this.document, required this.handwriting, required this.alignment});

  final ExamDocument document;
  final Map<String, HandwritingEvidence> handwriting;
  final AlignmentResult alignment;
}

/// Tracks the job and tells the listener about every change.
class _Reporter {
  _Reporter(this.current, this._listener);

  ProcessingJob current;
  final void Function(ProcessingJob job)? _listener;

  ProcessingCounts get counts => current.counts;

  /// The whole run, stamped on every change so the job saved at any point
  /// says how long the run had taken.
  final Stopwatch _run = Stopwatch()..start();

  void _emit(ProcessingJob job) {
    current = job.copyWith(elapsed: _run.elapsed);
    _listener?.call(current);
  }

  final Map<ProcessingStage, Stopwatch> _clocks = <ProcessingStage, Stopwatch>{};

  void begin(ProcessingStage stage) {
    _clocks[stage] = Stopwatch()..start();
    _emit(current.copyWith(stage: stage, stageFraction: 0, message: '${stage.label}…'));
  }

  void progress(String message, double fraction) => _emit(current.copyWith(message: message, stageFraction: fraction));

  void complete(ProcessingStage stage) => _emit(
        current.copyWith(
          completedStages: <ProcessingStage>{...current.completedStages, stage},
          stageFraction: 1,
          durations: <ProcessingStage, Duration>{
            ...current.durations,
            if (_clocks.remove(stage) case final Stopwatch clock) stage: clock.elapsed,
          },
        ),
      );

  void reused(ProcessingStage stage) => _emit(
        current.copyWith(
          reusedStages: <ProcessingStage>{...current.reusedStages, stage},
          message: '${stage.label} — reused from the last run.',
        ),
      );

  void update({ProcessingCounts? counts}) => _emit(current.copyWith(counts: counts));

  void warn(List<String> warnings) {
    if (warnings.isEmpty) return;
    _emit(current.copyWith(
      warnings: <String>[
        ...current.warnings,
        for (final String w in warnings)
          if (!current.warnings.contains(w)) w,
      ],
    ));
  }

  void finish(ProcessingStage stage, String message) => _emit(current.copyWith(stage: stage, message: message));

  void fail(ProcessingStage stage, String message) => _emit(
        current.copyWith(
          stage: ProcessingStage.failed,
          failedStage: () => stage,
          error: () => message,
          message: message,
        ),
      );
}
