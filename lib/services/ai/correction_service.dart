import 'package:exam_corrector/models/correction_result.dart';

/// Reports what the service is doing while a correction is in flight, so a
/// wait the teacher cannot otherwise see (a rate-limit pause, a retry) shows up
/// in the status bar instead of looking like a hang.
typedef CorrectionProgress = void Function(String message);

/// The correction service interface.
///
/// The UI and application state depend only on this abstraction, so the
/// underlying model or provider can be swapped without touching anything else.
abstract class CorrectionService {
  /// Marks a student's answer sheet against a question paper.
  ///
  /// [questionPaperText] establishes which questions exist, their sections and
  /// their maximum marks. [answerSheetText] is what gets judged. The two are
  /// joined on question number.
  ///
  /// [guidanceText] is the teacher's optional marking notes, which fill gaps
  /// the question paper leaves rather than overriding it.
  ///
  /// [fromHandwriting] tells the implementation that at least one document came
  /// from OCR rather than a text layer. It changes how the documents should be
  /// read, not how they are marked: transcription noise must not cost the
  /// student marks that their actual answer earned.
  ///
  /// Implementations must return a validated [CorrectionResult] or throw an
  /// [AppException] carrying a human-readable message.
  Future<CorrectionResult> correct({
    required String questionPaperText,
    required String answerSheetText,
    String guidanceText = '',
    CorrectionProgress? onProgress,
    bool fromHandwriting = false,
  });
}
