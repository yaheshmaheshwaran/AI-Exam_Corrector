import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';

/// A whole handwritten script after recognition: every page, every line, and
/// the provenance of each.
///
/// This is the single source of truth for the text that reaches the marking
/// prompt. Building that text lives here — not in the sidecar — so that the
/// teacher's corrections in the review screen are necessarily included, and so
/// the `--- Page N ---` convention exists in one place rather than being
/// half-implemented at each end of the wire.
class DocumentTranscript {
  const DocumentTranscript({
    required this.pages,
    required this.engine,
    required this.detector,
    required this.dpi,
    required this.workdir,
  });

  final List<PageTranscript> pages;

  /// The recognition model, e.g. `microsoft/trocr-large-handwritten`.
  final String engine;

  /// The line detector, e.g. `db_resnet50`.
  final String detector;

  final int dpi;

  /// Where the page images and line crops live. Owned by the app, so it can
  /// clean up once the correction is done.
  final String workdir;

  /// Marks a line the recogniser was unsure of. Kept out of the student's
  /// words themselves — it always sits at the start of the line.
  static const String uncertainMarker = '⚠';

  List<TextLine> get allLines =>
      <TextLine>[for (final PageTranscript page in pages) ...page.lines];

  int get lineCount => allLines.length;

  bool get isEmpty => lineCount == 0;

  double get meanConfidence {
    final List<TextLine> lines = allLines;
    if (lines.isEmpty) return 0;
    final double sum = lines.fold<double>(
      0,
      (double total, TextLine line) => total + line.confidence,
    );
    return sum / lines.length;
  }

  int uncertainCount(double threshold) =>
      allLines.where((TextLine line) => line.isUncertain(threshold)).length;

  int get editedCount => allLines.where((TextLine line) => line.isEdited).length;

  /// The text the AI marks.
  ///
  /// When [flagBelow] is given, lines the recogniser was unsure of are prefixed
  /// with [uncertainMarker] so the prompt can tell the model to read them
  /// charitably rather than penalising a student for the machine's mistake.
  String toMarkedText({double? flagBelow}) {
    final List<String> blocks = <String>[];

    for (final PageTranscript page in pages) {
      final StringBuffer body = StringBuffer();
      for (final TextLine line in page.lines) {
        final bool uncertain =
            flagBelow != null && line.isUncertain(flagBelow);
        body.writeln(uncertain ? '$uncertainMarker ${line.text}' : line.text);
      }
      blocks.add('--- Page ${page.pageNumber} ---\n${body.toString().trim()}');
    }

    return blocks.join('\n\n').trim();
  }

  /// Returns a copy with one line replaced.
  DocumentTranscript withLine(int pageIndex, int lineIndex, TextLine line) {
    if (pageIndex < 0 || pageIndex >= pages.length) return this;

    final List<PageTranscript> updated = List<PageTranscript>.of(pages);
    updated[pageIndex] = pages[pageIndex].withLine(lineIndex, line);

    return _copyWithPages(updated);
  }

  /// Returns a copy with [replacements] applied, keyed by page then line index.
  ///
  /// Used by the vision cross-check, which re-reads many scattered lines at
  /// once and would otherwise rebuild the document once per line.
  DocumentTranscript withLines(Map<int, Map<int, TextLine>> replacements) {
    if (replacements.isEmpty) return this;

    final List<PageTranscript> updated = List<PageTranscript>.of(pages);
    replacements.forEach((int pageIndex, Map<int, TextLine> lines) {
      if (pageIndex < 0 || pageIndex >= updated.length) return;
      PageTranscript page = updated[pageIndex];
      lines.forEach((int lineIndex, TextLine line) {
        page = page.withLine(lineIndex, line);
      });
      updated[pageIndex] = page;
    });

    return _copyWithPages(updated);
  }

  DocumentTranscript _copyWithPages(List<PageTranscript> updated) {
    return DocumentTranscript(
      pages: updated,
      engine: engine,
      detector: detector,
      dpi: dpi,
      workdir: workdir,
    );
  }
}
