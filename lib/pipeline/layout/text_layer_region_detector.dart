import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/pipeline/engines.dart';

/// Regions straight from a PDF's text layer.
///
/// Exact positions and exact text, for nothing: a typed answer sheet needs no
/// recognition at all. Lines are grouped into blocks at blank lines, so an
/// answer and the question printed above it are separate regions; a block that
/// still holds two answers is split at the label later, during alignment.
class TextLayerRegionDetector implements RegionDetector {
  const TextLayerRegionDetector(this._reader);

  final TextLayerReader _reader;

  @override
  String get fingerprint => 'text-layer:v1';

  @override
  Future<RegionDetection> detect(
    ExamDocument document,
    List<ExamPage> pages, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    onProgress?.call('Reading the text layer…', 0);
    final List<TextLayerPage> layer = await _reader.read(document.filePath);
    final Map<int, TextLayerPage> byNumber = <int, TextLayerPage>{
      for (final TextLayerPage page in layer) page.pageNumber: page,
    };

    final Map<String, HandwritingReading> readings =
        <String, HandwritingReading>{};
    final List<ExamPage> detected = <ExamPage>[];

    for (final ExamPage page in pages) {
      cancel?.throwIfCancelled();
      final TextLayerPage? text = byNumber[page.pageNumber];
      if (text == null || text.lines.isEmpty) {
        detected.add(page.copyWith(regions: const <PageRegion>[]));
        continue;
      }

      final List<PageRegion> regions = <PageRegion>[];
      for (final List<TextLayerLine> block in blocksOf(text.lines)) {
        final String regionId = '${page.pageId}:t${regions.length}';
        final List<NormalizedBox> lines = <NormalizedBox>[
          for (final TextLayerLine line in block) _box(line, text),
        ];
        final String body =
            block.map((TextLayerLine line) => line.text).join('\n');
        regions.add(
          PageRegion(
            regionId: regionId,
            pageId: page.pageId,
            pageNumber: page.pageNumber,
            type: RegionType.printedText,
            box: lines.reduce((NormalizedBox a, NormalizedBox b) => a.union(b)),
            confidence: 1,
            readingOrder: regions.length,
            origin: RegionOrigin.textLayer,
            detectedText: body,
            lineBoxes: lines,
          ),
        );
        readings[regionId] = HandwritingReading(
          source: ReadingSource.textLayer,
          text: body,
          confidence: 1,
          engine: 'pdf-text-layer',
          lines: <RecognizedLine>[
            for (int i = 0; i < block.length; i++)
              RecognizedLine(text: block[i].text, confidence: 1, box: lines[i]),
          ],
        );
      }
      detected.add(page.copyWith(regions: regions, detector: fingerprint));
    }

    onProgress?.call('Text layer read.', 1);
    return RegionDetection(pages: detected, readings: readings);
  }

  /// Consecutive lines separated by no more than a normal line gap.
  static List<List<TextLayerLine>> blocksOf(List<TextLayerLine> lines) {
    final List<TextLayerLine> ordered = List<TextLayerLine>.of(lines)
      ..sort((TextLayerLine a, TextLayerLine b) {
        final int byTop = a.top.compareTo(b.top);
        return byTop != 0 ? byTop : a.left.compareTo(b.left);
      });

    final List<List<TextLayerLine>> blocks = <List<TextLayerLine>>[];
    for (final TextLayerLine line in ordered) {
      if (blocks.isEmpty) {
        blocks.add(<TextLayerLine>[line]);
        continue;
      }
      final TextLayerLine previous = blocks.last.last;
      final double gap = line.top - (previous.top + previous.height);
      final double lineHeight =
          previous.height > line.height ? previous.height : line.height;
      if (gap <= 0.6 * lineHeight) {
        blocks.last.add(line);
      } else {
        blocks.add(<TextLayerLine>[line]);
      }
    }
    return blocks;
  }

  NormalizedBox _box(TextLayerLine line, TextLayerPage page) =>
      NormalizedBox.fromPixels(
        x: line.left,
        y: line.top,
        width: line.width,
        height: line.height,
        pageWidth: page.width,
        pageHeight: page.height,
      );
}
