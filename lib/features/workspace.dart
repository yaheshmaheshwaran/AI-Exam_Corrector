import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/llm_client.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/provider_health.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/services/background_signals.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/moderation.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/marking_guidance.dart';
import 'package:exam_corrector/marking/marking_pipeline.dart';
import 'package:exam_corrector/marking/marking_settings.dart';
import 'package:exam_corrector/services/document_inspector.dart';
import 'package:exam_corrector/services/export/report_exporter.dart';
import 'package:exam_corrector/services/file_picker_service.dart';
import 'package:exam_corrector/services/document_text_reader.dart';
import 'package:exam_corrector/services/pdf_service.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/review/marking_standard_store.dart';
import 'package:exam_corrector/services/settings_store.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/state/marked_script.dart';

/// What every feature of the marking workflow shares: the services, the
/// scripts and the question paper, the run in progress, and the status line.
///
/// Each feature — choosing documents, the answer key, the syllabus,
/// publishing, the marking standard, moderation, marking runs, review,
/// export, settings — is a mixin on this class in `lib/features/`, holding
/// its own state. What one feature needs from another is declared here as an
/// abstract hook, so the coupling between them is explicit.
abstract class Workspace extends ChangeNotifier {
  Workspace({
    required AppConfig config,
    required AiSettings ai,
    required MarkingPipeline Function() pipeline,
    DocumentInspector inspector = const LocalDocumentInspector(),
    FilePickerService filePicker = const FilePickerService(),
    SettingsStore settings = const SettingsStore(),
    PdfService pdfService = const PdfService(),
    DocumentTextReader keyReader = const DocumentTextReader(),
    ReportExporter exporter = const ReportExporter(),
    SyllabusLibrary? syllabusLibrary,
    this.usage,
    this.health,
    MarkingStandardStore? standards,
    ResultsRepository? results,
    Future<({bool ok, String message})> Function(AiSettings ai, String model)? modelCheck,
    Future<AiSettings> Function(SettingsStore settings)? aiLoader,
    DateTime Function()? clock,
    BackgroundSignals? signals,
  })  : modelCheckFn = modelCheck ?? _checkModel,
        loadAiSettings = aiLoader ?? _loadAi,
        aiSettings = ai,
        backgroundSignals = signals ?? BackgroundSignals.platform(),
        clockNow = clock ?? DateTime.now,
        appConfig = config,
        standardsStore = standards,
        resultsStore = results,
        syllabusStore = syllabusLibrary,
        pipelineOf = pipeline,
        documentInspector = inspector,
        picker = filePicker,
        settingsStore = settings,
        pdfReader = pdfService,
        keyTextReader = keyReader,
        reportExporter = exporter {
    if (!ai.hasModelAccess) {
      statusText = notReadyMessage;
      statusError = true;
    }
  }

  final MarkingPipeline Function() pipelineOf;

  /// Keeps the computer awake and reports progress during a background run.
  final BackgroundSignals backgroundSignals;
  final Future<({bool ok, String message})> Function(AiSettings ai, String model) modelCheckFn;

  /// Reads the AI settings afresh after Settings are saved.
  final Future<AiSettings> Function(SettingsStore settings) loadAiSettings;

  static Future<AiSettings> _loadAi(SettingsStore settings) => AiSettings.load(settings: settings);

  static Future<({bool ok, String message})> _checkModel(AiSettings ai, String model) =>
      LlmClient(() => ai).check(model);
  final DateTime Function() clockNow;



  /// What the teacher is told while no model can be reached at all.
  static const String notReadyMessage = AiSettings.notReadyMessage;
  final DocumentInspector documentInspector;
  final FilePickerService picker;
  final SettingsStore settingsStore;
  final PdfService pdfReader;
  final DocumentTextReader keyTextReader;
  final ReportExporter reportExporter;


  /// The teacher's saved syllabi; null where the feature is not wired up.
  final SyllabusLibrary? syllabusStore;

  /// Each paper's marking standard; null where not wired up.
  final MarkingStandardStore? standardsStore;

  /// The results database students read and raise corrections in; null
  /// where not wired up.
  final ResultsRepository? resultsStore;


  MarkingStandard paperStandard = const MarkingStandard();

  /// The standard the chosen paper is marked to.
  MarkingStandard get markingStandard => paperStandard;

  /// Whether the teacher can set a marking standard at all.
  bool get hasMarkingStandards => standardsStore != null;

  Moderation appliedModeration = Moderation.none;

  /// The moderation the paper's marks are brought to, when the teacher
  /// applied one.
  Moderation get moderation => appliedModeration;


  /// How much the AI has been asked today, and whether it is working,
  /// waiting out a rate limit or out of quota; null where not wired up.
  final UsageMonitor? usage;

  /// Which of our own model servers are unreachable; a server that stopped is
  /// checked again before each script, so one that has come back is used from
  /// the next script on.
  final ProviderHealth? health;

  AppConfig appConfig;
  AppConfig get config => appConfig;

  /// Where each model runs and which models do each job.
  AiSettings aiSettings;
  AiSettings get ai => aiSettings;

  /// The marking models, first choice first.
  List<String> get markersInUse => aiSettings.roles.chain(ModelRole.marker);

  /// Where the saved settings live, for the Settings dialog to show.
  String get settingsLocation => settingsStore.location;

  final List<MarkedScript> scriptList = <MarkedScript>[];
  int shownIndex = 0;
  bool classShown = false;
  SelectedDocument? chosenPaper;
  MarkingGuidance chosenGuidance = const MarkingGuidance.none();

  List<Syllabus> savedSyllabi = const <Syllabus>[];

  /// For the chosen paper: a syllabus ID, [SyllabusLibrary.none], or null to
  /// match automatically.
  String? chosenSyllabus;

  String? chosenGuidanceFile;

  ProcessingJob? currentJob;
  final Pulse progressPulse = Pulse();
  ProcessingJob? resumable;
  int? batchIndex;

  CancellationToken? runToken;
  bool choosing = false;

  String statusText = 'Ready.';
  bool statusError = false;
  String? pendingErrorText;

  /// Every student script chosen: one, or a class set.
  List<MarkedScript> get scripts => List<MarkedScript>.unmodifiable(scriptList);

  /// The script whose results are on screen.
  MarkedScript? get currentScript =>
      scriptList.isEmpty ? null : scriptList[shownIndex.clamp(0, scriptList.length - 1)];

  int get currentIndex => shownIndex;

  /// More than one script: a class set.
  bool get isClass => scriptList.length > 1;

  /// The class table is showing, rather than one student's results.
  bool get showingClass => isClass && classShown;

  /// While a class is being marked: which script, from 1.
  int? get batchPosition => batchIndex;

  SelectedDocument? get answerSheet => currentScript?.document;

  /// The authority for which questions exist, their sections and marks.
  SelectedDocument? get questionPaper => chosenPaper;


  MarkingGuidance get guidance => chosenGuidance;

  /// The file the guidance was loaded from, if it was.
  String? get guidanceFile => chosenGuidanceFile;

  /// How much of the question paper carries its own printed mark scheme —
  /// known once the paper has been read, and null when it prints none.
  ({int withScheme, int questions})? get paperScheme {
    final QuestionPaper? paper = scriptList
        .map((MarkedScript s) => s.assessment?.questionPaper)
        .nonNulls
        .firstOrNull;
    if (paper == null || !paper.hasMarkScheme) return null;
    return (withScheme: paper.markSchemeCount, questions: paper.markable.length);
  }

  /// The correction in progress, or the last one.
  ProcessingJob? get job => currentJob;

  /// Fires as a correction moves within a stage — often. Only what shows
  /// the progress ([job], [statusMessage]) listens here; everything else
  /// listens to the controller, which fires when a job or stage begins.
  Listenable get progress => progressPulse;

  @override
  void dispose() {
    progressPulse.dispose();
    // Never leave the computer held awake by a run that cannot finish.
    if (backgroundRun) unawaited(backgroundSignals.keepAwake(false));
    super.dispose();
  }


  /// A saved, unfinished run of the chosen pair of documents.
  ProcessingJob? get resumableJob => resumable;

  ExamAssessment? get assessment => currentScript?.assessment;
  CorrectionResult? get result => assessment?.result;
  TeacherReviewBook get reviews => currentScript?.reviews ?? const TeacherReviewBook();

  /// The teacher's readings of regions, keyed by region ID.
  Map<String, String> get transcriptions =>
      currentScript?.transcriptions ?? const <String, String>{};

  /// Transcriptions were corrected since the paper was last marked.
  bool get hasPendingCorrections => currentScript?.correctionsPending ?? false;

  String get statusMessage => statusText;
  bool get statusIsError => statusError;

  /// An error worth interrupting the teacher for. Cleared once shown.
  String? get pendingError => pendingErrorText;

  bool get isProcessing => runToken != null;
  bool get isChoosing => choosing;
  bool get isBusy => isProcessing || choosing;

  /// Kept for the status bar: marking is the long wait the teacher sees.
  bool get isCorrecting => isProcessing;

  bool get canCorrect =>
      scriptList.isNotEmpty && chosenPaper != null && !isBusy;

  /// Whether more scripts can be added now: between runs, and during a
  /// background run, whose queue they join.
  bool get canAddScripts => scriptList.isNotEmpty && !choosing && (!isProcessing || backgroundRun);

  // --------------------------------------------------------------------------

  void clearError() {
    if (pendingErrorText == null) return;
    pendingErrorText = null;
    notifyListeners();
  }

  void setStatus(String message) {
    statusText = message;
    statusError = false;
    notifyListeners();
  }

  void fail(String status, String detail) {
    statusText = status;
    statusError = true;
    pendingErrorText = detail;
    notifyListeners();
  }

  void raiseError(String detail) {
    pendingErrorText = detail;
    notifyListeners();
  }

  // --------------------------------------------------------------------------
  // Shared helpers
  // --------------------------------------------------------------------------

  /// How the pipeline marks: the AI settings, with the teacher's review
  /// threshold.
  MarkingSettings get markingSettings => MarkingSettings(ai: aiSettings, reviewThreshold: appConfig.reviewThreshold);

  /// Whether the run under way is a background run: the class table stays
  /// usable, scripts may be added, and the computer is kept awake.
  bool get isBackgroundRun => backgroundRun;

  bool backgroundRun = false;

  /// [model] as the teacher reads it: where it runs, and its name.
  String modelLabel(String model) {
    final ModelProvider? provider = aiSettings.providers.of(model);
    final String name = provider == null ? model : provider.modelId(model);
    return provider == null ? name : '${provider.label} ($name)';
  }

  Future<String?> writeFile(String path, String content) async {
    try {
      await File(path).writeAsString(content);
      setStatus('Report saved to $path.');
      return path;
    } on IOException catch (error) {
      fail('The report could not be saved.', '$error');
      return null;
    }
  }

  String describe(SelectedDocument document) {
    final String pages = '${document.pageCount} page${document.pageCount == 1 ? '' : 's'}';
    final String kind = switch (document.source) {
      DocumentSource.textLayer => 'typed',
      DocumentSource.scanned => 'scanned',
      DocumentSource.mixed => 'part typed, part scanned',
      DocumentSource.image => 'photograph',
    };
    return '${document.fileName}, $pages, $kind';
  }

  /// Scripts the current run has taken up; null between runs.
  Set<MarkedScript>? runAttempted;

  // --------------------------------------------------------------------------
  // What one feature asks of another — implemented by the feature named.
  // --------------------------------------------------------------------------

  /// The saved reviews, corrections and assignments of [script] (inputs).
  @protected
  Future<void> loadSavedWork(MarkedScript script);

  /// An unfinished run of the chosen documents, to offer resuming (inputs).
  @protected
  Future<void> loadResumable();

  /// Matches the chosen paper to a saved syllabus (syllabus).
  @protected
  Future<void> prepareSyllabus(SelectedDocument paper);

  /// The paper's saved moderation and the teacher's samples (moderation).
  @protected
  Future<void> loadModeration();

  /// Records the teacher's marks on [script] as moderation samples
  /// (moderation).
  @protected
  Future<void> recordSamples(MarkedScript script);

  /// The teacher's own key for the chosen paper (answer key).
  @protected
  Future<void> loadTeacherKey();

  /// Who wrote the AI's key and whether it was checked (answer key).
  @protected
  Future<void> refreshAiKey();

  /// Saves [script]'s reviews (review).
  @protected
  Future<void> persistReviews(MarkedScript script);

  /// Applies the standard again to the marked scripts, from the cache
  /// (marking standard).
  @protected
  Future<void> rerunFromCache(String done);

  /// Starts marking the class in the background when it can; whether it did
  /// (marking run).
  @protected
  bool startInBackground();

  /// Runs the pipeline for one script (marking run).
  @protected
  Future<ExamAssessment?> runScript(
    MarkedScript script,
    CancellationToken token, {
    bool backup = false,
    void Function()? onMarking,
  });

}

class Pulse extends ChangeNotifier {
  void pulse() => notifyListeners();
}
