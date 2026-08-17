import 'package:exam_corrector/models/ocr/document_transcript.dart';

/// How a paper's text was obtained.
enum ExamSource {
  /// Read straight out of the PDF's text layer.
  textLayer,

  /// Recognised from a scan or photograph of handwriting.
  ocr,
}

/// A document after extraction: the file it came from, and its text.
///
/// Used for both documents a correction needs — the student's answer sheet and
/// the question paper — because both are ingested the same way and either can
/// arrive as a scan. Which one a given instance is comes from the field holding
/// it, not from the type.
///
/// [text] stays the single thing the marking pipeline consumes, whichever way
/// it was obtained. [transcript] is the extra evidence an OCR run carries with
/// it — page images, line boxes, confidences — which the review screen needs
/// and a text-layer PDF simply does not have.
class ExamPaper {
  const ExamPaper({
    required this.filePath,
    required this.fileName,
    required this.text,
    this.source = ExamSource.textLayer,
    this.transcript,
  });

  final String filePath;
  final String fileName;
  final String text;
  final ExamSource source;

  /// Present only when [source] is [ExamSource.ocr].
  final DocumentTranscript? transcript;

  int get characterCount => text.length;

  bool get isHandwritten => source == ExamSource.ocr;

  /// Returns a copy whose text is rebuilt from an edited transcript.
  ///
  /// Used when the teacher confirms the review screen: the corrections they
  /// made are what must reach the marking prompt, not the raw recognition.
  ExamPaper withTranscript(DocumentTranscript updated, {double? flagBelow}) {
    return ExamPaper(
      filePath: filePath,
      fileName: fileName,
      text: updated.toMarkedText(flagBelow: flagBelow),
      source: ExamSource.ocr,
      transcript: updated,
    );
  }
}
