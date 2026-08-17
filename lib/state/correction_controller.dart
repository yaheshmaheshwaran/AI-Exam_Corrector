import 'package:flutter/foundation.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/exam_paper.dart';
import 'package:exam_corrector/models/marking_guidance.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';
import 'package:exam_corrector/services/ai/correction_service.dart';
import 'package:exam_corrector/services/ai/vision_transcription_service.dart';
import 'package:exam_corrector/services/file_picker_service.dart';
import 'package:exam_corrector/services/ocr/document_ingest_service.dart';
import 'package:exam_corrector/services/ocr/ocr_service.dart';
import 'package:exam_corrector/services/pdf_service.dart';
import 'package:exam_corrector/services/settings_store.dart';

/// Which of the two documents a transcript belongs to.
enum ReviewTarget {
  answerSheet('answer sheet'),
  questionPaper('question paper');

  const ReviewTarget(this.label);

  /// How the document is named to the teacher, mid-sentence.
  final String label;
}

/// What the application is doing right now.
enum CorrectionStage {
  idle,
  readingPaper,

  /// Running the handwriting pipeline: rendering, detecting, recognising.
  /// Separate from [readingPaper] because it takes minutes rather than
  /// milliseconds and reports a determinate fraction.
  transcribing,

  /// The transcript is waiting for the teacher to check it before marking.
  reviewingTranscript,

  correcting,
}

/// Owns the workflow: paper in, mark scheme in, correction out.
///
/// Holds no marking logic of its own — it sequences the services and exposes
/// the result the widgets render. A plain [ChangeNotifier] is enough state
/// management for a single-window tool; nothing here needs a larger framework.
class CorrectionController extends ChangeNotifier {
  CorrectionController({
    required AppConfig config,
    required CorrectionService correctionService,
    PdfService pdfService = const PdfService(),
    FilePickerService filePicker = const FilePickerService(),
    SettingsStore settings = const SettingsStore(),
    OcrService? ocrService,
    VisionTranscriptionService? visionService,
    DocumentIngestService? ingestService,
  })  : _config = config,
        _correctionService = correctionService,
        _filePicker = filePicker,
        _settings = settings,
        _ocrService = ocrService {
    // Built here rather than injected so the ingest service reads this
    // controller's live config, the same way the correction service does.
    _ingest = ingestService ??
        DocumentIngestService(
          configProvider: () => _config,
          ocrService: ocrService ?? const UnavailableOcrService(),
          visionService: visionService ?? VisionTranscriptionService(() => _config),
          pdfService: pdfService,
        );

    if (!config.hasApiKey) {
      _statusMessage = 'No API key set — open Settings to add one.';
      _statusIsError = true;
    }
  }

  final CorrectionService _correctionService;
  final FilePickerService _filePicker;
  final SettingsStore _settings;
  final OcrService? _ocrService;

  late final DocumentIngestService _ingest;

  AppConfig _config;

  AppConfig get config => _config;

  /// Where the saved key lives, for the Settings dialog to show.
  String get settingsLocation => _settings.location;

  /// Saves what the teacher typed in Settings and makes it live immediately.
  ///
  /// The correction service reads the key and model from this controller's
  /// config on every request, so there is nothing to restart.
  Future<void> saveSettings({
    required String apiKey,
    required String model,
    String fallbackModels = '',
    bool? ocrEnabled,
    String? trocrModel,
    double? ocrThreshold,
    bool? visionCrossCheck,
    int? ocrDpi,
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
        );

    if (_config.hasApiKey) {
      _setStatus('Settings saved. Ready to mark with ${_config.model}.');
    } else {
      _statusMessage = 'No API key set — open Settings to add one.';
      _statusIsError = true;
      notifyListeners();
    }
  }

  ExamPaper? _answerSheet;
  ExamPaper? _questionPaper;
  MarkingGuidance _guidance = const MarkingGuidance.none();
  CorrectionResult? _result;
  CorrectionStage _stage = CorrectionStage.idle;
  String _statusMessage = 'Ready.';
  bool _statusIsError = false;
  String? _pendingError;

  List<String> _ingestWarnings = const <String>[];
  double _ocrProgress = 0;

  /// Which document the review screen is showing.
  ///
  /// Either document can arrive as a scan, and a misread mark allocation on the
  /// question paper is the worse of the two — it changes what the student is
  /// marked out of, for every answer. So the same review gate covers both, one
  /// at a time, and this says which.
  ReviewTarget _reviewTarget = ReviewTarget.answerSheet;

  /// The student's handwritten answers.
  ExamPaper? get answerSheet => _answerSheet;

  /// The question paper: the authority for which questions exist, what section
  /// each belongs to, and how many marks each carries.
  ExamPaper? get questionPaper => _questionPaper;

  /// The teacher's optional marking notes.
  MarkingGuidance get guidance => _guidance;

  CorrectionResult? get result => _result;
  CorrectionStage get stage => _stage;
  String get statusMessage => _statusMessage;
  bool get statusIsError => _statusIsError;

  ReviewTarget get reviewTarget => _reviewTarget;

  /// The transcript currently under review, when one is.
  DocumentTranscript? get transcript => _documentFor(_reviewTarget)?.transcript;

  /// What recognition wants the teacher to know — lines it was unsure of,
  /// cross-checks it could not run.
  List<String> get ingestWarnings => _ingestWarnings;

  /// How far through recognition we are, 0..1.
  double get ocrProgress => _ocrProgress;

  bool get isTranscribing => _stage == CorrectionStage.transcribing;

  bool get isReviewingTranscript =>
      _stage == CorrectionStage.reviewingTranscript;

  /// Whether handwriting recognition is wired up in this build.
  bool get hasOcr => _ocrService != null;

  /// Lines still below the confidence threshold in the document under review.
  int get uncertainLineCount =>
      transcript?.uncertainCount(_config.ocrConfidenceThreshold) ?? 0;

  /// An error worth interrupting the teacher for. Cleared once shown.
  String? get pendingError => _pendingError;

  bool get isBusy => _stage != CorrectionStage.idle;
  bool get isCorrecting => _stage == CorrectionStage.correcting;

  /// Both documents are required; the guidance is not. The question paper is
  /// expected to carry the marking structure on its own.
  bool get canCorrect =>
      _answerSheet != null && _questionPaper != null && !isBusy;

  ExamPaper? _documentFor(ReviewTarget target) =>
      target == ReviewTarget.answerSheet ? _answerSheet : _questionPaper;

  /// Step 1 — choose the student's answer sheet.
  Future<void> chooseAnswerSheet() =>
      _chooseDocument(ReviewTarget.answerSheet);

  /// Step 2 — choose the question paper.
  ///
  /// This is what establishes the questions, their sections and their marks, so
  /// it is required rather than optional.
  Future<void> chooseQuestionPaper() =>
      _chooseDocument(ReviewTarget.questionPaper);

  /// Loads one of the two documents and extracts its content.
  ///
  /// A PDF with a text layer is read and done. A scan or a photograph goes
  /// through handwriting recognition and then stops for review: the teacher
  /// checks what the machine read before any of it is marked.
  Future<void> _chooseDocument(ReviewTarget target) async {
    if (isBusy) return;

    final String? path = await _filePicker.pickDocument();
    if (path == null) return;

    final String name = target.label;

    _setStage(CorrectionStage.readingPaper);
    _setStatus('Reading the $name…');

    try {
      final IngestResult result = await _ingest.loadDocument(
        path,
        onProgress: _reportOcrProgress,
      );

      _store(target, result.document);
      _ingestWarnings = result.warnings;
      _ocrProgress = 0;

      if (result.needsReview) {
        // Marking cannot start until the transcript is confirmed, so the stage
        // stays out of idle and `canCorrect` stays false.
        _reviewTarget = target;
        _setStage(CorrectionStage.reviewingTranscript);
        _setStatus(
          'Handwriting recognised in the $name — check the transcript before '
          'marking.',
        );
        return;
      }

      _setStatus('${_capitalise(name)} loaded.');
      _setStage(CorrectionStage.idle);
    } on AppException catch (error) {
      _store(target, null);
      _ingestWarnings = const <String>[];
      _ocrProgress = 0;
      _fail('The $name could not be read.', error.message);
      _setStage(CorrectionStage.idle);
    }
  }

  void _store(ReviewTarget target, ExamPaper? document) {
    if (target == ReviewTarget.answerSheet) {
      _answerSheet = document;
    } else {
      _questionPaper = document;
    }
  }

  String _capitalise(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

  void _reportOcrProgress(String message, double fraction) {
    // The first OCR progress event is what tells the UI to switch from the
    // brief "reading" state to the long determinate one.
    if (_stage != CorrectionStage.transcribing) {
      _stage = CorrectionStage.transcribing;
    }
    _ocrProgress = fraction;
    _setStatus(message);
  }

  /// Replaces one line's text with the teacher's correction.
  void updateLine(int pageIndex, int lineIndex, String text) {
    final DocumentTranscript? transcript = this.transcript;
    if (transcript == null) return;

    final TextLine? line = _lineAt(transcript, pageIndex, lineIndex);
    if (line == null || line.text == text) return;

    _applyLine(
      transcript,
      pageIndex,
      lineIndex,
      // A teacher's reading is the authority; nothing downstream should treat
      // it as uncertain or offer to double-check it.
      line.copyWith(
        text: text,
        source: OcrSource.teacher,
        confidence: 1,
      ),
    );
  }

  /// Puts a line back to what the recogniser originally read.
  void revertLine(int pageIndex, int lineIndex) {
    final DocumentTranscript? transcript = this.transcript;
    if (transcript == null) return;

    final TextLine? line = _lineAt(transcript, pageIndex, lineIndex);
    if (line == null || !line.isEdited) return;

    _applyLine(
      transcript,
      pageIndex,
      lineIndex,
      line.copyWith(text: line.ocrText, source: OcrSource.trocr),
    );
  }

  TextLine? _lineAt(DocumentTranscript transcript, int page, int line) {
    if (page < 0 || page >= transcript.pages.length) return null;
    final List<TextLine> lines = transcript.pages[page].lines;
    if (line < 0 || line >= lines.length) return null;
    return lines[line];
  }

  void _applyLine(
    DocumentTranscript transcript,
    int pageIndex,
    int lineIndex,
    TextLine updated,
  ) {
    final ExamPaper? document = _documentFor(_reviewTarget);
    if (document == null) return;

    _store(
      _reviewTarget,
      document.withTranscript(
        transcript.withLine(pageIndex, lineIndex, updated),
        flagBelow: _config.ocrConfidenceThreshold,
      ),
    );
    notifyListeners();
  }

  /// The teacher has checked the transcript; marking may proceed.
  void confirmTranscript() {
    if (_stage != CorrectionStage.reviewingTranscript) return;

    final int edited = transcript?.editedCount ?? 0;
    final String name = _reviewTarget.label;

    _setStatus(
      edited == 0
          ? '${_capitalise(name)} transcript accepted as recognised.'
          : '${_capitalise(name)} transcript accepted with '
              '$edited correction(s).',
    );
    _setStage(CorrectionStage.idle);
  }

  /// Reopens a document's transcript for further checking.
  void reopenTranscript([ReviewTarget? target]) {
    if (isBusy) return;

    final ReviewTarget wanted = target ?? _reviewTarget;
    if (_documentFor(wanted)?.transcript == null) return;

    _reviewTarget = wanted;
    _setStage(CorrectionStage.reviewingTranscript);
  }

  /// Step 3 — the teacher's optional marking guidance.
  ///
  /// Notifies only when the empty/non-empty state changes, so typing does not
  /// rebuild the results list on every keystroke.
  void setGuidance(String text) {
    final bool wasEmpty = _guidance.isEmpty;
    _guidance = MarkingGuidance(text);
    if (wasEmpty != _guidance.isEmpty) notifyListeners();
  }

  void clearGuidance() {
    if (isBusy) return;
    _guidance = const MarkingGuidance.none();
    notifyListeners();
  }

  /// Step 4 — mark the answer sheet against the question paper.
  Future<void> startCorrection() async {
    if (isBusy) return;

    final ExamPaper? answerSheet = _answerSheet;
    final ExamPaper? questionPaper = _questionPaper;

    if (answerSheet == null) {
      _raise("Choose the student's answer sheet first.");
      return;
    }
    if (questionPaper == null) {
      _raise(
        'Choose the question paper. It is what establishes the questions and '
        'how many marks each is worth.',
      );
      return;
    }

    // Choosing the same file twice produces a correction where every answer is
    // missing or every question is unknown, and a request is spent finding
    // that out.
    if (_isSameDocument(answerSheet.text, questionPaper.text)) {
      _raise(
        'The answer sheet and the question paper are the same document '
        '("${answerSheet.fileName}"). Choose the student\'s completed script '
        'as the answer sheet, and the blank paper as the question paper.',
      );
      return;
    }

    _result = null;
    _setStage(CorrectionStage.correcting);
    _setStatus('Marking against the question paper…');

    try {
      final CorrectionResult result = await _correctionService.correct(
        questionPaperText: questionPaper.text,
        answerSheetText: answerSheet.text,
        guidanceText: _guidance.trimmed,
        // A rate-limit wait would otherwise look like a hang.
        onProgress: _setStatus,
        // Transcription noise must not be marked as if the student wrote it.
        // Either document may have come from a scan.
        fromHandwriting:
            answerSheet.isHandwritten || questionPaper.isHandwritten,
      );
      _result = result;
      _setStatus(_summarise(result));
    } on AppException catch (error) {
      _fail('Correction failed.', error.message);
    } catch (error) {
      // A worker failure must never take the application down.
      _fail('Correction failed.', 'Unexpected error during correction: $error');
    } finally {
      _setStage(CorrectionStage.idle);
    }
  }

  /// True when two extractions are the same document, ignoring the page
  /// markers the PDF service adds and any difference in spacing.
  bool _isSameDocument(String left, String right) {
    String normalise(String text) => text
        .split('\n')
        .where((String line) => !line.startsWith('--- Page '))
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();

    final String first = normalise(left);
    return first.isNotEmpty && first == normalise(right);
  }

  void clearError() {
    if (_pendingError == null) return;
    _pendingError = null;
    notifyListeners();
  }

  String _summarise(CorrectionResult result) {
    final int count = result.questions.length;
    final String plural = count == 1 ? '' : 's';
    final StringBuffer summary = StringBuffer(
      'Marked $count question$plural: '
      '${formatMarks(result.totalMarks)} / '
      '${formatMarks(result.maximumTotalMarks)} '
      '(${formatPercentage(result.percentage)}).',
    );
    if (result.warnings.isNotEmpty) {
      summary.write(
        ' ${result.warnings.length} adjustment(s) applied — see the result.',
      );
    }
    return summary.toString();
  }

  void _setStage(CorrectionStage stage) {
    _stage = stage;
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
