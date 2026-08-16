import 'dart:io';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/exam_paper.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/services/ai/correction_service.dart';
import 'package:exam_corrector/services/file_picker_service.dart';
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

class FakeFilePicker extends FilePickerService {
  FakeFilePicker(this.path);

  final String? path;

  @override
  Future<String?> pickPdf() async => path;
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

  @override
  Future<void> save({
    String? apiKey,
    String? model,
    String? fallbackModels,
  }) async {
    if (throwOnSave) throw const FileSystemException('disk full');
    if (apiKey != null) saved = apiKey.trim().isEmpty ? null : apiKey.trim();
    if (model != null && model.trim().isNotEmpty) savedModel = model.trim();
    if (fallbackModels != null) savedFallbacks = fallbackModels.trim();
  }

  @override
  String get location => 'in-memory settings';
}

class FakePdfService extends PdfService {
  FakePdfService({this.text = 'Question 1. Extracted paper text.', this.error});

  final String text;
  final String? error;

  @override
  Future<String> extractText(String path) async {
    if (error != null) throw PdfExtractionException(error!);
    return text;
  }

  @override
  Future<ExamPaper> loadExamPaper(String path) async {
    final String extracted = await extractText(path);
    return ExamPaper(filePath: path, fileName: 'paper.pdf', text: extracted);
  }
}

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

  String? receivedPaper;
  String? receivedMarkScheme;
  int callCount = 0;

  @override
  Future<CorrectionResult> correct({
    required String paperText,
    required String markSchemeText,
    CorrectionProgress? onProgress,
  }) async {
    if (progressMessage != null) onProgress?.call(progressMessage!);
    callCount++;
    receivedPaper = paperText;
    receivedMarkScheme = markSchemeText;
    if (error != null) throw CorrectionException(error!);
    return result;
  }
}
