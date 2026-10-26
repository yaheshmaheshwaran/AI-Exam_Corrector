import 'dart:async';
import 'dart:io';

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/model_request.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/provider_health.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/marking/contracts.dart';
import 'package:exam_corrector/marking/document_reader.dart';
import 'package:exam_corrector/marking/marking_pipeline.dart';
import 'package:exam_corrector/marking/script/page_reader.dart';
import 'package:exam_corrector/marking/script/pages.dart';
import 'package:exam_corrector/marking/marking_settings.dart';
import 'package:exam_corrector/marking/stage_store.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/services/background_signals.dart';
import 'package:exam_corrector/services/document_inspector.dart';
import 'package:exam_corrector/services/file_picker_service.dart';
import 'package:exam_corrector/services/pdf_service.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/review/marking_standard_store.dart';
import 'package:exam_corrector/services/settings_store.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/state/correction_controller.dart';

const AppConfig configuredApp = AppConfig(developerMode: true);

/// The model every fake run marks with, first in the marking job.
const String fakeMarker = 'gemini/gemini-3.6-flash';

/// The backup marker, used only on a backup run.
const String fakeBackupMarker = 'gemini/gemini-3.7-flash';

/// AI settings with a Gemini key and two marking models — nothing read from
/// the environment or a real .env.
AiSettings fakeAi({Map<String, String> values = const <String, String>{}}) => AiSettings.fromMap(<String, String>{
      Providers.geminiKeyName: 'test-key',
      ModelRole.marker.settingName: '$fakeMarker, $fakeBackupMarker',
      ...values,
    });

const String answerPath = 'C:\\papers\\answers.pdf';
const String secondPath = 'C:\\papers\\bailey.pdf';
const String thirdPath = 'C:\\papers\\chen.pdf';
const String questionPath = 'C:\\papers\\questions.pdf';

/// Returns prepared paths in order, so the two document slots can be filled
/// with different files. The last path repeats once the list runs out.
class FakeFilePicker extends FilePickerService {
  FakeFilePicker(String? path, [String? then]) : _paths = <String?>[path, ?then];

  FakeFilePicker.sequence(List<String?> paths) : _paths = paths;

  final List<String?> _paths;
  int _calls = 0;
  String? guidancePath;
  String? syllabusPath;

  /// When set, the next choice of answer sheets returns all of these: a
  /// teacher selecting a class set in one go.
  List<String>? classSet;
  String? savePath;
  String? lastSuggestedName;

  String? get _next {
    if (_paths.isEmpty) return null;
    final int index = _calls < _paths.length ? _calls : _paths.length - 1;
    _calls++;
    return _paths[index];
  }

  @override
  Future<String?> pickPdf() async => _next;

  @override
  Future<String?> pickDocument() async => _next;

  @override
  Future<List<String>> pickDocuments() async {
    final List<String>? set = classSet;
    if (set != null) {
      classSet = null;
      return set;
    }
    final String? next = _next;
    return next == null ? const <String>[] : <String>[next];
  }

  @override
  Future<String?> pickGuidance() async => guidancePath;

  String? answerKeyPath;

  @override
  Future<String?> pickAnswerKey() async => answerKeyPath;

  @override
  Future<String?> pickSyllabus() async => syllabusPath;

  @override
  Future<String?> pickSaveLocation({
    required String suggestedName,
    required String extension,
  }) async {
    lastSuggestedName = suggestedName;
    return savePath;
  }
}

/// Keeps settings in memory so tests never touch the real user profile.
class RecordingSettingsStore extends SettingsStore {
  RecordingSettingsStore({this.throwOnSave = false});

  final bool throwOnSave;
  String? saved;
  bool? savedDeveloperMode;
  double? savedReviewThreshold;
  bool? savedBackground;
  bool? savedSounds;
  double? savedTransparency;
  String? savedServerUrl;
  String? savedServerKey;
  String? savedNvidia;
  String? savedPrepModels;
  String? savedReaderModels;
  String? savedMarkerModels;
  Map<String, String> savedServers = <String, String>{};

  @override
  Future<Map<String, String>> read() async => <String, String>{
        if (saved case final String key) SettingsStore.apiKeyField: key,
        if (savedServerUrl case final String url) SettingsStore.supabaseUrlField: url,
        if (savedServerKey case final String key) SettingsStore.supabaseAnonKeyField: key,
        if (savedNvidia case final String key) SettingsStore.nvidiaKeyField: key,
        if (savedPrepModels case final String models) SettingsStore.prepModelsField: models,
        if (savedReaderModels case final String models) SettingsStore.readerModelsField: models,
        if (savedMarkerModels case final String models) SettingsStore.markerModelsField: models,
        ...savedServers,
      };

  @override
  Future<void> save({
    String? apiKey,
    String? nvidiaKey,
    String? prepModels,
    String? readerModels,
    String? markerModels,
    double? reviewThreshold,
    bool? backgroundProcessing,
    bool? developerMode,
    bool? sounds,
    double? transparency,
    String? supabaseUrl,
    String? supabaseAnonKey,
    Map<String, String> openModels = const <String, String>{},
  }) async {
    if (throwOnSave) throw const FileSystemException('disk full');
    if (supabaseUrl != null || supabaseAnonKey != null) {
      savedServerUrl = supabaseUrl ?? savedServerUrl;
      savedServerKey = supabaseAnonKey ?? savedServerKey;
      return;
    }
    if (sounds != null || transparency != null) {
      savedSounds = sounds ?? savedSounds;
      savedTransparency = transparency ?? savedTransparency;
      return;
    }
    String? kept(String? value, String? old) => value == null ? old : (value.trim().isEmpty ? null : value.trim());
    saved = kept(apiKey, saved);
    savedNvidia = kept(nvidiaKey, savedNvidia);
    savedPrepModels = kept(prepModels, savedPrepModels);
    savedReaderModels = kept(readerModels, savedReaderModels);
    savedMarkerModels = kept(markerModels, savedMarkerModels);
    openModels.forEach((String key, String value) {
      if (value.trim().isEmpty) {
        savedServers.remove(key);
      } else {
        savedServers[key] = value.trim();
      }
    });
    savedDeveloperMode = developerMode ?? savedDeveloperMode;
    savedReviewThreshold = reviewThreshold ?? savedReviewThreshold;
    savedBackground = backgroundProcessing ?? savedBackground;
  }

  @override
  String get location => 'in-memory settings';
}

/// Validates by path: known paths become documents, anything else fails.
class FakeInspector implements DocumentInspector {
  FakeInspector({this.error, Map<String, SelectedDocument>? documents})
      : documents = documents ??
            <String, SelectedDocument>{
              answerPath: document(answerPath, DocumentRole.answerSheet, 'answers'),
              secondPath: document(secondPath, DocumentRole.answerSheet, 'bailey'),
              thirdPath: document(thirdPath, DocumentRole.answerSheet, 'chen'),
              questionPath: document(questionPath, DocumentRole.questionPaper, 'questions'),
            };

  final String? error;
  final Map<String, SelectedDocument> documents;

  static SelectedDocument document(
    String path,
    DocumentRole role,
    String hash, {
    DocumentSource source = DocumentSource.scanned,
  }) =>
      SelectedDocument(
        role: role,
        filePath: path,
        fileName: path.split('\\').last,
        contentHash: hash,
        byteCount: 1000,
        pageCount: 2,
        source: source,
      );

  @override
  Future<SelectedDocument> inspect(String path, DocumentRole role) async {
    if (error != null) throw PdfExtractionException(error!);
    final SelectedDocument? found = documents[path];
    if (found == null) throw PdfExtractionException('File not found: $path');
    return SelectedDocument(
      role: role,
      filePath: found.filePath,
      fileName: found.fileName,
      contentHash: found.contentHash,
      byteCount: found.byteCount,
      pageCount: found.pageCount,
      source: found.source,
    );
  }
}

/// An artifact store that never touches the disk, so widget tests run under
/// the test binding's fake clock.
class MemoryArtifactStore extends StageStore {
  MemoryArtifactStore() : super(Directory('/memory'));

  final Map<String, JsonMap> files = <String, JsonMap>{};

  @override
  Future<JsonMap?> read(String documentHash, String key) async =>
      files['$documentHash/$key'];

  @override
  Future<void> write(String documentHash, String key, JsonMap value) async {
    files['$documentHash/$key'] = value;
  }

  @override
  Future<void> remove(String documentHash, String key) async {
    files.remove('$documentHash/$key');
  }

  @override
  Future<Directory> folder(String documentHash, String name) async =>
      Directory('/memory/$documentHash/$name');

  @override
  Future<void> clear() async => files.clear();
}

class FakePdf extends PdfService {
  const FakePdf();

  @override
  Future<String?> extractTextIfPresent(String path) async => 'Q1 Name it. [2 marks]';

  @override
  Future<String> extractText(String path) async => 'Guidance from a PDF.';
}

/// Says no document has a text layer, so nothing opens a real PDF.
class FakeDocuments extends DocumentReader {
  const FakeDocuments();

  @override
  Future<String?> textIfPresent(String path) async => null;
}

/// The question paper every fake run uses: two questions of two marks.
QuestionPaper twoQuestionPaper() => QuestionPaper(
      documentId: 'questions',
      title: 'Biology',
      questions: <Question>[
        Question(
          label: QuestionLabel.parse('1')!,
          questionText: 'Name the organelle that makes ATP.',
          maximumMarks: 2,
          marksStated: true,
        ),
        Question(
          label: QuestionLabel.parse('2')!,
          questionText: 'Explain why muscle cells have many mitochondria.',
          maximumMarks: 2,
          marksStated: true,
        ),
      ],
    );

class FakePaperExtractor implements QuestionPaperExtractor {
  FakePaperExtractor({QuestionPaper? paper}) : paper = paper ?? twoQuestionPaper();

  final QuestionPaper paper;

  @override
  String get fingerprint => 'fake-paper';

  @override
  Future<QuestionPaper> extract(
    QuestionPaperSourceData source, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async =>
      paper;
}

/// Renders one page without writing anything: no image, so nothing needs
/// the disk.
class FakeRenderer extends PageRenderer {
  int calls = 0;

  /// Every file rendered, in order.
  final List<String> rendered = <String>[];

  @override
  String get fingerprint => 'fake-render';

  @override
  Future<List<ExamPage>> render(
    String pdfPath, {
    required String documentId,
    required Directory folder,
    void Function(int done, int total)? onPage,
    CancellationToken? cancel,
  }) async {
    calls++;
    rendered.add(pdfPath.split(RegExp(r'[\\/]')).last);
    onPage?.call(1, 1);
    return <ExamPage>[
      ExamPage(pageId: ExamPage.idFor(documentId, 1), pageNumber: 1, width: 1000, height: 1400),
    ];
  }
}

/// Reads two handwritten answers on every page: one to each question.
class FakePageReader extends PageReader {
  FakePageReader({this.texts = const <String>[
    '1 The mitochondrion makes ATP.',
    '2 Because muscles need energy.',
  ]}) : super(_NoModel(), models: const <String>['gemini/fake-reader']);

  final List<String> texts;
  int calls = 0;

  @override
  String get fingerprint => 'fake-read';

  @override
  Future<PageReadout> read(
    List<ExamPage> pages, {
    required Directory cropFolder,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) async {
    calls++;
    cancel?.throwIfCancelled();
    final Map<String, HandwritingEvidence> handwriting = <String, HandwritingEvidence>{};
    final List<ExamPage> read = <ExamPage>[];
    for (final ExamPage page in pages) {
      final List<PageRegion> regions = <PageRegion>[
        for (int i = 0; i < texts.length; i++)
          PageRegion(
            regionId: '${page.pageId}:r$i',
            pageId: page.pageId,
            pageNumber: page.pageNumber,
            type: RegionType.handwrittenAnswer,
            box: NormalizedBox(x: 0.1, y: 0.1 + i * 0.3, width: 0.8, height: 0.2),
            confidence: 0.8,
            readingOrder: i,
            origin: RegionOrigin.vision,
          ),
      ];
      for (int i = 0; i < regions.length; i++) {
        handwriting[regions[i].regionId] = HandwritingEvidence(
          regionId: regions[i].regionId,
          readings: <HandwritingReading>[
            HandwritingReading(
              source: ReadingSource.vision,
              text: texts[i],
              confidence: 0.95,
              uncertainSpans: i == 0
                  ? const <UncertainSpan>[UncertainSpan(text: 'ATP', confidence: 0.6, start: 26, end: 29)]
                  : const <UncertainSpan>[],
            ),
          ],
        );
      }
      read.add(page.copyWith(regions: regions));
    }
    return PageReadout(
      pages: read,
      handwriting: handwriting,
      visuals: const <String, VisualEvidence>{},
      models: <int, String>{for (final ExamPage page in pages) page.pageNumber: 'gemini/fake-reader'},
    );
  }
}

/// The page reader's model, never asked.
class _NoModel implements ModelClient {
  @override
  bool get isAvailable => true;

  @override
  Future<ModelResponse> requestJson(
    ModelRequest request, {
    required List<String> models,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) =>
      throw StateError('The fake pipeline asks no model.');
}

/// Marks each answered question 1 out of 2, citing its last region.
class FakeMarker implements MarkingEngine {
  FakeMarker({this.error, this.gate});

  AppException? error;

  /// When set, marking waits for it — so a test can look at the processing
  /// screen while the run is in flight.
  Completer<void>? gate;

  int calls = 0;
  final List<String> marked = <String>[];
  String? lastGuidance;

  /// The models each call was allowed, in order.
  final List<List<String>?> allowed = <List<String>?>[];

  @override
  String get fingerprint => 'fake-mark';

  @override
  Future<List<QuestionResult>> mark(
    List<MarkingTask> tasks, {
    required String guidance,
    required bool typedAnswerSheet,
    String? judge,
    List<String>? models,
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    calls++;
    allowed.add(models);
    lastGuidance = guidance;
    onProgress?.call('Marking questions…', 0.5);
    if (gate != null) await gate!.future;
    cancel?.throwIfCancelled();
    if (error != null) throw error!;
    return <QuestionResult>[
      for (final MarkingTask task in tasks)
        () {
          marked.add(task.question.questionId);
          final bool answered = !task.answer.isEmpty;
          return QuestionResult(
            questionNumber: task.question.displayNumber,
            questionId: task.question.questionId,
            questionText: task.question.questionText,
            maximumMarks: task.question.maximumMarks ?? 0,
            awardedMarks: answered ? 1 : 0,
            studentAnswer: answered ? task.answer.text : 'No answer found',
            evaluation: answered ? 'Names ATP but omits the site.' : 'No answer found.',
            confidence: task.question.questionId == 'Q2' ? 0.55 : 0.9,
            needsReview: task.question.questionId == 'Q2',
            reviewReasons: task.question.questionId == 'Q2'
                ? const <String>['Handwriting was hard to read.']
                : const <String>[],
            evidenceRegionIds: task.answer.regionIds,
            answerPages: task.answer.pages,
            model: answered ? models?.first ?? judge ?? fakeMarker : '',
            markingPoints: <MarkingPoint>[
              MarkingPoint(
                id: 'MP1',
                criterion: 'Names ATP',
                satisfied: answered,
                marks: answered ? 1 : 0,
                marksAvailable: 1,
                evidenceRegionIds: answered ? <String>[task.answer.regionIds.last] : const <String>[],
              ),
              const MarkingPoint(
                id: 'MP2',
                criterion: 'Identifies the site',
                satisfied: false,
                marks: 0,
                marksAvailable: 1,
              ),
            ],
          );
        }(),
    ];
  }
}

/// A real pipeline over fake engines and an in-memory store.
MarkingPipeline fakePipeline({
  required StageStore store,
  AiSettings Function()? ai,
  FakeMarker? marker,
  FakeRenderer? renderer,
  QuestionPaperExtractor? paper,
  FakePageReader? reader,
}) {
  final FakePageReader pages = reader ?? FakePageReader();
  return MarkingPipeline(
    settings: () => MarkingSettings(ai: (ai ?? fakeAi)()),
    store: store,
    client: _NoModel(),
    renderer: renderer ?? FakeRenderer(),
    documents: const FakeDocuments(),
    reader: (_) => pages,
    questionExtractor: paper ?? FakePaperExtractor(),
    // Keys come only from what a test saves itself.
    writeAnswerKeys: false,
    marker: marker ?? FakeMarker(),
  );
}

/// A controller wired to fakes throughout.
CorrectionController fakeController({
  AppConfig config = configuredApp,
  AiSettings? ai,
  FakeMarker? marker,
  FakeFilePicker? picker,
  FakeInspector? inspector,
  RecordingSettingsStore? settings,
  StageStore? store,
  QuestionPaperExtractor? paper,
  SyllabusLibrary? syllabi,
  MarkingStandardStore? standards,
  ResultsRepository? results,
  UsageMonitor? usage,
  FakeRenderer? renderer,
  FakePageReader? reader,
  Future<({bool ok, String message})> Function(AiSettings ai, String model)? modelCheck,
  DateTime Function()? clock,
  BackgroundSignals? signals,
  ProviderHealth? health,
}) {
  final StageStore artifacts = store ?? MemoryArtifactStore();
  final RecordingSettingsStore saved = settings ?? RecordingSettingsStore();
  late final CorrectionController controller;
  controller = CorrectionController(
    config: config,
    ai: ai ?? fakeAi(),
    pipeline: () => fakePipeline(
      store: artifacts,
      ai: () => controller.ai,
      marker: marker,
      paper: paper,
      renderer: renderer,
      reader: reader,
    ),
    inspector: inspector ?? FakeInspector(),
    filePicker: picker ?? FakeFilePicker(answerPath, questionPath),
    settings: saved,
    pdfService: const FakePdf(),
    syllabusLibrary: syllabi,
    standards: standards,
    results: results,
    usage: usage,
    modelCheck: modelCheck,
    aiLoader: (SettingsStore store) async => AiSettings.fromMap(await store.read()),
    clock: clock,
    signals: signals ?? const NoBackgroundSignals(),
    health: health,
  );
  return controller;
}
