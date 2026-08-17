import 'package:exam_corrector/models/ocr/text_line.dart';

/// One page of a transcribed script: the rendered image, and the lines found
/// on it in reading order.
///
/// [imagePath] points at the *cleaned* page — deskewed and contrast-normalised
/// — because that is the image every [TextLine.box] was measured against. The
/// review screen must show the same one or the boxes will not line up.
class PageTranscript {
  const PageTranscript({
    required this.index,
    required this.imagePath,
    required this.width,
    required this.height,
    required this.lines,
  });

  final int index;
  final String imagePath;
  final int width;
  final int height;
  final List<TextLine> lines;

  /// Human-facing page number, matching the `--- Page N ---` markers.
  int get pageNumber => index + 1;

  bool get isEmpty => lines.isEmpty;

  int uncertainCount(double threshold) =>
      lines.where((TextLine line) => line.isUncertain(threshold)).length;

  /// Returns a copy with the line at [lineIndex] replaced.
  PageTranscript withLine(int lineIndex, TextLine line) {
    if (lineIndex < 0 || lineIndex >= lines.length) return this;

    final List<TextLine> updated = List<TextLine>.of(lines);
    updated[lineIndex] = line;

    return PageTranscript(
      index: index,
      imagePath: imagePath,
      width: width,
      height: height,
      lines: updated,
    );
  }
}
