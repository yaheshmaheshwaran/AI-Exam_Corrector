import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';

/// Reports pipeline progress while a document is being transcribed.
///
/// Carries a fraction as well as a message because recognition is slow enough
/// — minutes for a full script — that a determinate bar is worth having, unlike
/// the single API call [CorrectionProgress] describes.
typedef OcrProgress = void Function(String message, double fraction);

/// Handwriting recognition.
///
/// The state layer depends only on this, so the local TrOCR sidecar can be
/// swapped for a hosted service without touching anything above it.
abstract class OcrService {
  /// Transcribes a scanned or photographed script.
  ///
  /// Implementations must return a [DocumentTranscript] or throw an
  /// [OcrException] carrying a message written for a teacher.
  Future<DocumentTranscript> transcribe({
    required String path,
    OcrProgress? onProgress,
  });

  /// Releases anything the implementation is holding — a child process, a
  /// client, a temporary directory.
  Future<void> dispose();
}

/// Stands in when the application was built without a recogniser wired up.
///
/// Lets the text-layer path work unchanged while making the missing capability
/// explicit at the point it is actually needed, rather than leaving a null to
/// be checked at every call site.
class UnavailableOcrService implements OcrService {
  const UnavailableOcrService();

  @override
  Future<DocumentTranscript> transcribe({
    required String path,
    OcrProgress? onProgress,
  }) async {
    throw const OcrException(
      'Handwriting recognition is not available in this build.',
      sidecarUnavailable: true,
    );
  }

  @override
  Future<void> dispose() async {}
}
