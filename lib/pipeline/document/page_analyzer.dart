import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/pipeline/engines.dart';

/// Stage one routing, from measurements the renderer already took.
///
/// Costs nothing and saves a great deal: a blank continuation sheet is never
/// sent for layout analysis, and a typed page is read from its text layer
/// rather than recognised.
class DefaultPageAnalyzer implements PageAnalyzer {
  const DefaultPageAnalyzer();

  @override
  PageRoute route(ExamPage page) {
    if (page.hasTextLayer) return PageRoute.textLayer;
    if (page.isBlank) return PageRoute.skip;
    return PageRoute.detect;
  }
}
