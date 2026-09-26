import 'dart:async';
import 'dart:io';

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
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/alignment/label_boundary_detector.dart';
import 'package:exam_corrector/pipeline/alignment/paper_question_aligner.dart';
import 'package:exam_corrector/pipeline/cache/artifact_store.dart';
import 'package:exam_corrector/pipeline/document/page_analyzer.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/exam_pipeline.dart';
import 'package:exam_corrector/pipeline/layout/text_layer_region_detector.dart';
import 'package:exam_corrector/pipeline/visual/visual_evidence_engine.dart';
import 'package:exam_corrector/services/file_picker_service.dart';
import 'package:exam_corrector/services/pdf_service.dart';
import 'package:exam_corrector/services/settings_store.dart';
import 'package:exam_corrector/state/correction_controller.dart';

const AppConfig configuredApp = AppConfig(
  apiKey: 'test-key',
  model: 'gemini-3.7-flash',
  effort: 'high',
  maxTokens: 32000,
  developerMode: true,
);

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
  String? savedModel;
  String? savedFallbacks;
  String? savedLayout;
  bool? savedDeveloperMode;
  double? savedReviewThreshold;

  @override
  Future<Map<String, String>> read() async => <String, String>{
        if (saved case final String key) SettingsStore.apiKeyField: key,
      };

  @override
  Future<void> save({
    String? apiKey,
    String? model,
    String? fallbackModels,
    bool? ocrEnabled,
    String? trocrModel,
    double? ocrThreshold,
    bool? visionCrossCheck,
    int? ocrDpi,
    String? layoutEngine,
    String? visionModel,
    double? reviewThreshold,
    bool? visualAnalysis,
    bool? developerMode,
  }) async {
    if (throwOnSave) throw const FileSystemException('disk full');
    if (apiKey != null) saved = apiKey.trim().isEmpty ? null : apiKey.trim();
    if (model != null && model.trim().isNotEmpty) savedModel = model.trim();
    if (fallbackModels != null) savedFallbacks = fallbackModels.trim();
    savedLayout = layoutEngine ?? savedLayout;
    savedDeveloperMode = developerMode ?? savedDeveloperMode;
    savedReviewThreshold = reviewThreshold ?? savedReviewThreshold;
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
class MemoryArtifactStore extends ArtifactStore {
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

/// Renders two pages without writing anything: no images, so nothing needs
/// the disk.
class FakeRenderer implements DocumentRenderer {
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
    onProgress?.call('Rendering page 1 of 1…', 0.5);
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
          width: 1000,
          height: 1400,
        ),
      ],
    );
  }
}

/// Two handwritten regions: an answer to each question.
class FakeDetector implements RegionDetector {
  @override
  String get fingerprint => 'fake-detect';

  @override
  Future<RegionDetection> detect(
    ExamDocument document,
    List<ExamPage> pages, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    return RegionDetection(pages: <ExamPage>[
      for (final ExamPage page in pages)
        page.copyWith(regions: <PageRegion>[
          for (int i = 0; i < 2; i++)
            PageRegion(
              regionId: '${page.pageId}:r$i',
              pageId: page.pageId,
              pageNumber: page.pageNumber,
              type: RegionType.handwrittenAnswer,
              box: NormalizedBox(x: 0.1, y: 0.1 + i * 0.3, width: 0.8, height: 0.2),
              confidence: 0.8,
              readingOrder: i,
            ),
        ]),
    ]);
  }
}

class FakeRecognizer implements HandwritingRecognizer {
  FakeRecognizer({this.texts = const <String>[
    '1 The mitochondrion makes ATP.',
    '2 Because muscles need energy.',
  ]});

  final List<String> texts;

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
    return <String, HandwritingEvidence>{
      for (int i = 0; i < regions.length; i++)
        regions[i].regionId: HandwritingEvidence(
          regionId: regions[i].regionId,
          readings: <HandwritingReading>[
            HandwritingReading(
              source: ReadingSource.trocr,
              text: texts[i % texts.length],
              confidence: 0.95,
              uncertainSpans: i == 0
                  ? const <UncertainSpan>[
                      UncertainSpan(text: 'ATP', confidence: 0.6, start: 26, end: 29),
                    ]
                  : const <UncertainSpan>[],
            ),
          ],
        ),
    };
  }
}

/// Marks each answered question 1 out of 2, citing its first region.
class FakeMarker implements MarkingEngine {
  FakeMarker({this.error, this.gate});

  AppException? error;

  /// When set, marking waits for it — so a test can look at the processing
  /// screen while the run is in flight.
  Completer<void>? gate;

  int calls = 0;
  final List<String> marked = <String>[];
  String? lastGuidance;

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
            model: answered ? 'gemini-3.6-flash' : '',
            markingPoints: <MarkingPoint>[
              MarkingPoint(
                id: 'MP1',
                criterion: 'Names ATP',
                satisfied: answered,
                marks: answered ? 1 : 0,
                marksAvailable: 1,
                evidenceRegionIds: answered
                    ? <String>[task.answer.regionIds.last]
                    : const <String>[],
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

class FakeTextLayer implements TextLayerReader {
  @override
  Future<List<TextLayerPage>> read(String path) async => const <TextLayerPage>[];
}

/// A real pipeline over fake engines and an in-memory store.
ExamPipeline fakePipeline({
  required ArtifactStore store,
  AppConfig Function()? config,
  FakeMarker? marker,
  FakeRenderer? renderer,
  QuestionPaperExtractor? paper,
  HandwritingRecognizer? recognizer,
}) {
  return ExamPipeline(
    config: config ?? () => configuredApp,
    store: store,
    renderer: renderer ?? FakeRenderer(),
    textLayer: FakeTextLayer(),
    pageAnalyzer: const DefaultPageAnalyzer(),
    regionDetector: FakeDetector(),
    textLayerDetector: TextLayerRegionDetector(FakeTextLayer()),
    cropper: null,
    recognizer: recognizer ?? FakeRecognizer(),
    visuals: const VisualEvidenceEngine(),
    visualFingerprint: 'none',
    questionExtractor: paper ?? FakePaperExtractor(),
    boundaries: const LabelBoundaryDetector(),
    aligner: const PaperQuestionAligner(),
    marker: marker ?? FakeMarker(),
    pdf: const FakePdf(),
  );
}

/// A controller wired to fakes throughout.
CorrectionController fakeController({
  AppConfig config = configuredApp,
  FakeMarker? marker,
  FakeFilePicker? picker,
  FakeInspector? inspector,
  RecordingSettingsStore? settings,
  ArtifactStore? store,
  QuestionPaperExtractor? paper,
}) {
  final ArtifactStore artifacts = store ?? MemoryArtifactStore();
  late final CorrectionController controller;
  controller = CorrectionController(
    config: config,
    pipeline: () => fakePipeline(
      store: artifacts,
      config: () => controller.config,
      marker: marker,
      paper: paper,
    ),
    inspector: inspector ?? FakeInspector(),
    filePicker: picker ?? FakeFilePicker(answerPath, questionPath),
    settings: settings ?? RecordingSettingsStore(),
    pdfService: const FakePdf(),
  );
  return controller;
}
