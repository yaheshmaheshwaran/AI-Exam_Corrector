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
  /// Evaluates a student's paper against a mark scheme.
  ///
  /// Implementations must return a validated [CorrectionResult] or throw an
  /// [AppException] carrying a human-readable message.
  Future<CorrectionResult> correct({
    required String paperText,
    required String markSchemeText,
    CorrectionProgress? onProgress,
  });
}
