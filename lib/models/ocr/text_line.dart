/// Where a line's current text came from.
///
/// Recorded per line rather than per document because a single page routinely
/// mixes all three: TrOCR reads most lines, the vision model rescues the ones
/// it was unsure of, and the teacher fixes what is still wrong.
enum OcrSource {
  /// Transcribed by TrOCR in the local sidecar.
  trocr,

  /// Re-read by the vision model after TrOCR reported low confidence.
  vision,

  /// Corrected by the teacher in the review screen.
  teacher,
}

/// Where a line sits on its page, in pixels of the rendered page image.
class LineBox {
  const LineBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;
}

/// One transcribed line of a student's handwriting.
///
/// [ocrText] is kept alongside [text] for the whole life of the transcript, so
/// the review screen can always show what the machine originally read and offer
/// to revert to it. A teacher's correction never destroys the evidence.
class TextLine {
  const TextLine({
    required this.text,
    required this.ocrText,
    required this.confidence,
    required this.box,
    required this.cropPath,
    this.source = OcrSource.trocr,
  });

  final String text;
  final String ocrText;

  /// Geometric mean token probability from the recogniser, 0..1.
  final double confidence;

  final LineBox box;

  /// The cropped image of this line, on disk, shown beside the text in review.
  final String cropPath;

  final OcrSource source;

  bool get isEdited => text != ocrText;

  bool get isFromTeacher => source == OcrSource.teacher;

  /// True when this line is worth a second look at [threshold].
  bool isUncertain(double threshold) =>
      source != OcrSource.teacher && confidence < threshold;

  TextLine copyWith({
    String? text,
    double? confidence,
    OcrSource? source,
  }) {
    return TextLine(
      text: text ?? this.text,
      ocrText: ocrText,
      confidence: confidence ?? this.confidence,
      box: box,
      cropPath: cropPath,
      source: source ?? this.source,
    );
  }
}
