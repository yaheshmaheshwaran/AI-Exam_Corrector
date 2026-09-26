import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/pipeline/recognition/text_similarity.dart';

/// Finds working inside handwritten regions and gives it its own region.
///
/// Local layout cannot see an equation — to it, `= 100 / 0.05` is a line of
/// writing like any other — and TrOCR, trained on prose, is at its weakest
/// there. Once the writing has been read, though, working is recognisable by
/// its content. Each run of mathematical lines becomes a derived `equation`
/// region inside its parent: it gets its own crop, is read as mathematics by
/// the equation recogniser, and its image goes to the marker. The parent keeps
/// its text, so nothing is removed from the answer.
class EquationPromoter {
  const EquationPromoter();

  static const Set<RegionType> _sources = <RegionType>{
    RegionType.handwrittenAnswer,
    RegionType.marginNote,
    RegionType.unknown,
  };

  ({ExamDocument document, Map<String, HandwritingEvidence> evidence}) promote(
    ExamDocument document,
    Map<String, HandwritingEvidence> evidence,
  ) {
    final List<PageRegion> added = <PageRegion>[];
    final Map<String, HandwritingEvidence> readings = <String, HandwritingEvidence>{};

    for (final ExamPage page in document.pages) {
      final List<PageRegion> existing = page.regions
          .where((PageRegion r) => r.type == RegionType.equation)
          .toList();

      for (final PageRegion region in page.regions) {
        if (!_sources.contains(region.type) || region.origin == RegionOrigin.textLayer) {
          continue;
        }
        final HandwritingEvidence? found = evidence[region.regionId];
        if (found == null) continue;

        final List<({String text, NormalizedBox box})> lines = _lines(region, found);
        int k = 0;
        for (final List<({String text, NormalizedBox box})> run in _mathRuns(lines)) {
          final NormalizedBox box = run
              .map((line) => line.box)
              .reduce((NormalizedBox a, NormalizedBox b) => a.union(b));
          // The vision model may already have found this equation.
          if (existing.any((PageRegion e) => e.box.iou(box) > 0.5)) continue;

          final String id = '${region.regionId}.eq$k';
          k++;
          final String text = run.map((line) => line.text).join('\n');
          added.add(
            PageRegion(
              regionId: id,
              pageId: region.pageId,
              pageNumber: region.pageNumber,
              type: RegionType.equation,
              box: box,
              confidence: 0.6,
              readingOrder: region.readingOrder,
              origin: RegionOrigin.derived,
              parentRegionId: region.regionId,
              detectedText: text,
              lineBoxes: <NormalizedBox>[for (final line in run) line.box],
            ),
          );
          final HandwritingReading? primary = found.primary;
          readings[id] = HandwritingEvidence(
            regionId: id,
            readings: <HandwritingReading>[
              HandwritingReading(
                source: primary?.source ?? ReadingSource.trocr,
                text: text,
                confidence: primary?.confidence ?? 0.5,
                engine: primary?.engine ?? '',
              ),
            ],
          );
        }
      }
    }

    return (
      document: document.withRegions(added: added),
      evidence: <String, HandwritingEvidence>{...evidence, ...readings},
    );
  }

  /// The region's lines with their boxes: the primary reading's text where its
  /// lines line up with the geometry, which may come from another engine.
  static List<({String text, NormalizedBox box})> _lines(
    PageRegion region,
    HandwritingEvidence evidence,
  ) {
    final HandwritingReading? primary = evidence.primary;
    if (primary == null) return const <({String text, NormalizedBox box})>[];
    final List<String> primaryLines =
        primary.text.split('\n').where((String l) => l.trim().isNotEmpty).toList();

    List<NormalizedBox> boxes = <NormalizedBox>[
      for (final RecognizedLine line in primary.lines) line.box,
    ];
    if (boxes.length != primaryLines.length) {
      boxes = <NormalizedBox>[];
      for (final HandwritingReading reading in evidence.readings) {
        if (reading.lines.length == primaryLines.length) {
          boxes = <NormalizedBox>[for (final RecognizedLine line in reading.lines) line.box];
          break;
        }
      }
    }
    if (boxes.length != primaryLines.length && region.lineBoxes.length == primaryLines.length) {
      boxes = region.lineBoxes;
    }
    if (boxes.length != primaryLines.length) {
      return const <({String text, NormalizedBox box})>[];
    }
    return <({String text, NormalizedBox box})>[
      for (int i = 0; i < boxes.length; i++) (text: primaryLines[i], box: boxes[i]),
    ];
  }

  static List<List<({String text, NormalizedBox box})>> _mathRuns(
    List<({String text, NormalizedBox box})> lines,
  ) {
    final List<List<({String text, NormalizedBox box})>> runs =
        <List<({String text, NormalizedBox box})>>[];
    List<({String text, NormalizedBox box})> current = <({String text, NormalizedBox box})>[];
    for (final line in lines) {
      if (looksMathematical(line.text)) {
        current.add(line);
      } else if (current.isNotEmpty) {
        runs.add(current);
        current = <({String text, NormalizedBox box})>[];
      }
    }
    if (current.isNotEmpty) runs.add(current);
    return runs;
  }
}
