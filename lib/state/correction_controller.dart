import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/marking_guidance.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/document/document_inspector.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/exam_pipeline.dart';
import 'package:exam_corrector/services/export/report_exporter.dart';
import 'package:exam_corrector/services/file_picker_service.dart';
import 'package:exam_corrector/services/pdf_service.dart';
import 'package:exam_corrector/services/review/teacher_work_store.dart';
import 'package:exam_corrector/services/settings_store.dart';
import 'package:exam_corrector/state/marked_script.dart';

export 'package:exam_corrector/state/marked_script.dart';

/// Owns the workflow: student scripts — one, or a class set — a question
/// paper and optional guidance in; understood and marked scripts out; then
/// the teacher's review.
///
/// Holds no marking logic of its own. It sequences the pipeline, keeps the
/// teacher's decisions beside the AI's results — never inside them — and
/// exposes state for the widgets. A plain [ChangeNotifier] is enough for a
/// single-window tool.
class CorrectionController extends ChangeNotifier {
  CorrectionController({
    required AppConfig config,
    required ExamPipeline Function() pipeline,
    DocumentInspector inspector = const LocalDocumentInspector(),
    FilePickerService filePicker = const FilePickerService(),
    SettingsStore settings = const SettingsStore(),
    PdfService pdfService = const PdfService(),
    ReportExporter exporter = const ReportExporter(),
  })  : _config = config,
        _pipeline = pipeline,
        _inspector = inspector,
        _filePicker = filePicker,
        _settings = settings,
        _pdf = pdfService,
        _exporter = exporter {
    if (!config.hasApiKey) {
      _statusMessage = 'No API key set — open Settings to add one.';
      _statusIsError = true;
    }
  }

  final ExamPipeline Function() _pipeline;
  final DocumentInspector _inspector;
  final FilePickerService _filePicker;
  final SettingsStore _settings;
  final PdfService _pdf;
  final ReportExporter _exporter;

  AppConfig _config;
  AppConfig get config => _config;

  /// Where the saved settings live, for the Settings dialog to show.
  String get settingsLocation => _settings.location;

  final List<MarkedScript> _scripts = <MarkedScript>[];
  int _current = 0;
  bool _showingClass = false;
  SelectedDocument? _questionPaper;
  MarkingGuidance _guidance = const MarkingGuidance.none();
  String? _guidanceFile;

  ProcessingJob? _job;
  ProcessingJob? _resumable;
  int? _batchPosition;

  CancellationToken? _cancel;
  bool _choosing = false;

  String _statusMessage = 'Ready.';
  bool _statusIsError = false;
  String? _pendingError;

  /// Every student script chosen: one, or a class set.
  List<MarkedScript> get scripts => List<MarkedScript>.unmodifiable(_scripts);

  /// The script whose results are on screen.
  MarkedScript? get currentScript =>
      _scripts.isEmpty ? null : _scripts[_current.clamp(0, _scripts.length - 1)];

  int get currentIndex => _current;

  /// More than one script: a class set.
  bool get isClass => _scripts.length > 1;

  /// The class table is showing, rather than one student's results.
  bool get showingClass => isClass && _showingClass;

  /// While a class is being marked: which script, from 1.
  int? get batchPosition => _batchPosition;

  SelectedDocument? get answerSheet => currentScript?.document;

  /// The authority for which questions exist, their sections and marks.
  SelectedDocument? get questionPaper => _questionPaper;

  MarkingGuidance get guidance => _guidance;

  /// The file the guidance was loaded from, if it was.
  String? get guidanceFile => _guidanceFile;

  /// How much of the question paper carries its own printed mark scheme —
  /// known once the paper has been read, and null when it prints none.
  ({int withScheme, int questions})? get paperScheme {
    final QuestionPaper? paper = _scripts
        .map((MarkedScript s) => s.assessment?.questionPaper)
        .nonNulls
        .firstOrNull;
    if (paper == null || !paper.hasMarkScheme) return null;
    return (withScheme: paper.markSchemeCount, questions: paper.markable.length);
  }

  /// The correction in progress, or the last one.
  ProcessingJob? get job => _job;

  /// A saved, unfinished run of the chosen pair of documents.
  ProcessingJob? get resumableJob => _resumable;

  ExamAssessment? get assessment => currentScript?.assessment;
  CorrectionResult? get result => assessment?.result;
  TeacherReviewBook get reviews => currentScript?.reviews ?? const TeacherReviewBook();

  /// The teacher's readings of regions, keyed by region ID.
  Map<String, String> get transcriptions =>
      currentScript?.transcriptions ?? const <String, String>{};

  /// Transcriptions were corrected since the paper was last marked.
  bool get hasPendingCorrections => currentScript?.correctionsPending ?? false;

  String get statusMessage => _statusMessage;
  bool get statusIsError => _statusIsError;

  /// An error worth interrupting the teacher for. Cleared once shown.
  String? get pendingError => _pendingError;

  bool get isProcessing => _cancel != null;
  bool get isChoosing => _choosing;
  bool get isBusy => isProcessing || _choosing;

  /// Kept for the status bar: marking is the long wait the teacher sees.
  bool get isCorrecting => isProcessing;

  bool get canCorrect =>
      _scripts.isNotEmpty && _questionPaper != null && !isBusy;

  // --------------------------------------------------------------------------
  // Inputs
  // --------------------------------------------------------------------------

  /// Chooses the student scripts to mark — one, or a whole class at once —
  /// replacing any chosen before.
  Future<void> chooseAnswerSheet() async {
    if (isBusy) return;
    final List<String> paths = await _filePicker.pickDocuments();
    if (paths.isEmpty) return;
    await _addScripts(paths, replace: true);
  }

  /// Adds more scripts to the class set.
  Future<void> addAnswerSheets() async {
    if (isBusy) return;
    final List<String> paths = await _filePicker.pickDocuments();
    if (paths.isEmpty) return;
    await _addScripts(paths, replace: false);
  }

  Future<void> _addScripts(List<String> paths, {required bool replace}) async {
    _choosing = true;
    _setStatus(paths.length == 1
        ? 'Checking the answer sheet…'
        : 'Checking ${paths.length} answer sheets…');

    final List<MarkedScript> added = <MarkedScript>[];
    final List<String> failures = <String>[];
    for (final String path in paths) {
      try {
        final SelectedDocument document =
            await _inspector.inspect(path, DocumentRole.answerSheet);
        final bool duplicate = <MarkedScript>[
          if (!replace) ..._scripts,
          ...added,
        ].any((MarkedScript s) => s.document.contentHash == document.contentHash);
        if (!duplicate) added.add(MarkedScript(document));
      } on AppException catch (error) {
        failures.add(paths.length == 1
            ? error.message
            : '${path.split(RegExp(r'[/\\]')).last}: ${error.message}');
      }
    }

    try {
      if (replace && (added.isNotEmpty || paths.length == 1)) {
        _scripts
          ..clear()
          ..addAll(added);
        _current = 0;
        _job = null;
      } else {
        _scripts.addAll(added);
      }
      _showingClass = _scripts.length > 1;
      for (final MarkedScript script in added) {
        await _loadSavedWork(script);
      }

      if (failures.isNotEmpty) {
        _fail(
          paths.length == 1
              ? 'The answer sheet could not be read.'
              : '${failures.length} of ${paths.length} answer sheets could not be read.',
          failures.join('\n'),
        );
      } else if (_scripts.length == 1) {
        _setStatus('Answer sheet ready: ${_describe(_scripts.single.document)}.');
      } else {
        _setStatus('${_scripts.length} answer sheets ready to mark as a class.');
      }
      if (_scripts.length == 1) await _loadResumable();
    } finally {
      _choosing = false;
      notifyListeners();
    }
  }

  Future<void> chooseQuestionPaper() async {
    if (isBusy) return;
    final String? path = await _filePicker.pickDocument();
    if (path == null) return;

    _choosing = true;
    _setStatus('Checking the question paper…');
    try {
      _questionPaper = await _inspector.inspect(path, DocumentRole.questionPaper);
      // A different paper means every mark so far was against the wrong
      // questions.
      for (final MarkedScript script in _scripts) {
        script.assessment = null;
        script.error = null;
      }
      _job = null;
      _setStatus('Question paper ready: ${_describe(_questionPaper!)}.');
      for (final MarkedScript script in _scripts) {
        await _loadSavedWork(script);
      }
      await _loadResumable();
    } on AppException catch (error) {
      _questionPaper = null;
      _fail('The question paper could not be read.', error.message);
    } finally {
      _choosing = false;
      notifyListeners();
    }
  }

  /// Opens one student's results.
  void openScript(int index) {
    if (index < 0 || index >= _scripts.length) return;
    _current = index;
    _showingClass = false;
    notifyListeners();
  }

  /// Back to the class table.
  void showClass() {
    if (!isClass) return;
    _showingClass = true;
    notifyListeners();
  }

  void removeScript(int index) {
    if (isBusy || index < 0 || index >= _scripts.length) return;
    _scripts.removeAt(index);
    _current = _current.clamp(0, _scripts.isEmpty ? 0 : _scripts.length - 1);
    if (_scripts.length <= 1) _showingClass = false;
    notifyListeners();
  }

  /// Picks up the teacher's earlier work on a script: its corrections and,
  /// with a question paper chosen, its reviews.
  Future<void> _loadSavedWork(MarkedScript script) async {
    final SelectedDocument? paper = _questionPaper;
    try {
      final TeacherWorkStore work = TeacherWorkStore(_pipeline().store);
      script.transcriptions = await work.transcriptions(script.document.contentHash);
      script.reviews = paper == null
          ? const TeacherReviewBook()
          : await work.reviews(script.document.contentHash, paper.contentHash);
    } on IOException {
      // Saved work is a convenience; its absence is not an error.
    }
  }

  /// An unfinished run of a single script against this paper, to resume.
  Future<void> _loadResumable() async {
    _resumable = null;
    final SelectedDocument? paper = _questionPaper;
    if (_scripts.length != 1 || paper == null) return;
    try {
      final ProcessingJob? last = await _pipeline().lastJob(_scripts.single.document, paper);
      if (last != null &&
          (last.stage == ProcessingStage.failed ||
              last.stage == ProcessingStage.cancelled)) {
        _resumable = last;
        _setStatus(
          'An unfinished run of these papers was found — marking will resume '
          'from ${(last.failedStage ?? ProcessingStage.rendering).label.toLowerCase()}.',
        );
      }
    } on IOException {
      // As above.
    }
  }

  String _describe(SelectedDocument document) {
    final String pages = '${document.pageCount} page${document.pageCount == 1 ? '' : 's'}';
    final String kind = switch (document.source) {
      DocumentSource.textLayer => 'typed',
      DocumentSource.scanned => 'scanned',
      DocumentSource.mixed => 'part typed, part scanned',
      DocumentSource.image => 'photograph',
    };
    return '${document.fileName}, $pages, $kind';
  }

  /// The teacher's optional marking notes. Notifies only when it changes
  /// between empty and not, so typing does not rebuild the results.
  void setGuidance(String text) {
    final bool wasEmpty = _guidance.isEmpty;
    _guidance = MarkingGuidance(text);
    if (wasEmpty != _guidance.isEmpty) notifyListeners();
  }

  void clearGuidance() {
    if (isBusy) return;
    _guidance = const MarkingGuidance.none();
    _guidanceFile = null;
    notifyListeners();
  }

  /// Loads marking guidance from a text, Markdown or PDF file.
  Future<void> loadGuidanceFile() async {
    if (isBusy) return;
    final String? path = await _filePicker.pickGuidance();
    if (path == null) return;
    try {
      final String text = path.toLowerCase().endsWith('.pdf')
          ? await _pdf.extractText(path)
          : await File(path).readAsString();
      _guidance = MarkingGuidance(
        text.split('\n').where((String l) => !l.startsWith('--- Page ')).join('\n').trim(),
      );
      _guidanceFile = path.split(RegExp(r'[/\\]')).last;
      _setStatus('Marking guidance loaded from $_guidanceFile.');
    } on AppException catch (error) {
      _fail('The guidance file could not be read.', error.message);
    } on IOException catch (error) {
      _fail('The guidance file could not be read.', '$error');
    }
  }

  // --------------------------------------------------------------------------
  // Processing
  // --------------------------------------------------------------------------

  /// Understands the current script and marks it against the question paper.
  ///
  /// Also how the teacher re-marks after correcting a transcription: every
  /// stage whose inputs did not change comes straight from the cache.
  Future<void> startCorrection() async {
    if (isBusy) return;
    final MarkedScript? script = currentScript;
    if (!_readyToMark(script == null ? const <MarkedScript>[] : <MarkedScript>[script])) {
      return;
    }

    final CancellationToken token = CancellationToken();
    _cancel = token;
    _resumable = null;
    _setStatus('Starting…');
    try {
      final ExamAssessment? assessment = await _run(script!, token);
      final CorrectionResult? result = assessment?.result;
      if (assessment == null) return;
      if (result == null) {
        _fail(
          'Marking stopped — everything read from the paper was kept.',
          assessment.job.error ?? 'Marking failed.',
        );
      } else {
        _setStatus(_summarise(result));
      }
    } on CancelledException {
      _setStatus('Cancelled. Starting again resumes where it stopped.');
    } finally {
      _cancel = null;
      notifyListeners();
    }
  }

  /// Marks every script in the class that still needs it, one after another.
  ///
  /// Scripts already marked are not repeated; a stopped batch resumes where
  /// it stopped, because every finished stage is cached. A marking failure —
  /// most often a spent quota — stops the batch rather than failing the same
  /// way for every remaining student.
  Future<void> markAll() async {
    if (isBusy) return;
    if (!_readyToMark(_scripts)) return;

    final List<MarkedScript> pending =
        _scripts.where((MarkedScript s) => s.needsWork).toList();
    if (pending.isEmpty) {
      _setStatus('Every script is already marked.');
      return;
    }

    final CancellationToken token = CancellationToken();
    _cancel = token;
    int done = 0;
    try {
      for (final MarkedScript script in pending) {
        _batchPosition = _scripts.indexOf(script) + 1;
        _setStatus('Script $_batchPosition of ${_scripts.length}: ${script.document.fileName}…');
        final ExamAssessment? assessment = await _run(script, token);
        if (assessment == null) {
          _fail(
            'Stopped at ${script.document.fileName}.',
            '${script.document.fileName}: ${script.error}\n\nThe scripts marked so far '
                'are kept. Marking all again continues from this one.',
          );
          return;
        }
        if (assessment.result == null) {
          _fail(
            'Marking stopped at ${script.document.fileName}.',
            '${assessment.job.error ?? 'Marking failed.'}\n\nThe scripts marked so '
                'far are kept, and everything read from this one. Marking all '
                'again continues from here.',
          );
          return;
        }
        done++;
      }
      final int review = _scripts
          .where((MarkedScript s) => s.status == ScriptStatus.reviewRequired)
          .length;
      _setStatus('Marked $done script${done == 1 ? '' : 's'}. '
          '${review == 0 ? 'Nothing needs review.' : '$review need your review.'}');
    } on CancelledException {
      _setStatus('Cancelled after $done script${done == 1 ? '' : 's'}. '
          'Marking all again continues where it stopped.');
    } finally {
      _cancel = null;
      _batchPosition = null;
      _showingClass = isClass;
      notifyListeners();
    }
  }

  /// Checks what every run needs, raising the reason when something is
  /// missing.
  bool _readyToMark(List<MarkedScript> scripts) {
    final SelectedDocument? paper = _questionPaper;
    if (scripts.isEmpty) {
      _raise("Choose the student's answer sheet first.");
      return false;
    }
    if (paper == null) {
      _raise(
        'Choose the question paper. It is what establishes the questions and '
        'how many marks each is worth.',
      );
      return false;
    }
    for (final MarkedScript script in scripts) {
      if (script.document.contentHash == paper.contentHash) {
        _raise(
          'The answer sheet and the question paper are the same document '
          '("${script.document.fileName}"). Choose the student\'s completed '
          'script as the answer sheet, and the question paper — with or without '
          'its mark scheme — as the question paper.',
        );
        return false;
      }
    }
    return true;
  }

  /// Runs the pipeline for one script. Returns null when a stage before
  /// marking failed, with the reason recorded on the script; rethrows a
  /// cancellation.
  Future<ExamAssessment?> _run(MarkedScript script, CancellationToken token) async {
    script.processing = true;
    script.error = null;
    try {
      final ExamAssessment assessment = await _pipeline().run(
        answerSheet: script.document,
        questionPaper: _questionPaper!,
        guidance: _guidance.trimmed,
        teacherTranscriptions: script.transcriptions,
        cancel: token,
        onUpdate: (ProcessingJob job) {
          _job = job;
          _statusMessage = _batchPosition == null
              ? job.message
              : 'Script $_batchPosition of ${_scripts.length}: ${job.message}';
          _statusIsError = false;
          notifyListeners();
        },
      );
      script.assessment = assessment;
      _job = assessment.job;
      script.correctionsPending = false;
      if (assessment.result == null) script.error = assessment.job.error;
      return assessment;
    } on CancelledException {
      rethrow;
    } on AppException catch (error) {
      script.error = error.message;
      if (_batchPosition == null) _fail('Correction failed.', error.message);
      return null;
    } catch (error) {
      // A pipeline failure must never take the application down.
      script.error = 'Unexpected error during correction: $error';
      if (_batchPosition == null) _fail('Correction failed.', script.error!);
      return null;
    } finally {
      script.processing = false;
    }
  }

  /// Stops processing. Finished stages stay cached.
  void cancelProcessing() {
    final CancellationToken? token = _cancel;
    if (token == null) return;
    _setStatus('Cancelling…');
    token.cancel();
  }

  String _summarise(CorrectionResult result) {
    final int count = result.questions.length;
    final StringBuffer summary = StringBuffer(
      'Marked $count question${count == 1 ? '' : 's'}: '
      '${formatMarks(result.totalMarks)} / '
      '${formatMarks(result.maximumTotalMarks)} '
      '(${formatPercentage(result.percentage)}).',
    );
    if (result.needsReviewCount > 0) {
      summary.write(' ${result.needsReviewCount} need your review.');
    }
    return summary.toString();
  }

  // --------------------------------------------------------------------------
  // Teacher review — always of the script on screen
  // --------------------------------------------------------------------------

  /// Records the teacher's own reading of a region. The machine readings are
  /// kept; this is what marking reads the next time the paper is marked.
  Future<void> correctTranscription(String regionId, String text) async {
    final MarkedScript? script = currentScript;
    if (script == null) return;
    script.transcriptions = <String, String>{...script.transcriptions, regionId: text};
    script.correctionsPending = true;
    await _saveTranscriptions(script);
    _setStatus('Transcription corrected. Re-mark to apply it.');
  }

  Future<void> revertTranscription(String regionId) async {
    final MarkedScript? script = currentScript;
    if (script == null || !script.transcriptions.containsKey(regionId)) return;
    script.transcriptions = Map<String, String>.of(script.transcriptions)..remove(regionId);
    script.correctionsPending = true;
    await _saveTranscriptions(script);
    _setStatus('Correction removed. Re-mark to apply it.');
  }

  Future<void> _saveTranscriptions(MarkedScript script) async {
    try {
      await TeacherWorkStore(_pipeline().store)
          .saveTranscriptions(script.document.contentHash, script.transcriptions);
    } on IOException catch (error) {
      _fail('The correction could not be saved.', '$error');
    }
  }

  /// The teacher agrees with the AI's mark.
  Future<void> acceptMark(String questionId, {String comment = ''}) async {
    final QuestionResult? question = result?.question(questionId);
    if (question == null) return;
    await _review(TeacherReview(
      questionId: questionId,
      status: ReviewStatus.accepted,
      aiMarks: question.awardedMarks,
      comment: comment,
      timestamp: DateTime.now(),
    ));
  }

  /// The teacher's mark replaces the AI's in every total — and the AI's is
  /// still recorded beside it.
  Future<void> overrideMark(
    String questionId,
    double marks, {
    String comment = '',
  }) async {
    final QuestionResult? question = result?.question(questionId);
    if (question == null) return;
    if (marks < 0 || marks > question.maximumMarks) {
      _raise(
        'A mark for question ${question.questionNumber} must be between 0 and '
        '${formatMarks(question.maximumMarks)}.',
      );
      return;
    }
    await _review(TeacherReview(
      questionId: questionId,
      status: ReviewStatus.overridden,
      aiMarks: question.awardedMarks,
      teacherMarks: marks,
      comment: comment,
      timestamp: DateTime.now(),
    ));
  }

  Future<void> clearReview(String questionId) async {
    final MarkedScript? script = currentScript;
    if (script == null || script.reviews[questionId] == null) return;
    script.reviews = script.reviews.without(questionId);
    await _saveReviews(script);
    notifyListeners();
  }

  Future<void> _review(TeacherReview review) async {
    final MarkedScript? script = currentScript;
    if (script == null) return;
    script.reviews = script.reviews.withReview(review);
    await _saveReviews(script);
    _setStatus(review.isOverride
        ? 'Mark changed to ${formatMarks(review.teacherMarks!)}. The AI\'s mark is kept for reference.'
        : 'Mark accepted.');
  }

  Future<void> _saveReviews(MarkedScript script) async {
    final SelectedDocument? paper = _questionPaper;
    if (paper == null) return;
    try {
      await TeacherWorkStore(_pipeline().store)
          .saveReviews(script.document.contentHash, paper.contentHash, script.reviews);
    } on IOException catch (error) {
      _fail('The review could not be saved.', '$error');
    }
  }

  double get finalTotal => currentScript?.finalTotal ?? 0;

  double get finalPercentage => currentScript?.finalPercentage ?? 0;

  // --------------------------------------------------------------------------
  // Export
  // --------------------------------------------------------------------------

  /// Writes the current script's marks out; returns the saved path, or null.
  Future<String?> exportReport(ReportFormat format) async {
    final ExamAssessment? marked = assessment;
    if (marked == null || marked.result == null) return null;

    final String? path = await _filePicker.pickSaveLocation(
      suggestedName: _exporter.suggestedName(marked, format),
      extension: format.extension,
    );
    if (path == null) return null;
    return _write(path, _exporter.export(marked, reviews, format));
  }

  /// Writes the whole class's marks as one CSV for a gradebook.
  Future<String?> exportClass() async {
    final List<ClassReportRow> rows = <ClassReportRow>[
      for (final MarkedScript script in _scripts)
        ClassReportRow(
          fileName: script.document.fileName,
          result: script.result,
          reviews: script.reviews,
        ),
    ];
    if (rows.every((ClassReportRow row) => row.result == null)) return null;

    final String? path = await _filePicker.pickSaveLocation(
      suggestedName: 'class marks.csv',
      extension: 'csv',
    );
    if (path == null) return null;
    return _write(path, _exporter.exportClass(rows));
  }

  Future<String?> _write(String path, String content) async {
    try {
      await File(path).writeAsString(content);
      _setStatus('Report saved to $path.');
      return path;
    } on IOException catch (error) {
      _fail('The report could not be saved.', '$error');
      return null;
    }
  }

  // --------------------------------------------------------------------------
  // Settings
  // --------------------------------------------------------------------------

  /// Saves what the teacher typed in Settings and makes it live immediately:
  /// every engine reads the configuration afresh for the next correction.
  Future<void> saveSettings({
    required String apiKey,
    required String model,
    String fallbackModels = '',
    bool? ocrEnabled,
    String? trocrModel,
    double? ocrThreshold,
    bool? visionCrossCheck,
    int? ocrDpi,
    LayoutEngine? layoutEngine,
    String? visionModel,
    double? reviewThreshold,
    bool? visualAnalysis,
    bool? developerMode,
  }) async {
    try {
      await _settings.save(
        apiKey: apiKey,
        model: model,
        fallbackModels: fallbackModels,
        ocrEnabled: ocrEnabled,
        trocrModel: trocrModel,
        ocrThreshold: ocrThreshold,
        visionCrossCheck: visionCrossCheck,
        ocrDpi: ocrDpi,
        layoutEngine: layoutEngine?.name,
        visionModel: visionModel,
        reviewThreshold: reviewThreshold,
        visualAnalysis: visualAnalysis,
        developerMode: developerMode,
      );
    } on Exception catch (error) {
      _fail('Settings could not be saved.', 'Could not save settings: $error');
      return;
    }

    _config = _config
        .withApiKey(apiKey.trim().isEmpty ? null : apiKey.trim())
        .withModel(model)
        .withFallbackModels(AppConfig.parseModelList(fallbackModels))
        .copyWith(
          ocrEnabled: ocrEnabled,
          trocrModel: trocrModel,
          ocrConfidenceThreshold: ocrThreshold,
          visionCrossCheck: visionCrossCheck,
          ocrDpi: ocrDpi,
          layoutEngine: layoutEngine,
          visionModel: visionModel == null
              ? null
              : () => visionModel.trim().isEmpty ? null : visionModel.trim(),
          reviewThreshold: reviewThreshold,
          visualAnalysis: visualAnalysis,
          developerMode: developerMode,
        );

    if (_config.hasApiKey) {
      _setStatus('Settings saved. Ready to mark with ${_config.model}.');
    } else {
      _statusMessage = 'No API key set — open Settings to add one.';
      _statusIsError = true;
      notifyListeners();
    }
  }

  /// Deletes every cached stage result. Teacher reviews and corrections are
  /// kept elsewhere and survive.
  Future<void> clearCache() async {
    if (isBusy) return;
    try {
      final ExamPipeline pipeline = _pipeline();
      final Directory docs = Directory(
        '${pipeline.store.root.path}${Platform.pathSeparator}docs',
      );
      if (await docs.exists()) {
        await for (final FileSystemEntity entry in docs.list()) {
          if (entry is! Directory) continue;
          await for (final FileSystemEntity file in entry.list()) {
            final String name = file.path.split(RegExp(r'[/\\]')).last;
            if (name.startsWith('teacher-')) continue;
            await file.delete(recursive: true);
          }
        }
      }
      _setStatus('Cache cleared. Your reviews and corrections were kept.');
    } on IOException catch (error) {
      _fail('The cache could not be cleared.', '$error');
    }
  }

  // --------------------------------------------------------------------------

  void clearError() {
    if (_pendingError == null) return;
    _pendingError = null;
    notifyListeners();
  }

  void _setStatus(String message) {
    _statusMessage = message;
    _statusIsError = false;
    notifyListeners();
  }

  void _fail(String status, String detail) {
    _statusMessage = status;
    _statusIsError = true;
    _pendingError = detail;
    notifyListeners();
  }

  void _raise(String detail) {
    _pendingError = detail;
    notifyListeners();
  }
}

/// Convenience for widgets: a question's region pages, for the evidence list.
extension RegionPages on ExamAssessment {
  List<int> pagesOf(Iterable<String> regionIds) => <int>{
        for (final String id in regionIds)
          if (region(id) case final region?) region.pageNumber,
      }.toList()
        ..sort();
}
