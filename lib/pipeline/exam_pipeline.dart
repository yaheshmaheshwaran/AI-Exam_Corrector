import 'dart:io';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/cache/artifact_store.dart';
import 'package:exam_corrector/pipeline/alignment/teacher_assignments.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/choice_resolver.dart';
import 'package:exam_corrector/pipeline/reconstruction/evidence_answer_reconstructor.dart';
import 'package:exam_corrector/pipeline/recognition/ensemble_handwriting_recognizer.dart';
import 'package:exam_corrector/pipeline/recognition/equation_promoter.dart';
import 'package:exam_corrector/pipeline/visual/visual_evidence_engine.dart';
import 'package:exam_corrector/services/pdf_service.dart';

/// Runs the understanding pipeline, stage by stage, with every stage cached.
///
/// ```
/// question paper → structure
/// answer sheet → pages → regions → handwriting → answers aligned to
///   questions → visual evidence → reconstructed answers → marks
/// ```
///
/// Each stage's output is stored under a key built from its inputs, so:
/// - re-running an unchanged correction reuses everything;
/// - a correction interrupted at marking resumes at marking;
/// - a teacher's correction to one transcription re-marks only the question
///   it belongs to, because only that question's answer changed.
class ExamPipeline {
  ExamPipeline({
    required AppConfig Function() config,
    required ArtifactStore store,
    required DocumentRenderer renderer,
    required TextLayerReader textLayer,
    required PageAnalyzer pageAnalyzer,
    required RegionDetector regionDetector,
    required RegionDetector textLayerDetector,
    required RegionCropper? cropper,
    required HandwritingRecognizer recognizer,
    required VisualEvidenceEngine visuals,
    required String visualFingerprint,
    required QuestionPaperExtractor questionExtractor,
    required AnswerBoundaryDetector boundaries,
    required QuestionAligner aligner,
    required MarkingEngine marker,
    PdfService pdf = const PdfService(),
  })  : _config = config,
        _store = store,
        _renderer = renderer,
        _textLayer = textLayer,
        _pageAnalyzer = pageAnalyzer,
        _regionDetector = regionDetector,
        _textLayerDetector = textLayerDetector,
        _cropper = cropper,
        _recognizer = recognizer,
        _visuals = visuals,
        _visualFingerprint = visualFingerprint,
        _questionExtractor = questionExtractor,
        _boundaries = boundaries,
        _aligner = aligner,
        _marker = marker,
        _pdf = pdf;

  final AppConfig Function() _config;
  final ArtifactStore _store;
  final DocumentRenderer _renderer;
  final TextLayerReader _textLayer;
  final PageAnalyzer _pageAnalyzer;
  final RegionDetector _regionDetector;
  final RegionDetector _textLayerDetector;
  final RegionCropper? _cropper;
  final HandwritingRecognizer _recognizer;
  final VisualEvidenceEngine _visuals;
  final String _visualFingerprint;
  final QuestionPaperExtractor _questionExtractor;
  final AnswerBoundaryDetector _boundaries;
  final QuestionAligner _aligner;
  final MarkingEngine _marker;
  final PdfService _pdf;
  final EquationPromoter _equations = const EquationPromoter();

  ArtifactStore get store => _store;

  /// Images attached per question for the marker, at most.
  static const int imagesPerQuestion = 6;

  /// Runs every stage for one answer sheet against one question paper.
  ///
  /// Throws a [PipelineException] when a stage before marking fails, a
  /// [CancelledException] when cancelled. A marking failure does not throw:
  /// the returned assessment carries every extracted answer, no result, and a
  /// failed job saying why.
  Future<ExamAssessment> run({
    required SelectedDocument answerSheet,
    required SelectedDocument questionPaper,
    String guidance = '',
    Map<String, String> teacherTranscriptions = const <String, String>{},
    Map<String, String> teacherAssignments = const <String, String>{},
    void Function(ProcessingJob job)? onUpdate,
    CancellationToken? cancel,
  }) async {
    final _Reporter job = _Reporter(
      ProcessingJob(
        jobId: jobIdFor(answerSheet, questionPaper),
        stage: ProcessingStage.uploaded,
      ),
      onUpdate,
    );
    final String hash = answerSheet.contentHash;

    try {
      // 1. The question paper: the structural authority.
      final ({QuestionPaper paper, String key}) questions =
          await _stage(job, ProcessingStage.extractingQuestions, () =>
              _questions(questionPaper, job, cancel));
      job.update(counts: job.counts.copyWith(questions: questions.paper.markable.length));
      job.warn(questions.paper.warnings);

      // 2. Render.
      final ({ExamDocument document, String key}) rendered =
          await _stage(job, ProcessingStage.rendering, () =>
              _render(answerSheet, job, cancel));
      job.update(
        counts: job.counts.copyWith(
          pagesTotal: rendered.document.pageCount,
          pagesDone: rendered.document.pageCount,
        ),
      );

      // 3. Stage-one page analysis.
      final Map<int, PageRoute> routes = await _stage(
        job,
        ProcessingStage.analyzingPages,
        () async => <int, PageRoute>{
          for (final ExamPage page in rendered.document.pages)
            page.pageNumber: _pageAnalyzer.route(page),
        },
      );

      // 4. Regions.
      final _Detected detected = await _stage(
        job,
        ProcessingStage.detectingRegions,
        () => _detect(rendered.document, rendered.key, routes, job, cancel),
      );
      job.update(counts: _countRegions(job.counts, detected.document));

      // 5. Handwriting.
      final ({Map<String, HandwritingEvidence> evidence, String key}) read =
          await _stage(job, ProcessingStage.recognizingHandwriting, () =>
              _recognize(detected, job, cancel));
      final Map<String, HandwritingEvidence> handwriting =
          _withTeacherReadings(read.evidence, teacherTranscriptions);

      // 6. Boundaries and alignment.
      final _Aligned aligned = await _stage(
        job,
        ProcessingStage.aligningQuestions,
        () => _align(
          detected.document,
          handwriting,
          questions.paper,
          teacherTranscriptions,
          teacherAssignments,
          '${read.key}:${questions.key}:${ArtifactStore.fingerprint(teacherTranscriptions)}'
              ':${ArtifactStore.fingerprint(teacherAssignments)}',
        ),
      );
      job.warn(aligned.alignment.warnings);

      // 7. Visual evidence.
      final Map<String, VisualEvidence> visuals = await _stage(
        job,
        ProcessingStage.analyzingVisuals,
        () => _analyzeVisuals(aligned, questions.paper, job, cancel),
      );

      // 8. Reconstruction.
      final EvidenceSet evidence =
          EvidenceSet(handwriting: aligned.handwriting, visuals: visuals);
      final Map<String, StudentAnswer> answers = await _stage(
        job,
        ProcessingStage.reconstructingAnswers,
        () async => EvidenceAnswerReconstructor(
          uncertainBelow: _config().ocrConfidenceThreshold,
        ).reconstruct(
          document: aligned.document,
          evidence: evidence,
          alignment: aligned.alignment,
          paper: questions.paper,
        ),
      );

      ExamAssessment assessment = ExamAssessment(
        job: job.current,
        answerSheet: aligned.document,
        questionPaper: questions.paper,
        evidence: evidence,
        alignment: aligned.alignment,
        answers: answers,
        warnings: job.current.warnings,
      );

      // 9. Marking.
      try {
        final CorrectionResult result = await _stage(
          job,
          ProcessingStage.marking,
          () => _mark(assessment, guidance, job, cancel),
        );
        job.finish(
          result.needsReviewCount > 0
              ? ProcessingStage.reviewRequired
              : ProcessingStage.completed,
          result.needsReviewCount > 0
              ? '${result.needsReviewCount} question(s) need your review.'
              : 'Marked.',
        );
        assessment = assessment.copyWith(
          job: job.current,
          result: () => result,
          warnings: job.current.warnings,
        );
      } on CorrectionException catch (error) {
        job.fail(ProcessingStage.marking, error.message);
        assessment = assessment.copyWith(
          job: job.current,
          warnings: <String>[
            ...job.current.warnings,
            'Marking stopped: ${error.message} Everything read from the paper '
                'has been kept; marking again resumes where it stopped.',
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
  Future<ProcessingJob?> lastJob(
    SelectedDocument answers,
    SelectedDocument paper,
  ) async {
    final JsonMap? saved = await _store.read(
      answers.contentHash,
      'job-${paper.contentHash}',
    );
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

  Future<T> _stage<T>(
    _Reporter job,
    ProcessingStage stage,
    Future<T> Function() body,
  ) async {
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
    final String key =
        'questions-${ArtifactStore.fingerprint(<Object?>[_questionExtractor.fingerprint])}';
    final JsonMap? cached = await _store.read(document.contentHash, key);
    final QuestionPaper? restored =
        cached == null ? null : QuestionPaper.fromJson(cached);
    // What later stages are keyed on names this paper, not just how it was
    // read: the same answer sheet against another paper must be aligned and
    // marked afresh.
    final String identity = '${document.contentHash}:$key';
    if (restored != null && restored.markable.isNotEmpty) {
      job.reused(ProcessingStage.extractingQuestions);
      return (paper: restored, key: identity);
    }

    String? text;
    List<ExamPage> pages = const <ExamPage>[];
    if (document.source != DocumentSource.scanned &&
        document.source != DocumentSource.image) {
      text = await _pdf.extractTextIfPresent(document.filePath);
    }
    if (text == null) {
      final ({ExamDocument document, String key}) rendered =
          await _render(document, job, cancel);
      pages = rendered.document.pages;
    }

    final QuestionPaper paper = await _questionExtractor.extract(
      QuestionPaperSourceData(document: document, text: text, pages: pages),
      onProgress: job.progress,
      cancel: cancel,
    );
    await _store.write(document.contentHash, key, paper.toJson());
    return (paper: paper, key: identity);
  }

  Future<({ExamDocument document, String key})> _render(
    SelectedDocument document,
    _Reporter job,
    CancellationToken? cancel,
  ) async {
    final String key =
        'render-${ArtifactStore.fingerprint(<Object?>[_renderer.fingerprint])}';
    final JsonMap? cached = await _store.read(document.contentHash, key);
    final ExamDocument? restored =
        cached == null ? null : ExamDocument.fromJson(cached);
    if (restored != null && _imagesExist(restored)) {
      if (document.role == DocumentRole.answerSheet) {
        job.reused(ProcessingStage.rendering);
      }
      return (document: restored, key: key);
    }

    try {
      final ExamDocument rendered = await _renderer.render(
        document,
        outputDirectory: await _store.folder(document.contentHash, key),
        onProgress: job.progress,
        cancel: cancel,
      );
      await _store.write(document.contentHash, key, rendered.toJson());
      return (document: rendered, key: key);
    } on OcrException catch (error) {
      if (!error.sidecarUnavailable ||
          document.source != DocumentSource.textLayer) {
        throw PipelineException(
          document.source == DocumentSource.textLayer
              ? error.message
              : 'The ${document.role.label} is a scan, and rendering it needs '
                  'the local recogniser, which is unavailable: '
                  '${error.message}',
          stage: 'rendering',
        );
      }
      // A typed document can still be understood from its text layer alone;
      // the only loss is the page image beside the evidence.
      job.warn(<String>[
        'Page images are unavailable (${error.message}), so evidence is shown '
            'as text only.',
      ]);
      return (document: await _textOnly(document), key: '$key-text');
    }
  }

  Future<ExamDocument> _textOnly(SelectedDocument document) async {
    final List<TextLayerPage> layer = await _textLayer.read(document.filePath);
    return ExamDocument(
      documentId: document.contentHash,
      role: document.role,
      filePath: document.filePath,
      fileName: document.fileName,
      source: document.source,
      pages: <ExamPage>[
        for (final TextLayerPage page in layer)
          ExamPage(
            pageId: ExamPage.idFor(document.contentHash, page.pageNumber),
            pageNumber: page.pageNumber,
            width: page.width.round(),
            height: page.height.round(),
            hasTextLayer: page.lines.isNotEmpty,
            textLayerText: page.text,
            isBlank: page.lines.isEmpty,
          ),
      ],
    );
  }

  bool _imagesExist(ExamDocument document) => document.pages.every(
        (ExamPage page) =>
            page.imagePath == null || File(page.imagePath!).existsSync(),
      );

  Future<_Detected> _detect(
    ExamDocument document,
    String renderKey,
    Map<int, PageRoute> routes,
    _Reporter job,
    CancellationToken? cancel,
  ) async {
    final String key = 'regions-${ArtifactStore.fingerprint(<Object?>[
      renderKey,
      _regionDetector.fingerprint,
      _textLayerDetector.fingerprint,
      _cropper != null,
    ])}';
    final JsonMap? cached = await _store.read(document.documentId, key);
    if (cached != null) {
      final ExamDocument? restored = ExamDocument.fromJson(
        readMap(cached['document']) ?? const <String, Object?>{},
      );
      if (restored != null) {
        job.reused(ProcessingStage.detectingRegions);
        job.warn(readStringList(cached['warnings']));
        return _Detected(
          document: restored,
          readings: <String, HandwritingReading>{
            for (final MapEntry<String, Object?> e
                in (readMap(cached['readings']) ?? const <String, Object?>{}).entries)
              if (readMap(e.value) case final JsonMap json)
                if (HandwritingReading.fromJson(json) case final HandwritingReading r)
                  e.key: r,
          },
          key: key,
        );
      }
    }

    List<ExamPage> byRoute(PageRoute route) => document.pages
        .where((ExamPage page) => routes[page.pageNumber] == route)
        .toList();

    final Map<int, ExamPage> pages = <int, ExamPage>{
      for (final ExamPage page in document.pages) page.pageNumber: page,
    };
    final Map<String, HandwritingReading> readings = <String, HandwritingReading>{};
    final List<String> warnings = <String>[];

    for (final ExamPage page in byRoute(PageRoute.skip)) {
      pages[page.pageNumber] = page.copyWith(isBlank: true, regions: const <PageRegion>[]);
    }

    final List<ExamPage> typed = byRoute(PageRoute.textLayer);
    if (typed.isNotEmpty) {
      final RegionDetection result = await _textLayerDetector.detect(
        document,
        typed,
        cancel: cancel,
      );
      _merge(result, pages, readings, warnings);
    }

    final List<ExamPage> scanned = byRoute(PageRoute.detect);
    if (scanned.isNotEmpty) {
      final RegionDetection result = await _regionDetector.detect(
        document,
        scanned,
        onProgress: job.progress,
        cancel: cancel,
      );
      _merge(result, pages, readings, warnings);
    }

    ExamDocument updated = document.withPages(
      <ExamPage>[for (final ExamPage page in document.pages) pages[page.pageNumber]!],
    );
    updated = await _crop(updated, key, warnings);

    job.warn(warnings);
    await _store.write(document.documentId, key, <String, Object?>{
      'document': updated.toJson(),
      'readings': <String, Object?>{
        for (final MapEntry<String, HandwritingReading> e in readings.entries)
          e.key: e.value.toJson(),
      },
      'warnings': warnings,
    });
    return _Detected(document: updated, readings: readings, key: key);
  }

  void _merge(
    RegionDetection result,
    Map<int, ExamPage> pages,
    Map<String, HandwritingReading> readings,
    List<String> warnings,
  ) {
    for (final ExamPage page in result.pages) {
      pages[page.pageNumber] = page;
    }
    readings.addAll(result.readings);
    warnings.addAll(result.warnings);
  }

  /// Cuts every region lacking a crop out of its page.
  Future<ExamDocument> _crop(
    ExamDocument document,
    String key,
    List<String> warnings,
  ) async {
    final RegionCropper? cropper = _cropper;
    if (cropper == null) return document;

    final Directory folder =
        await _store.folder(document.documentId, 'crops-${ArtifactStore.fingerprint(key)}');
    final List<ExamPage> pages = <ExamPage>[];
    for (final ExamPage page in document.pages) {
      final List<PageRegion> needing = page.regions
          .where((PageRegion r) => r.cropPath == null && !r.box.isEmpty)
          .toList();
      if (!page.hasImage || needing.isEmpty) {
        pages.add(page);
        continue;
      }
      try {
        final Map<String, String> crops =
            await cropper.crop(page, needing, outputDirectory: folder);
        pages.add(page.copyWith(regions: <PageRegion>[
          for (final PageRegion region in page.regions)
            crops[region.regionId] == null
                ? region
                : region.copyWith(cropPath: () => crops[region.regionId]),
        ]));
      } on AppException catch (error) {
        warnings.add('Page ${page.pageNumber}: regions could not be cropped '
            '(${error.message}); the whole page is used instead.');
        pages.add(page);
      }
    }
    return document.withPages(pages);
  }

  Future<({Map<String, HandwritingEvidence> evidence, String key})> _recognize(
    _Detected detected,
    _Reporter job,
    CancellationToken? cancel,
  ) async {
    final String key = 'handwriting-${ArtifactStore.fingerprint(<Object?>[
      detected.key,
      _recognizer.fingerprint,
    ])}';
    final String hash = detected.document.documentId;
    final JsonMap? cached = await _store.read(hash, key);
    if (cached != null) {
      final Map<String, HandwritingEvidence> previous = <String, HandwritingEvidence>{
        for (final HandwritingEvidence e
            in readObjects(cached['evidence'], HandwritingEvidence.fromJson))
          e.regionId: e,
      };
      // Regions that missed a reading because an engine was unreachable get
      // another attempt; everything else is reused as it is.
      final List<PageRegion> retry = <PageRegion>[
        for (final PageRegion region in detected.document.regions)
          if (previous[region.regionId] case final HandwritingEvidence e
              when EnsembleHandwritingRecognizer.retryable(e))
            region,
      ];
      if (retry.isEmpty) {
        job.reused(ProcessingStage.recognizingHandwriting);
        return (evidence: previous, key: key);
      }
      final Map<String, HandwritingEvidence> again = await _recognizer.recognize(
        detected.document,
        retry,
        priorReadings: detected.readings,
        onProgress: job.progress,
        cancel: cancel,
      );
      final Map<String, HandwritingEvidence> merged = <String, HandwritingEvidence>{
        ...previous,
        ...again,
      };
      await _store.write(hash, key, <String, Object?>{
        'evidence': <JsonMap>[
          for (final HandwritingEvidence e in merged.values) e.toJson(),
        ],
      });
      return (evidence: merged, key: key);
    }

    final List<PageRegion> regions = <PageRegion>[
      for (final PageRegion region in detected.document.regions)
        if ((region.type.isTextual || region.type == RegionType.unknown) &&
            region.type != RegionType.header &&
            region.type != RegionType.footer)
          region,
    ];
    job.update(
      counts: job.counts.copyWith(
        handwritingRegions: regions
            .where((PageRegion r) => r.origin != RegionOrigin.textLayer)
            .length,
      ),
    );

    final Map<String, HandwritingEvidence> evidence =
        regions.isEmpty
            ? <String, HandwritingEvidence>{}
            : Map<String, HandwritingEvidence>.of(
                await _recognizer.recognize(
                  detected.document,
                  regions,
                  priorReadings: detected.readings,
                  onProgress: job.progress,
                  cancel: cancel,
                ),
              );

    // Readings made during detection of regions nothing else reads — an
    // equation's transcription, say — are kept as evidence too.
    detected.readings.forEach((String id, HandwritingReading reading) {
      evidence.putIfAbsent(
        id,
        () => HandwritingEvidence(regionId: id, readings: <HandwritingReading>[reading]),
      );
    });

    await _store.write(hash, key, <String, Object?>{
      'evidence': <JsonMap>[
        for (final HandwritingEvidence e in evidence.values) e.toJson(),
      ],
    });
    return (evidence: evidence, key: key);
  }

  Map<String, HandwritingEvidence> _withTeacherReadings(
    Map<String, HandwritingEvidence> evidence,
    Map<String, String> teacher,
  ) {
    if (teacher.isEmpty) return evidence;
    return <String, HandwritingEvidence>{
      for (final MapEntry<String, HandwritingEvidence> e in evidence.entries)
        e.key: teacher.containsKey(e.key)
            ? e.value.withTeacherText(teacher[e.key])
            : e.value,
    };
  }

  Future<_Aligned> _align(
    ExamDocument document,
    Map<String, HandwritingEvidence> handwriting,
    QuestionPaper paper,
    Map<String, String> teacherTranscriptions,
    Map<String, String> teacherAssignments,
    String upstream,
  ) async {
    // The version changes whenever boundary or alignment logic does: the
    // stage is deterministic, so a cached result is only stale when the code
    // that produced it has changed.
    final String key =
        'alignment-${ArtifactStore.fingerprint(<Object?>['align:v5', upstream])}';
    final JsonMap? cached = await _store.read(document.documentId, key);
    if (cached != null) {
      final ExamDocument? restored =
          ExamDocument.fromJson(readMap(cached['document']) ?? const <String, Object?>{});
      if (restored != null) {
        return _Aligned(
          document: restored,
          handwriting: <String, HandwritingEvidence>{
            ...handwriting,
            for (final HandwritingEvidence e
                in readObjects(cached['splitEvidence'], HandwritingEvidence.fromJson))
              e.regionId: e,
          },
          alignment: AlignmentResult.fromJson(
            readMap(cached['alignment']) ?? const <String, Object?>{},
          ),
          key: key,
        );
      }
    }

    BoundaryResult boundaries = _boundaries.detect(
      document,
      EvidenceSet(handwriting: handwriting),
      paper,
    );
    // A block split at a label gets new regions, and the teacher may have
    // corrected one of those. Their reading is applied, and the answers are
    // found again from it.
    final Map<String, HandwritingEvidence> corrected = _withTeacherReadings(
      boundaries.evidence.handwriting,
      teacherTranscriptions,
    );
    if (!identical(corrected, boundaries.evidence.handwriting)) {
      boundaries = _boundaries.detect(
        boundaries.document,
        EvidenceSet(handwriting: corrected),
        paper,
      );
    }
    // The teacher's own choices of which writing answers which question
    // come last, over whatever was found.
    final AlignmentResult alignment = const TeacherAssignments().apply(
      _aligner.align(boundaries.segments, paper).withWarnings(boundaries.warnings),
      teacherAssignments,
      boundaries.document,
      paper,
    );

    // Working inside the answers becomes equation regions of its own, now
    // that the regions are final and their writing has been read.
    final ({ExamDocument document, Map<String, HandwritingEvidence> evidence}) promoted =
        _equations.promote(boundaries.document, boundaries.evidence.handwriting);
    boundaries = BoundaryResult(
      document: promoted.document,
      evidence: EvidenceSet(handwriting: promoted.evidence),
      segments: boundaries.segments,
      warnings: boundaries.warnings,
    );

    final List<String> warnings = <String>[];
    final ExamDocument cropped = await _crop(boundaries.document, key, warnings);

    final Map<String, HandwritingEvidence> split = <String, HandwritingEvidence>{
      for (final MapEntry<String, HandwritingEvidence> e
          in boundaries.evidence.handwriting.entries)
        if (!handwriting.containsKey(e.key)) e.key: e.value,
    };
    await _store.write(document.documentId, key, <String, Object?>{
      'document': cropped.toJson(),
      'splitEvidence': <JsonMap>[
        for (final HandwritingEvidence e in split.values) e.toJson(),
      ],
      'alignment': alignment.toJson(),
    });

    return _Aligned(
      document: cropped,
      handwriting: boundaries.evidence.handwriting,
      alignment: alignment,
      key: key,
    );
  }

  Future<Map<String, VisualEvidence>> _analyzeVisuals(
    _Aligned aligned,
    QuestionPaper paper,
    _Reporter job,
    CancellationToken? cancel,
  ) async {
    final AppConfig config = _config();
    final String key = 'visuals-${ArtifactStore.fingerprint(<Object?>[
      aligned.key,
      _visualFingerprint,
      config.visualAnalysis,
    ])}';
    final String hash = aligned.document.documentId;
    final JsonMap? cached = await _store.read(hash, key);
    final Map<String, VisualEvidence> previous = cached == null
        ? const <String, VisualEvidence>{}
        : <String, VisualEvidence>{
            for (final VisualEvidence v
                in readObjects(cached['visuals'], VisualEvidence.fromJson))
              v.regionId: v,
          };

    final Map<String, List<String>> questionsByRegion =
        aligned.alignment.questionsByRegion;
    final List<VisualTask> tasks = <VisualTask>[];
    for (final PageRegion region in aligned.document.regions) {
      if (!region.type.isVisual) continue;
      final String? image =
          region.cropPath ?? aligned.document.page(region.pageId)?.imagePath;
      if (image == null) continue;
      // A derived equation answers whatever its parent region answers.
      final String? questionId = (questionsByRegion[region.regionId] ??
              questionsByRegion[region.parentRegionId ?? ''])
          ?.first;
      tasks.add(
        VisualTask(
          region: region,
          imagePath: image,
          questionContext:
              questionId == null ? null : paper.byId(questionId)?.questionText,
        ),
      );
    }

    // A cached run is reused — except analyses that failed, which were most
    // often a passing rate limit and are worth another attempt now.
    if (cached != null) {
      final List<VisualTask> retry = <VisualTask>[
        for (final VisualTask task in tasks)
          if (previous[task.region.regionId]?.status == AnalysisStatus.failed) task,
      ];
      if (retry.isEmpty || !config.visualAnalysis || !_visuals.hasAnyAnalyzer) {
        job.reused(ProcessingStage.analyzingVisuals);
        return previous;
      }
      final ({Map<String, VisualEvidence> evidence, List<String> warnings}) again =
          await _visuals.analyze(retry, onProgress: job.progress, cancel: cancel);
      job.warn(again.warnings);
      final Map<String, VisualEvidence> merged = <String, VisualEvidence>{
        ...previous,
        ...again.evidence,
      };
      await _store.write(hash, key, <String, Object?>{
        'visuals': <JsonMap>[for (final VisualEvidence v in merged.values) v.toJson()],
      });
      return merged;
    }

    Map<String, VisualEvidence> evidence;
    if (tasks.isEmpty) {
      evidence = <String, VisualEvidence>{};
    } else if (!config.visualAnalysis || !_visuals.hasAnyAnalyzer) {
      evidence = <String, VisualEvidence>{
        for (final VisualTask task in tasks)
          task.region.regionId: VisualEvidence.unanalysed(
            regionId: task.region.regionId,
            kind: task.region.type,
            status: AnalysisStatus.skipped,
            error: 'Visual analysis is turned off.',
          ),
      };
    } else {
      final ({Map<String, VisualEvidence> evidence, List<String> warnings}) result =
          await _visuals.analyze(tasks, onProgress: job.progress, cancel: cancel);
      evidence = result.evidence;
      job.warn(result.warnings);
    }

    await _store.write(hash, key, <String, Object?>{
      'visuals': <JsonMap>[for (final VisualEvidence v in evidence.values) v.toJson()],
    });
    return evidence;
  }

  Future<CorrectionResult> _mark(
    ExamAssessment assessment,
    String guidance,
    _Reporter job,
    CancellationToken? cancel,
  ) async {
    final QuestionPaper paper = assessment.questionPaper;
    final bool typed = assessment.answerSheet.source == DocumentSource.textLayer;
    final String hash = assessment.answerSheet.documentId;
    final List<MarkingTask> tasks = <MarkingTask>[
      for (final Question question in paper.markable)
        MarkingTask(
          question: question,
          section: paper.section(question.sectionId),
          answer: assessment.answers[question.questionId] ??
              StudentAnswer.none(question.questionId),
          images: _imagesFor(assessment, question.questionId),
          markScheme: paper.markSchemeFor(question),
          paperGuidance: paper.markingGuidance,
          choice: switch (paper.choicesOf(question.questionId)) {
            [final first, ...] => paper.describeChoice(first.choice),
            _ => '',
          },
        ),
    ];

    String keyFor(MarkingTask task) => 'mark-${ArtifactStore.fingerprint(<Object?>[
          _marker.fingerprint,
          guidance.trim(),
          typed,
          task.question.toJson(),
          task.markScheme,
          task.paperGuidance,
          task.choice,
          task.section?.toJson(),
          task.answer.toJson(),
          <String>[for (final MarkingImage image in task.images) image.regionId],
        ])}';

    final Map<String, QuestionResult> results = <String, QuestionResult>{};
    final List<MarkingTask> pending = <MarkingTask>[];
    for (final MarkingTask task in tasks) {
      final JsonMap? cached = await _store.read(hash, keyFor(task));
      final QuestionResult? restored =
          cached == null ? null : QuestionResult.fromJson(cached);
      if (restored != null) {
        results[task.question.questionId] = restored;
      } else {
        pending.add(task);
      }
    }
    if (pending.isEmpty) job.reused(ProcessingStage.marking);

    // Marked in chunks, each cached as soon as it returns, so an interruption
    // loses at most the chunk in flight.
    final int chunk = _config().questionsPerMarkingRequest;
    for (int start = 0; start < pending.length; start += chunk) {
      cancel?.throwIfCancelled();
      final List<MarkingTask> slice =
          pending.sublist(start, (start + chunk).clamp(0, pending.length));
      final List<QuestionResult> marked = await _marker.mark(
        slice,
        guidance: guidance,
        typedAnswerSheet: typed,
        onProgress: (String message, double fraction) => job.progress(
          message,
          (results.length + fraction * slice.length) / tasks.length,
        ),
        cancel: cancel,
      );
      for (int i = 0; i < slice.length; i++) {
        results[slice[i].question.questionId] = marked[i];
        // An unmarked question is not cached, so the next attempt retries it.
        if (marked[i].model.isNotEmpty || slice[i].answer.isEmpty) {
          await _store.write(hash, keyFor(slice[i]), marked[i].toJson());
        }
      }
      job.update(counts: job.counts.copyWith(questionsMarked: results.length));
    }

    // Which options of an OR count is decided from the answer sheet: the
    // first answered.
    final Map<String, int> firstSeen = <String, int>{
      for (final MapEntry<String, StudentAnswer> entry in assessment.answers.entries)
        if (!entry.value.isEmpty)
          if (_firstPosition(assessment, entry.value) case final int at) entry.key: at,
    };
    final List<QuestionResult> ordered = const ChoiceResolver().resolve(
      paper,
      <QuestionResult>[
        for (final MarkingTask task in tasks) results[task.question.questionId]!,
      ],
      firstSeen,
    );
    final Set<String> models = <String>{
      for (final QuestionResult q in ordered)
        if (q.model.isNotEmpty) q.model,
    };
    return CorrectionResult.fromQuestions(ordered, model: models.join(', '));
  }

  /// Where an answer begins on the answer sheet, as a sortable number.
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

  /// What the marker sees besides text: every visual region, and the writing
  /// that could not be read with confidence.
  List<MarkingImage> _imagesFor(ExamAssessment assessment, String questionId) {
    final StudentAnswer? answer = assessment.answers[questionId];
    if (answer == null || answer.isEmpty) return const <MarkingImage>[];
    final double threshold = _config().ocrConfidenceThreshold;
    final List<MarkingImage> images = <MarkingImage>[];

    void add(String regionId, String reason) {
      if (images.length >= imagesPerQuestion) return;
      final String? crop = assessment.region(regionId)?.cropPath;
      if (crop == null || images.any((MarkingImage i) => i.regionId == regionId)) {
        return;
      }
      images.add(MarkingImage(regionId: regionId, path: crop, reason: reason));
    }

    for (final String id in answer.visualRegionIds) {
      add(id, assessment.region(id)?.type.displayName.toLowerCase() ?? 'visual');
    }
    for (final TextEvidenceItem item in answer.textEvidence) {
      if (item.source == ReadingSource.textLayer || item.source == ReadingSource.teacher) {
        continue;
      }
      if (item.type == RegionType.printedText) continue;
      if (item.illegible ||
          item.enginesDisagree ||
          item.confidence < threshold ||
          item.uncertainSpans.isNotEmpty) {
        add(item.regionId, 'uncertain reading');
      }
    }
    return images;
  }

  ProcessingCounts _countRegions(ProcessingCounts counts, ExamDocument document) {
    int of(RegionType type) => document.countOf(type);
    return counts.copyWith(
      answerRegions: document.regions
          .where((PageRegion r) =>
              r.type.isAnswerContent || r.origin == RegionOrigin.textLayer)
          .length,
      diagrams: of(RegionType.diagram),
      graphs: of(RegionType.graph),
      tables: of(RegionType.table),
      equations: of(RegionType.equation),
      crossedOut: of(RegionType.crossedOut),
    );
  }
}

class _Detected {
  const _Detected({
    required this.document,
    required this.readings,
    required this.key,
  });

  final ExamDocument document;
  final Map<String, HandwritingReading> readings;
  final String key;
}

class _Aligned {
  const _Aligned({
    required this.document,
    required this.handwriting,
    required this.alignment,
    required this.key,
  });

  final ExamDocument document;
  final Map<String, HandwritingEvidence> handwriting;
  final AlignmentResult alignment;
  final String key;
}

/// Tracks the job and tells the listener about every change.
class _Reporter {
  _Reporter(this.current, this._listener);

  ProcessingJob current;
  final void Function(ProcessingJob job)? _listener;

  ProcessingCounts get counts => current.counts;

  void _emit(ProcessingJob job) {
    current = job;
    _listener?.call(job);
  }

  void begin(ProcessingStage stage) => _emit(
        current.copyWith(stage: stage, stageFraction: 0, message: '${stage.label}…'),
      );

  void progress(String message, double fraction) =>
      _emit(current.copyWith(message: message, stageFraction: fraction));

  void complete(ProcessingStage stage) => _emit(
        current.copyWith(
          completedStages: <ProcessingStage>{...current.completedStages, stage},
          stageFraction: 1,
        ),
      );

  void reused(ProcessingStage stage) => _emit(
        current.copyWith(
          reusedStages: <ProcessingStage>{...current.reusedStages, stage},
          message: '${stage.label} — reused from the last run.',
        ),
      );

  void update({ProcessingCounts? counts}) =>
      _emit(current.copyWith(counts: counts));

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

  void finish(ProcessingStage stage, String message) =>
      _emit(current.copyWith(stage: stage, message: message));

  void fail(ProcessingStage stage, String message) => _emit(
        current.copyWith(
          stage: ProcessingStage.failed,
          failedStage: () => stage,
          error: () => message,
          message: message,
        ),
      );
}
