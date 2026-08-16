import 'package:flutter/foundation.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/exam_paper.dart';
import 'package:exam_corrector/models/mark_scheme.dart';
import 'package:exam_corrector/services/ai/correction_service.dart';
import 'package:exam_corrector/services/file_picker_service.dart';
import 'package:exam_corrector/services/pdf_service.dart';
import 'package:exam_corrector/services/settings_store.dart';

/// What the application is doing right now.
enum CorrectionStage {
  idle,
  readingPaper,
  readingMarkScheme,
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
  })  : _config = config,
        _correctionService = correctionService,
        _pdfService = pdfService,
        _filePicker = filePicker,
        _settings = settings {
    if (!config.hasApiKey) {
      _statusMessage = 'No API key set — open Settings to add one.';
      _statusIsError = true;
    }
  }

  final CorrectionService _correctionService;
  final PdfService _pdfService;
  final FilePickerService _filePicker;
  final SettingsStore _settings;

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
  }) async {
    try {
      await _settings.save(
        apiKey: apiKey,
        model: model,
        fallbackModels: fallbackModels,
      );
    } on Exception catch (error) {
      _fail('Settings could not be saved.', 'Could not save settings: $error');
      return;
    }

    _config = _config
        .withApiKey(apiKey.trim().isEmpty ? null : apiKey.trim())
        .withModel(model)
        .withFallbackModels(AppConfig.parseModelList(fallbackModels));

    if (_config.hasApiKey) {
      _setStatus('Settings saved. Ready to mark with ${_config.model}.');
    } else {
      _statusMessage = 'No API key set — open Settings to add one.';
      _statusIsError = true;
      notifyListeners();
    }
  }

  ExamPaper? _paper;
  MarkScheme _markScheme = const MarkScheme('');
  CorrectionResult? _result;
  CorrectionStage _stage = CorrectionStage.idle;
  String _statusMessage = 'Ready.';
  bool _statusIsError = false;
  String? _pendingError;

  ExamPaper? get paper => _paper;
  MarkScheme get markScheme => _markScheme;
  CorrectionResult? get result => _result;
  CorrectionStage get stage => _stage;
  String get statusMessage => _statusMessage;
  bool get statusIsError => _statusIsError;

  /// An error worth interrupting the teacher for. Cleared once shown.
  String? get pendingError => _pendingError;

  bool get isBusy => _stage != CorrectionStage.idle;
  bool get isCorrecting => _stage == CorrectionStage.correcting;

  bool get canCorrect => _paper != null && !_markScheme.isEmpty && !isBusy;

  /// Step 1 — choose the student's exam paper and extract its content.
  Future<void> chooseExamPaper() async {
    if (isBusy) return;

    final String? path = await _filePicker.pickPdf();
    if (path == null) return;

    _setStage(CorrectionStage.readingPaper);
    _setStatus('Reading the exam paper…');

    try {
      final ExamPaper loaded = await _pdfService.loadExamPaper(path);
      _paper = loaded;
      _setStatus('Exam paper loaded.');
    } on AppException catch (error) {
      _paper = null;
      _fail('Exam paper could not be read.', error.message);
    } finally {
      _setStage(CorrectionStage.idle);
    }
  }

  /// Step 2 — the mark scheme, typed or pasted by the teacher.
  ///
  /// Notifies only when the empty/non-empty state changes, so typing does not
  /// rebuild the results list on every keystroke.
  void setMarkScheme(String text) {
    final bool wasEmpty = _markScheme.isEmpty;
    _markScheme = MarkScheme(text);
    if (wasEmpty != _markScheme.isEmpty) notifyListeners();
  }

  /// Step 2 (alternative) — load the mark scheme from a PDF.
  Future<void> loadMarkSchemeFromPdf() async {
    if (isBusy) return;

    final String? path = await _filePicker.pickPdf();
    if (path == null) return;

    _setStage(CorrectionStage.readingMarkScheme);
    _setStatus('Reading the mark scheme…');

    try {
      final String text = await _pdfService.extractText(path);
      _markScheme = MarkScheme(text);
      _setStatus('Mark scheme loaded.');
    } on AppException catch (error) {
      _fail('Mark scheme could not be read.', error.message);
    } finally {
      _setStage(CorrectionStage.idle);
    }
  }

  void clearMarkScheme() {
    if (isBusy) return;
    _markScheme = const MarkScheme('');
    notifyListeners();
  }

  /// Step 3 — mark the paper against the mark scheme.
  Future<void> startCorrection() async {
    if (isBusy) return;

    final ExamPaper? paper = _paper;
    if (paper == null) {
      _raise('Choose the student\'s exam paper PDF first.');
      return;
    }
    if (_markScheme.isEmpty) {
      _raise('Provide the mark scheme before correcting.');
      return;
    }

    // Choosing the mark scheme in step 1 produces a paper with no answers in
    // it: every question scores zero and a request is spent finding that out.
    if (_isSameDocument(paper.text, _markScheme.trimmed)) {
      _raise(
        'The exam paper and the mark scheme are the same document '
        '("${paper.fileName}"). In step 1, choose the student\'s completed '
        'paper.',
      );
      return;
    }

    _result = null;
    _setStage(CorrectionStage.correcting);
    _setStatus('Marking against the supplied mark scheme…');

    try {
      final CorrectionResult result = await _correctionService.correct(
        paperText: paper.text,
        markSchemeText: _markScheme.trimmed,
        // A rate-limit wait would otherwise look like a hang.
        onProgress: _setStatus,
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
  bool _isSameDocument(String paper, String markScheme) {
    String normalise(String text) => text
        .split('\n')
        .where((String line) => !line.startsWith('--- Page '))
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();

    final String left = normalise(paper);
    return left.isNotEmpty && left == normalise(markScheme);
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
