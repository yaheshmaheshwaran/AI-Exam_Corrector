import 'dart:io';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/exam_paper.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/services/ai/correction_service.dart';
import 'package:exam_corrector/services/file_picker_service.dart';
import 'package:exam_corrector/services/ocr/ocr_service.dart';
import 'package:exam_corrector/services/pdf_service.dart';
import 'package:exam_corrector/services/settings_store.dart';

const AppConfig configuredApp = AppConfig(
  apiKey: 'test-key',
  model: 'gemini-3.7-flash',
  effort: 'high',
  maxTokens: 32000,
);

const CorrectionResult sampleResult = CorrectionResult(
  questions: <QuestionResult>[
    QuestionResult(
      questionNumber: '1',
      maximumMarks: 2,
      awardedMarks: 1,
      studentAnswer: 'The mitochondrion makes ATP.',
      evaluation: 'Names ATP but omits the site.',
      markingPoints: <MarkingPoint>[
        MarkingPoint(criterion: 'Names ATP', satisfied: true, marks: 1),
        MarkingPoint(
          criterion: 'Identifies the site',
          satisfied: false,
          marks: 0,
        ),
      ],
    ),
  ],
  totalMarks: 1,
  maximumTotalMarks: 2,
  percentage: 50,
  // Not the configured primary: the sample stands for a paper marked after a
  // quota fallback, which is exactly what the result must disclose.
  model: 'gemini-3.6-flash',
);

/// A paper the model could find no answers in — what you get from marking a
/// mark scheme or a blank question paper.
const CorrectionResult unansweredResult = CorrectionResult(
  questions: <QuestionResult>[
    QuestionResult(
      questionNumber: '1',
      maximumMarks: 2,
      awardedMarks: 0,
      studentAnswer: 'No answer found',
      evaluation: 'No student answer could be located for this question.',
      markingPoints: <MarkingPoint>[
        MarkingPoint(criterion: 'Names ATP', satisfied: false, marks: 0),
      ],
    ),
  ],
  totalMarks: 0,
  maximumTotalMarks: 2,
  percentage: 0,
  model: 'gemini-3.6-flash',
);

/// Returns prepared paths in order, so the two document slots can be filled
/// with different files. The last path repeats once the list runs out.
class FakeFilePicker extends FilePickerService {
  FakeFilePicker(String? path, [String? then])
      : _paths = <String?>[path, ?then];

  FakeFilePicker.sequence(List<String?> paths) : _paths = paths;

  final List<String?> _paths;
  int _calls = 0;

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
}

/// Keeps the saved key in memory so tests never touch the real user profile.
class RecordingSettingsStore extends SettingsStore {
  RecordingSettingsStore({this.throwOnSave = false});

  final bool throwOnSave;
  String? saved;
  String? savedModel;
  String? savedFallbacks;

  @override
  Future<Map<String, String>> read() async => <String, String>{
        if (saved case final String key) SettingsStore.apiKeyField: key,
        if (savedModel case final String model)
          SettingsStore.modelField: model,
      };

  bool? savedOcrEnabled;
  String? savedTrocrModel;
  double? savedOcrThreshold;
  bool? savedVisionCrossCheck;
  int? savedOcrDpi;

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
  }) async {
    if (throwOnSave) throw const FileSystemException('disk full');
    if (apiKey != null) saved = apiKey.trim().isEmpty ? null : apiKey.trim();
    if (model != null && model.trim().isNotEmpty) savedModel = model.trim();
    if (fallbackModels != null) savedFallbacks = fallbackModels.trim();

    if (ocrEnabled != null) savedOcrEnabled = ocrEnabled;
    if (trocrModel != null) savedTrocrModel = trocrModel.trim();
    if (ocrThreshold != null) savedOcrThreshold = ocrThreshold;
    if (visionCrossCheck != null) savedVisionCrossCheck = visionCrossCheck;
    if (ocrDpi != null) savedOcrDpi = ocrDpi;
  }

  @override
  String get location => 'in-memory settings';
}

class FakePdfService extends PdfService {
  FakePdfService({
    this.text = 'Question 1. Extracted paper text.',
    this.error,
    this.hasTextLayer = true,
    this.textByPath = const <String, String>{},
    this.scannedPaths = const <String>{},
  });

  final String text;
  final String? error;

  /// False stands for a scan: the file is a valid PDF, it simply carries no
  /// text to extract, which is what routes a paper to handwriting recognition.
  final bool hasTextLayer;

  /// Per-path text, for tests that need the two documents to differ.
  final Map<String, String> textByPath;

  /// Paths that behave as scans while the rest keep their text layer — the
  /// realistic case, where a handwritten answer sheet is paired with a typed
  /// question paper.
  final Set<String> scannedPaths;

  @override
  Future<String?> extractTextIfPresent(String path) async {
    if (error != null) throw PdfExtractionException(error!);
    if (!hasTextLayer || scannedPaths.contains(path)) return null;
    return textByPath[path] ?? text;
  }

  @override
  Future<String> extractText(String path) async {
    final String? extracted = await extractTextIfPresent(path);
    if (extracted == null) {
      throw const PdfExtractionException('No readable text was found.');
    }
    return extracted;
  }

  @override
  Future<ExamPaper> loadExamPaper(String path) async {
    final String extracted = await extractText(path);
    return ExamPaper(filePath: path, fileName: 'paper.pdf', text: extracted);
  }
}

/// A handwriting recogniser that returns a prepared transcript.
class FakeOcrService implements OcrService {
  FakeOcrService({DocumentTranscript? transcript, this.error})
      : transcript = transcript ?? sampleTranscript;

  final DocumentTranscript transcript;
  final String? error;

  int callCount = 0;
  String? receivedPath;
  final List<String> progressMessages = <String>[];

  @override
  Future<DocumentTranscript> transcribe({
    required String path,
    OcrProgress? onProgress,
  }) async {
    callCount++;
    receivedPath = path;
    onProgress?.call('Reading page 1 of 1…', 0.5);
    progressMessages.add('Reading page 1 of 1…');
    if (error != null) throw OcrException(error!);
    return transcript;
  }

  @override
  Future<void> dispose() async {}
}

TextLine fakeLine(
  String text, {
  double confidence = 0.95,
  int y = 0,
  OcrSource source = OcrSource.trocr,
}) {
  return TextLine(
    text: text,
    ocrText: text,
    confidence: confidence,
    box: LineBox(x: 10, y: y, width: 400, height: 30),
    cropPath: '/crops/${y}_${text.hashCode}.png',
    source: source,
  );
}

/// One page, one confident line and one the recogniser struggled with.
final DocumentTranscript sampleTranscript = DocumentTranscript(
  pages: <PageTranscript>[
    PageTranscript(
      index: 0,
      imagePath: '/pages/page_000.png',
      width: 2480,
      height: 3508,
      lines: <TextLine>[
        fakeLine('1. The mitochondrion makes ATP.', y: 100),
        fakeLine('2. The rate was 12.5 mol', confidence: 0.42, y: 200),
      ],
    ),
  ],
  engine: 'microsoft/trocr-large-handwritten',
  detector: 'db_resnet50',
  dpi: 300,
  workdir: '/tmp/exam_ocr_test',
);

class FakeCorrectionService implements CorrectionService {
  FakeCorrectionService({
    this.result = sampleResult,
    this.error,
    this.progressMessage,
  });

  final CorrectionResult result;
  final String? error;

  /// Reported through `onProgress` before finishing, standing in for a
  /// rate-limit wait.
  final String? progressMessage;

  String? receivedAnswerSheet;
  String? receivedQuestionPaper;
  String? receivedGuidance;
  bool? receivedFromHandwriting;
  int callCount = 0;

  @override
  Future<CorrectionResult> correct({
    required String questionPaperText,
    required String answerSheetText,
    String guidanceText = '',
    CorrectionProgress? onProgress,
    bool fromHandwriting = false,
  }) async {
    if (progressMessage != null) onProgress?.call(progressMessage!);
    callCount++;
    receivedQuestionPaper = questionPaperText;
    receivedAnswerSheet = answerSheetText;
    receivedGuidance = guidanceText;
    receivedFromHandwriting = fromHandwriting;
    if (error != null) throw CorrectionException(error!);
    return result;
  }
}
