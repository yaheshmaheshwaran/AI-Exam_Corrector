import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/moderation.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/marking_guidance.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/document/document_inspector.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/exam_pipeline.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/pipeline/syllabus/syllabus_matcher.dart';
import 'package:exam_corrector/services/ai/model_usage.dart';
import 'package:exam_corrector/services/export/report_exporter.dart';
import 'package:exam_corrector/services/file_picker_service.dart';
import 'package:exam_corrector/services/pdf_service.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/models/student_status.dart';
import 'package:exam_corrector/models/correction_request.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/review/marking_standard_store.dart';
import 'package:exam_corrector/services/review/teacher_work_store.dart';
import 'package:exam_corrector/services/settings_store.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/services/syllabus/syllabus_reader.dart';
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
    SyllabusLibrary? syllabusLibrary,
    this.usage,
    MarkingStandardStore? standards,
    ResultsRepository? results,
  })  : _config = config,
        _standards = standards,
        _results = results,
        _library = syllabusLibrary,
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
    if (syllabusLibrary != null) unawaited(reloadSyllabi());
  }

  final ExamPipeline Function() _pipeline;
  final DocumentInspector _inspector;
  final FilePickerService _filePicker;
  final SettingsStore _settings;
  final PdfService _pdf;
  final ReportExporter _exporter;

  /// The teacher's saved syllabi; null where the feature is not wired up.
  final SyllabusLibrary? _library;

  /// Each paper's marking standard; null where not wired up.
  final MarkingStandardStore? _standards;

  /// The results database students read and raise corrections in; null
  /// where not wired up.
  final ResultsRepository? _results;

  /// Whether results can be published to students at all.
  bool get canPublish => _results != null;

  int _openRequests = 0;

  /// Students' correction requests still waiting for an answer.
  int get openRequestCount => _openRequests;

  MarkingStandard _standard = const MarkingStandard();

  /// The standard the chosen paper is marked to.
  MarkingStandard get markingStandard => _standard;

  /// Whether the teacher can set a marking standard at all.
  bool get hasMarkingStandards => _standards != null;

  /// The teacher's own marks on this paper's scripts, script by script,
  /// against the AI's — what moderation is worked out from.
  Map<String, List<ModerationSample>> _moderationSamples = <String, List<ModerationSample>>{};

  Moderation _moderation = Moderation.none;

  /// The moderation the paper's marks are brought to, when the teacher
  /// applied one.
  Moderation get moderation => _moderation;

  /// What the teacher's marks so far suggest; null until there are enough.
  Moderation? get suggestedModeration => Moderation.from(_moderationSamples);

  /// Whether the teacher's marks suggest a moderation other than the one in
  /// force.
  bool get moderationOutdated {
    final Moderation? suggested = suggestedModeration;
    return suggested != null && suggested.differsFrom(_moderation);
  }

  /// How far the AI is from the teacher on the questions they marked — as
  /// marked, and moderated as it is (or would be); null before they mark any.
  ({double before, double after, int questions})? get agreement => Moderation.agreement(
        _moderationSamples,
        _moderation.isActive ? _moderation : (suggestedModeration ?? Moderation.none),
      );

  /// How many questions the teacher has marked on this paper's scripts.
  int get moderationSampleCount => _moderationSamples.values
      .fold<int>(0, (int sum, List<ModerationSample> s) => sum + s.length);

  /// A class whose marks are higher than real classes get, with nothing
  /// moderating them.
  bool get classMarksLookHigh {
    final List<double> percentages = <double>[
      for (final MarkedScript script in _scripts)
        if (script.finalPercentage case final double p) p,
    ];
    if (percentages.length < 3 || _moderation.isActive) return false;
    final double average = percentages.reduce((double a, double b) => a + b) / percentages.length;
    return average > Moderation.classHighAverage;
  }

  /// How much the AI has been asked today, and whether it is working,
  /// waiting out a rate limit or out of quota; null where not wired up.
  final ModelUsageMonitor? usage;

  AppConfig _config;
  AppConfig get config => _config;

  /// Where the saved settings live, for the Settings dialog to show.
  String get settingsLocation => _settings.location;

  final List<MarkedScript> _scripts = <MarkedScript>[];
  int _current = 0;
  bool _showingClass = false;
  SelectedDocument? _questionPaper;
  MarkingGuidance _guidance = const MarkingGuidance.none();

  List<Syllabus> _syllabi = const <Syllabus>[];

  /// For the chosen paper: a syllabus ID, [SyllabusLibrary.none], or null to
  /// match automatically.
  String? _syllabusChoice;

  /// What automatic matching found in the paper's text when it was chosen.
  SyllabusMatch? _syllabusMatch;

  /// Bumped whenever the teacher chooses a syllabus, so a read of the saved
  /// choice that began before it never overwrites what they just chose.
  int _syllabusVersion = 0;
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

  /// Whether the syllabus library is available at all.
  bool get hasSyllabusLibrary => _library != null;

  bool _addingSyllabus = false;
  CancellationToken? _syllabusCancel;

  /// Stops reading syllabus files; those already saved are kept.
  void cancelSyllabusReading() {
    final CancellationToken? token = _syllabusCancel;
    if (token == null) return;
    _setStatus('Stopping…');
    token.cancel();
  }

  /// Syllabus files are being read right now.
  bool get isAddingSyllabus => _addingSyllabus;

  /// Every saved syllabus.
  List<Syllabus> get syllabi => _syllabi;

  /// The teacher's choice for the chosen paper, or null for automatic.
  String? get syllabusChoice => _syllabusChoice;

  /// The syllabus the chosen paper is — or will be — marked against, and how
  /// it was chosen; null when there is none.
  ({String name, String how})? get syllabusInUse {
    if (_syllabusChoice == SyllabusLibrary.none) return null;
    if (_syllabusChoice case final String id) {
      for (final Syllabus syllabus in _syllabi) {
        if (syllabus.id == id) return (name: syllabus.name, how: 'chosen by you');
      }
    }
    if (assessment?.syllabus case final ({String id, String name, String how}) used) {
      return (name: used.name, how: used.how);
    }
    if (_syllabusMatch case final SyllabusMatch match) {
      return (name: match.syllabus.name, how: 'matched by ${match.reason}');
    }
    return null;
  }

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
      await _prepareSyllabus(_questionPaper!);
      final MarkingStandardStore? standards = _standards;
      if (standards != null) {
        try {
          _standard = await standards.forPaper(_questionPaper!.contentHash);
        } on IOException {
          _standard = const MarkingStandard();
        }
      }
      await _loadModeration();
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

  // --------------------------------------------------------------------------
  // Syllabi
  // --------------------------------------------------------------------------

  Future<void> reloadSyllabi() async {
    final SyllabusLibrary? library = _library;
    if (library == null) return;
    try {
      _syllabi = await library.list();
    } on IOException {
      _syllabi = const <Syllabus>[];
    }
    final SelectedDocument? paper = _questionPaper;
    if (paper != null) await _prepareSyllabus(paper);
    notifyListeners();
  }

  /// Reads the teacher's choice for [paper], and matches the saved syllabi
  /// against its text so the card can say which one will be used.
  Future<void> _prepareSyllabus(SelectedDocument paper) async {
    final SyllabusLibrary? library = _library;
    if (library == null) return;
    final int version = _syllabusVersion;
    bool current() => version == _syllabusVersion && _questionPaper == paper;

    String? choice;
    try {
      choice = await library.choiceFor(paper.contentHash);
    } on IOException {
      choice = null;
    }
    if (!current()) return;
    _syllabusChoice = choice;
    _syllabusMatch = null;
    if (_syllabi.isEmpty) return;
    try {
      final String? text = await _pdf.extractTextIfPresent(paper.filePath);
      if (text != null && current()) {
        final String opening = text.length > 6000 ? text.substring(0, 6000) : text;
        _syllabusMatch = const SyllabusMatcher().best(_syllabi, title: '', text: opening);
      }
    } on AppException {
      // A scanned paper: it is matched once its questions have been read.
    }
  }

  /// Adds a syllabus to the library from a file the teacher picks.
  Future<Syllabus?> addSyllabus() async {
    if (_library == null || isBusy) return null;
    final String? path = await _filePicker.pickSyllabus();
    if (path == null) return null;
    final List<Syllabus> added = await addSyllabusFiles(<String>[path]);
    return added.isEmpty ? null : added.single;
  }

  /// Adds syllabi from files dropped on the library or picked: each read and
  /// saved on its own, so one bad file does not stop the rest.
  Future<List<Syllabus>> addSyllabusFiles(List<String> paths) async {
    final SyllabusLibrary? library = _library;
    if (library == null || isBusy || paths.isEmpty) return const <Syllabus>[];

    final List<Syllabus> added = <Syllabus>[];
    final List<String> failures = <String>[];
    String name(String path) => path.split(RegExp(r'[/\\]')).last;

    _choosing = true;
    _addingSyllabus = true;
    final CancellationToken token = CancellationToken();
    _syllabusCancel = token;
    bool cancelled = false;
    try {
      for (int i = 0; i < paths.length; i++) {
        final String path = paths[i];
        final String extension = path.contains('.') ? path.split('.').last.toLowerCase() : '';
        if (!SyllabusReader.extensions.contains(extension)) {
          failures.add('${name(path)}: not a PDF, PowerPoint (.pptx), Word (.docx) or text file.');
          continue;
        }
        _setStatus(paths.length == 1
            ? 'Reading the syllabus…'
            : 'Reading syllabus ${i + 1} of ${paths.length}: ${name(path)}…');
        try {
          added.addAll(await library.add(
            path,
            cancel: token,
            onProgress: (String message) => _setStatus(paths.length == 1
                ? message
                : '(${i + 1} of ${paths.length}) $message'),
          ));
        } on CancelledException {
          cancelled = true;
          break;
        } on AppException catch (error) {
          failures.add(paths.length == 1 ? error.message : '${name(path)}: ${error.message}');
        } on IOException catch (error) {
          failures.add('${name(path)}: could not be saved ($error).');
        }
      }
      await reloadSyllabi();

      final int files = added.map((Syllabus s) => s.sourceId).toSet().length;
      final String saved = added.length == 1
          ? 'Syllabus saved: ${added.single.name} — ${added.single.units.length} '
              'unit${added.single.units.length == 1 ? '' : 's'}.'
          : files == 1
              ? '${added.length} courses read from ${added.first.fileName} and saved.'
              : '${added.length} syllabi saved from $files files.';
      if (cancelled) {
        _setStatus(added.isEmpty
            ? 'Stopped reading the syllabus.'
            : 'Stopped. $saved');
      } else if (failures.isEmpty) {
        // What could not be read — picture slides with no key — is said.
        final Set<String> notes = <String>{for (final Syllabus s in added) ...s.notes};
        _setStatus(notes.isEmpty ? saved : '$saved ${notes.join(' ')}');
      } else {
        _fail(
          added.isEmpty
              ? (paths.length == 1
                  ? 'The syllabus could not be read.'
                  : 'None of the ${paths.length} files could be read as a syllabus.')
              : '$saved ${failures.length} could not be read.',
          failures.join('\n'),
        );
      }
      return added;
    } finally {
      _choosing = false;
      _addingSyllabus = false;
      _syllabusCancel = null;
      notifyListeners();
    }
  }

  /// Removes every course read from one uploaded file.
  Future<void> removeSyllabusFile(String sourceId) async {
    final SyllabusLibrary? library = _library;
    if (library == null || isBusy) return;
    try {
      await library.removeSource(sourceId);
    } on IOException catch (error) {
      _fail('The syllabus file could not be removed.', '$error');
      return;
    }
    await reloadSyllabi();
    _setStatus('Syllabus file removed.');
  }

  Future<void> removeSyllabus(String id) async {
    final SyllabusLibrary? library = _library;
    if (library == null || isBusy) return;
    try {
      await library.remove(id);
    } on IOException catch (error) {
      _fail('The syllabus could not be removed.', '$error');
      return;
    }
    await reloadSyllabi();
    _setStatus('Syllabus removed.');
  }

  /// Corrects a syllabus's course title or code — what matching relies on.
  Future<void> updateSyllabus(String id, {String? courseTitle, String? courseCode}) async {
    final SyllabusLibrary? library = _library;
    if (library == null) return;
    try {
      await library.update(id, courseTitle: courseTitle, courseCode: courseCode);
    } on IOException catch (error) {
      _fail('The syllabus could not be saved.', '$error');
      return;
    }
    await reloadSyllabi();
  }

  /// Chooses the syllabus for the chosen paper: an ID, [SyllabusLibrary.none],
  /// or null to match automatically. Saved for the paper; applied at the next
  /// marking, which re-marks only the questions whose syllabus changed.
  Future<void> chooseSyllabus(String? choice) async {
    final SyllabusLibrary? library = _library;
    final SelectedDocument? paper = _questionPaper;
    if (library == null || paper == null || isBusy) return;
    _syllabusVersion++;
    _syllabusChoice = choice;
    try {
      await library.setChoice(paper.contentHash, choice);
    } on IOException catch (error) {
      _fail('The choice could not be saved.', '$error');
      return;
    }
    final bool marked = _scripts.any((MarkedScript s) => s.result != null);
    for (final MarkedScript script in _scripts) {
      if (script.result != null) script.correctionsPending = true;
    }
    _setStatus(<String>[
      switch (choice) {
        null => 'The syllabus will be matched automatically.',
        SyllabusLibrary.none => 'This paper will be marked without a syllabus.',
        _ => 'Syllabus chosen: ${syllabusInUse?.name ?? 'saved'}.',
      },
      if (marked) 'Re-mark to apply it.',
    ].join(' '));
  }

  // --------------------------------------------------------------------------
  // Publishing to students
  // --------------------------------------------------------------------------

  /// The name a student would look a script up by: its file name, without
  /// the extension.
  static String studentNameFor(MarkedScript script) =>
      script.document.fileName.replaceAll(RegExp(r'\.[^.]+$'), '');

  /// Why [script] cannot be published yet, or null when it can.
  String? publishBlocker(MarkedScript script) {
    final CorrectionResult? result = script.result;
    if (result == null) return 'It has not been marked yet.';
    final int outstanding = script.reviews.outstanding(result);
    if (outstanding > 0) {
      return '$outstanding question${outstanding == 1 ? ' still needs' : 's still need'} '
          'your review.';
    }
    return null;
  }

  /// What the publish dialog starts from for [script]: a roll number from
  /// its file name, and the subject and exam this paper was last published
  /// under — or the matched syllabus's course code and the paper's title.
  Future<({String rollNo, String subjectCode, String exam})> publishDefaults(MarkedScript script) async {
    final ExamAssessment? marked = script.assessment;
    final String paperHash = marked?.questionPaper.documentId ?? '';
    ({String subjectCode, String exam})? saved;
    try {
      saved = paperHash.isEmpty ? null : await _results?.paperDefaults(paperHash);
    } on Exception {
      saved = null;
    }
    String code = saved?.subjectCode ?? '';
    if (code.isEmpty) {
      final String? usedId = marked?.syllabus?.id ?? _syllabusChoice;
      code = _syllabi.where((Syllabus s) => s.id == usedId).firstOrNull?.courseCode ?? '';
    }
    final String title = marked?.questionPaper.title.trim() ?? '';
    return (
      rollNo: PublishedResult.rollFromFileName(script.document.fileName) ?? '',
      subjectCode: code,
      exam: saved?.exam ?? title,
    );
  }

  /// Publishes the script on screen to the results database, under the
  /// student's roll number and the subject and exam.
  Future<bool> publishCurrent({
    required String rollNo,
    String student = '',
    required String subjectCode,
    required String exam,
  }) async {
    final MarkedScript? script = currentScript;
    final ResultsRepository? results = _results;
    if (script == null || results == null || isBusy) return false;
    final String? blocker = publishBlocker(script);
    if (blocker != null) {
      _raise('This script cannot be published yet: $blocker');
      return false;
    }
    try {
      final PublishedResult saved = await results.publish(PublishedResult.of(
        script.assessment!,
        script.reviews,
        student: student,
        rollNo: rollNo,
        subjectCode: subjectCode,
        exam: exam,
      ));
      await results.savePaperDefaults(saved.paperHash, subjectCode: subjectCode, exam: exam);
      _setStatus('Published for ${saved.rollNo} in ${saved.subjectCode}'
          '${saved.exam.isEmpty ? '' : ' (${saved.exam})'} — the student signs in with '
          'that roll number and subject.');
      return true;
    } on AppException catch (error) {
      _fail('The result could not be published.', error.message);
    } on Exception catch (error) {
      _fail('The result could not be published.', '$error');
    }
    return false;
  }

  /// Publishes every ready script in the class under the same subject and
  /// exam; [rollNos] gives each script's roll number by its index. Scripts
  /// without one, or still with questions to review, are held back and named.
  Future<int> publishClass({
    required String subjectCode,
    required String exam,
    required Map<int, String> rollNos,
  }) async {
    final ResultsRepository? results = _results;
    if (results == null || isBusy) return 0;
    int published = 0;
    final List<String> held = <String>[];
    for (int i = 0; i < _scripts.length; i++) {
      final MarkedScript script = _scripts[i];
      if (script.result == null) continue;
      final String roll = rollNos[i]?.trim() ?? '';
      final String? blocker = roll.isEmpty ? 'it has no roll number.' : publishBlocker(script);
      if (blocker != null) {
        held.add('${script.document.fileName}: $blocker');
        continue;
      }
      try {
        final PublishedResult saved = await results.publish(PublishedResult.of(
          script.assessment!,
          script.reviews,
          student: '',
          rollNo: roll,
          subjectCode: subjectCode,
          exam: exam,
        ));
        await results.savePaperDefaults(saved.paperHash, subjectCode: subjectCode, exam: exam);
        published++;
      } on AppException catch (error) {
        held.add('${script.document.fileName}: ${error.message}');
      }
    }
    if (held.isEmpty) {
      _setStatus('Published $published result${published == 1 ? '' : 's'} in '
          '${PublishedResult.normaliseRoll(subjectCode)}.');
    } else {
      _fail(
        'Published $published; ${held.length} held back.',
        'These were not published:\n${held.join('\n')}',
      );
    }
    return published;
  }

  // --------------------------------------------------------------------------
  // Students' correction requests
  // --------------------------------------------------------------------------

  /// Reads how many requests are waiting, for the badge.
  Future<void> refreshRequests() async {
    final ResultsRepository? results = _results;
    if (results == null) return;
    final int open = await results.openRequestCount();
    if (open != _openRequests) {
      _openRequests = open;
      notifyListeners();
    }
  }

  /// Where every student stands with their published results: seen,
  /// verified, requests.
  Future<List<StudentStatus>> studentOverview({String? subjectCode, String? exam}) async =>
      await _results?.overview(subjectCode: subjectCode, exam: exam) ?? const <StudentStatus>[];

  Future<List<String>> publishedSubjects() async => await _results?.subjects() ?? const <String>[];

  Future<List<String>> examsFor(String? subjectCode) async =>
      await _results?.exams(subjectCode: subjectCode) ?? const <String>[];

  /// The students table as CSV, for the college's records.
  static String overviewCsv(List<StudentStatus> rows) {
    String cell(String value) =>
        RegExp(r'[",\n]').hasMatch(value) ? '"${value.replaceAll('"', '""')}"' : value;
    String date(DateTime? d) => d == null ? '' : d.toIso8601String().substring(0, 16).replaceFirst('T', ' ');
    final StringBuffer out = StringBuffer()
      ..writeln(<String>[
        'Roll no', 'Name', 'Subject', 'Exam', 'Marks', 'Maximum', 'Percentage', 'Published',
        'First seen', 'Times seen', 'Verified', 'Open requests', 'Answered requests', 'Status',
        'Syllabus badges',
      ].join(','));
    for (final StudentStatus r in rows) {
      out.writeln(<String>[
        r.rollNo, r.studentName, r.subjectCode, r.exam, formatMarks(r.total), formatMarks(r.maximum),
        formatPercentage(r.percentage), date(r.publishedAt), date(r.firstSeenAt), '${r.seenCount}',
        date(r.verifiedAt), '${r.openRequests}', '${r.answeredRequests}', r.stage.label,
        '${r.badges}',
      ].map(cell).join(','));
    }
    return out.toString();
  }

  /// Saves the table as shown, filters applied.
  Future<String?> exportOverview(List<StudentStatus> rows, {String name = 'student status'}) async {
    if (rows.isEmpty) return null;
    final String? path = await _filePicker.pickSaveLocation(suggestedName: '$name.csv', extension: 'csv');
    if (path == null) return null;
    return _write(path, overviewCsv(rows));
  }

  /// A published result, with its answer sheet — for looking at the answer
  /// a request is about.
  Future<PublishedResult?> publishedResult(String id) async => _results?.result(id);

  Future<List<CorrectionRequest>> correctionRequests({
    bool openOnly = false,
    String? subjectCode,
    String? rollNo,
  }) async =>
      await _results?.requests(openOnly: openOnly, subjectCode: subjectCode, rollNo: rollNo) ??
      const <CorrectionRequest>[];

  /// Accepts a request: the student's mark becomes [marks] and every total
  /// changes. If that script is open here, the change is recorded as the
  /// teacher's override too, so this screen and its exports agree.
  Future<bool> acceptRequest(CorrectionRequest request, double marks, String reply) async {
    final ResultsRepository? results = _results;
    if (results == null) return false;
    try {
      final PublishedResult changed = await results.acceptRequest(request.id, marks: marks, reply: reply);
      for (final MarkedScript script in _scripts) {
        final ExamAssessment? marked = script.assessment;
        final QuestionResult? question = marked?.result?.question(request.questionId);
        if (marked == null ||
            question == null ||
            marked.answerSheet.documentId != changed.scriptHash ||
            marked.questionPaper.documentId != changed.paperHash) {
          continue;
        }
        script.reviews = script.reviews.withReview(TeacherReview(
          questionId: request.questionId,
          status: ReviewStatus.overridden,
          aiMarks: question.awardedMarks,
          teacherMarks: marks,
          comment: 'Correction request from ${request.rollNo}: $reply',
          timestamp: DateTime.now(),
        ));
        await _saveReviews(script);
      }
      await refreshRequests();
      _setStatus('Accepted: question ${request.questionNumber} for ${request.rollNo} is now '
          '${formatMarks(marks)} — total ${formatMarks(changed.total)}.');
      return true;
    } on AppException catch (error) {
      _raise(error.message);
      return false;
    }
  }

  Future<bool> declineRequest(CorrectionRequest request, String reply) async {
    final ResultsRepository? results = _results;
    if (results == null) return false;
    try {
      await results.declineRequest(request.id, reply: reply);
      await refreshRequests();
      _setStatus('Declined: question ${request.questionNumber} for ${request.rollNo}.');
      return true;
    } on AppException catch (error) {
      _raise(error.message);
      return false;
    }
  }

  // --------------------------------------------------------------------------
  // Marking standard
  // --------------------------------------------------------------------------

  /// Sets the chosen paper's marking standard, and saves it — as the default
  /// for new papers too when asked.
  ///
  /// A change of level or of the written college rules changes how the AI
  /// judges, so the marked scripts are left to re-mark, with an estimate of
  /// the requests it takes. A change of rounding, mark step or penalty is
  /// arithmetic on marks already made: it is applied at once, from the
  /// cache, with no request at all.
  Future<void> setMarkingStandard(MarkingStandard next, {bool asDefault = false}) async {
    if (isBusy) return;
    final MarkingStandard previous = _standard;
    _standard = next;
    final SelectedDocument? paper = _questionPaper;
    final MarkingStandardStore? standards = _standards;
    if (paper != null && standards != null) {
      try {
        await standards.save(paper.contentHash, next, asDefault: asDefault);
      } on IOException catch (error) {
        _fail('The marking standard could not be saved.', '$error');
      }
    }

    final List<MarkedScript> marked =
        _scripts.where((MarkedScript s) => s.result != null).toList();
    if (marked.isEmpty) {
      _setStatus('Marking standard: ${next.summary}.');
      return;
    }

    if (next.judgementKey != previous.judgementKey) {
      int questions = 0;
      int requests = 0;
      for (final MarkedScript script in marked) {
        final int answered = script.assessment!.answers.values
            .where((StudentAnswer a) => !a.isEmpty)
            .length;
        questions += answered;
        requests += (answered / _config.questionsPerMarkingRequest).ceil();
        script.correctionsPending = true;
      }
      _setStatus('Marking standard: ${next.summary}. The AI judges differently at '
          'this level — re-mark to apply it: $questions answer${questions == 1 ? '' : 's'}, '
          'about $requests request${requests == 1 ? '' : 's'}.');
      return;
    }

    // Arithmetic only: every mark comes back from the cache.
    await _rerunFromCache('Marking standard applied: ${next.summary} — no re-marking needed.');
  }

  /// Runs every marked script again with every mark from the cache, for a
  /// change that is arithmetic on the marks.
  Future<void> _rerunFromCache(String done) async {
    final List<MarkedScript> marked =
        _scripts.where((MarkedScript s) => s.result != null).toList();
    if (marked.isEmpty) {
      _setStatus(done);
      return;
    }
    final CancellationToken token = CancellationToken();
    _cancel = token;
    try {
      for (final MarkedScript script in marked) {
        await _run(script, token);
      }
      _setStatus(done);
    } on CancelledException {
      _setStatus('Cancelled.');
    } finally {
      _cancel = null;
      notifyListeners();
    }
  }

  // --------------------------------------------------------------------------
  // Moderation
  // --------------------------------------------------------------------------

  Future<void> _loadModeration() async {
    _moderationSamples = <String, List<ModerationSample>>{};
    _moderation = Moderation.none;
    final SelectedDocument? paper = _questionPaper;
    if (paper == null) return;
    try {
      final JsonMap? saved = await TeacherWorkStore(_pipeline().store).moderation(paper.contentHash);
      if (saved == null) return;
      _moderation = Moderation.fromJson(saved['applied']);
      final JsonMap samples = readMap(saved['samples']) ?? const <String, Object?>{};
      _moderationSamples = <String, List<ModerationSample>>{
        for (final MapEntry<String, Object?> entry in samples.entries)
          entry.key: readObjects(entry.value, ModerationSample.fromJson),
      };
    } on IOException {
      // Moderation is the teacher's own record; without it marks stand as marked.
    }
  }

  Future<void> _saveModeration() async {
    final SelectedDocument? paper = _questionPaper;
    if (paper == null) return;
    try {
      await TeacherWorkStore(_pipeline().store).saveModeration(paper.contentHash, <String, Object?>{
        'applied': _moderation.toJson(),
        'samples': <String, Object?>{
          for (final MapEntry<String, List<ModerationSample>> entry in _moderationSamples.entries)
            entry.key: <JsonMap>[for (final ModerationSample s in entry.value) s.toJson()],
        },
      });
    } on IOException catch (error) {
      _fail('Moderation could not be saved.', '$error');
    }
  }

  /// Each question the teacher accepted or changed on [script], beside the
  /// AI's mark before moderation.
  Future<void> _recordSamples(MarkedScript script) async {
    final CorrectionResult? marked = script.result;
    if (marked == null) return;
    final List<ModerationSample> samples = <ModerationSample>[
      for (final QuestionResult q in marked.questions)
        if (script.reviews[q.questionId] case final TeacherReview review when q.counted)
          ModerationSample(
            questionId: q.questionId,
            ai: q.moderatedFrom ?? q.awardedMarks,
            teacher: review.isOverride ? review.teacherMarks! : review.aiMarks,
            maximum: q.maximumMarks,
            section: q.section,
          ),
    ];
    final String hash = script.document.contentHash;
    if (samples.isEmpty) {
      _moderationSamples.remove(hash);
    } else {
      _moderationSamples[hash] = samples;
    }
    await _saveModeration();
  }

  /// Brings every script's marks to the teacher's own marking, as their
  /// marks so far suggest — instantly, from the cache.
  Future<void> applyModeration() async {
    final Moderation? suggested = suggestedModeration;
    if (isBusy || suggested == null) return;
    _moderation = suggested;
    await _saveModeration();
    await _rerunFromCache('Moderated to your marking ${suggested.factors} (${suggested.basis}).');
  }

  /// Marks as the AI and the standard make them, unmoderated.
  Future<void> removeModeration() async {
    if (isBusy || !_moderation.isActive) return;
    _moderation = Moderation.none;
    await _saveModeration();
    await _rerunFromCache('Moderation removed — marks are as the AI and the standard make them.');
  }

  // --------------------------------------------------------------------------
  // Answer key
  // --------------------------------------------------------------------------

  /// The key the paper was last marked against, with the teacher's edits;
  /// null before any script of it was marked.
  Future<AnswerKey?> answerKey() async {
    final SelectedDocument? paper = _questionPaper;
    if (paper == null) return null;
    try {
      final TeacherWorkStore work = TeacherWorkStore(_pipeline().store);
      final Map<String, AnswerKeyEntry> entries = AnswerKey.entriesFromJson(await work.answerKey(paper.contentHash));
      final Map<String, String> edits = await work.answerKeyEdits(paper.contentHash);
      final AnswerKey key = AnswerKey(entries: entries, edits: edits);
      return key.isEmpty ? null : key;
    } on IOException {
      return null;
    }
  }

  /// The paper's questions as read, for showing the key beside them.
  QuestionPaper? get markedPaper => _scripts
      .map((MarkedScript s) => s.assessment?.questionPaper)
      .nonNulls
      .firstOrNull;

  /// The teacher's own key for questions, in place of the AI's. It changes
  /// what the AI marks against, so marked scripts need re-marking.
  Future<void> saveAnswerKeyEdits(Map<String, String> edits) async {
    final SelectedDocument? paper = _questionPaper;
    if (paper == null) return;
    final AnswerKey? before = await answerKey();
    final Map<String, String> kept = <String, String>{
      for (final MapEntry<String, String> e in edits.entries)
        if (e.value.trim().isNotEmpty && e.value.trim() != (before?.entries[e.key]?.text ?? '').trim())
          e.key: e.value.trim(),
    };
    try {
      await TeacherWorkStore(_pipeline().store).saveAnswerKeyEdits(paper.contentHash, kept);
    } on IOException catch (error) {
      _fail('The answer key could not be saved.', '$error');
      return;
    }
    final Set<String> changed = <String>{
      ...kept.keys,
      ...?before?.edits.keys,
    }.where((String id) => kept[id] != before?.edits[id]).toSet();
    if (changed.isEmpty) {
      _setStatus('Answer key unchanged.');
      return;
    }
    int scripts = 0;
    for (final MarkedScript script in _scripts) {
      if (script.result == null) continue;
      script.correctionsPending = true;
      scripts++;
    }
    _setStatus(scripts == 0
        ? 'Answer key saved.'
        : 'Answer key saved — ${changed.length} question${changed.length == 1 ? '' : 's'} changed. '
            'Re-mark to apply it to $scripts script${scripts == 1 ? '' : 's'}.');
    notifyListeners();
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
      script.assignments = paper == null
          ? const <String, String>{}
          : await work.assignments(script.document.contentHash, paper.contentHash);
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
        teacherAssignments: script.assignments,
        syllabi: _syllabi,
        syllabusChoice: _syllabusChoice,
        standard: _standard,
        moderation: _moderation,
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

  /// Writing the teacher chose as questions' answers, for the script on
  /// screen: region ID to question ID.
  Map<String, String> get assignments =>
      currentScript?.assignments ?? const <String, String>{};

  /// Makes [regionIds] the writing the teacher chose for [questionId] —
  /// replacing any chosen for it before, and taking each region away from
  /// any other question it was chosen for. Applied at the next re-mark.
  Future<void> assignRegions(String questionId, List<String> regionIds) async {
    final MarkedScript? script = currentScript;
    if (script == null || isBusy) return;
    script.assignments = <String, String>{
      for (final MapEntry<String, String> entry in script.assignments.entries)
        if (entry.value != questionId && !regionIds.contains(entry.key)) entry.key: entry.value,
      for (final String id in regionIds) id: questionId,
    };
    script.correctionsPending = true;
    await _saveAssignments(script);
    final String name =
        assessment?.questionPaper.byId(questionId)?.displayNumber ?? questionId;
    _setStatus(regionIds.isEmpty
        ? 'Your choice for question $name was removed. Re-mark to apply it.'
        : 'Answer chosen for question $name. Re-mark to apply it.');
  }

  /// Drops the teacher's choice of answer for [questionId].
  Future<void> clearAssignments(String questionId) => assignRegions(questionId, const <String>[]);

  Future<void> _saveAssignments(MarkedScript script) async {
    final SelectedDocument? paper = _questionPaper;
    if (paper == null) return;
    try {
      await TeacherWorkStore(_pipeline().store)
          .saveAssignments(script.document.contentHash, paper.contentHash, script.assignments);
    } on IOException catch (error) {
      _fail('Your choice could not be saved.', '$error');
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
    await _recordSamples(script);
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
          paper: script.assessment?.questionPaper,
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
