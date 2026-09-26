import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/services/ocr/sidecar_client.dart';

/// [HandwritingRecognizer] running TrOCR in the sidecar, region by region.
///
/// Local and free. Each region is read line by line inside its own bounds and
/// returned whole, with the words TrOCR scored low reported as uncertain
/// spans placed on their own ink.
class TrocrRegionRecognizer implements HandwritingRecognizer {
  TrocrRegionRecognizer(this._client, this._configProvider);

  final SidecarClient _client;
  final AppConfig Function() _configProvider;

  AppConfig get _config => _configProvider();

  @override
  String get fingerprint =>
      'trocr-regions:v1:${_config.trocrModel}:${_config.ocrConfidenceThreshold}';

  @override
  Future<Map<String, HandwritingEvidence>> recognize(
    ExamDocument document,
    List<PageRegion> regions, {
    Map<String, HandwritingReading> priorReadings =
        const <String, HandwritingReading>{},
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final Map<String, List<PageRegion>> byPage = <String, List<PageRegion>>{};
    for (final PageRegion region in regions) {
      byPage.putIfAbsent(region.pageId, () => <PageRegion>[]).add(region);
    }

    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    for (final MapEntry<String, List<PageRegion>> entry in byPage.entries) {
      final ExamPage? page = document.page(entry.key);
      if (page == null || !page.hasImage) continue;
      pages.add(<String, Object?>{
        'index': page.pageNumber - 1,
        'image_path': page.imagePath,
        'regions': <Map<String, Object?>>[
          for (final PageRegion region in entry.value)
            _request(region, page.width, page.height),
        ],
      });
    }
    if (pages.isEmpty) return const <String, HandwritingEvidence>{};

    final Map<String, Object?> done = await _client.stream(
      'recognize',
      <String, Object?>{
        'pages': pages,
        'crops_dir': await _cropsDirectory(document),
        'model': _config.trocrModel,
        'uncertain_below': _config.ocrConfidenceThreshold,
      },
      onProgress: onProgress,
      cancel: cancel,
    );

    final String engine = readString(done['engine']) ?? _config.trocrModel;
    final Map<String, HandwritingEvidence> evidence =
        <String, HandwritingEvidence>{};

    for (final JsonMap result in readObjects(done['regions'], (JsonMap m) => m)) {
      final String? regionId = readString(result['region_id']);
      if (regionId == null) continue;
      evidence[regionId] = HandwritingEvidence(
        regionId: regionId,
        readings: <HandwritingReading>[readingFrom(result, engine)],
      );
    }
    for (final JsonMap failure
        in readObjects(done['failures'], (JsonMap m) => m)) {
      final String? regionId = readString(failure['region_id']);
      if (regionId == null) continue;
      evidence[regionId] = HandwritingEvidence.failed(
        regionId,
        readString(failure['error']) ?? 'Recognition failed.',
      );
    }
    for (final PageRegion region in regions) {
      evidence.putIfAbsent(
        region.regionId,
        () => HandwritingEvidence.failed(
          region.regionId,
          'The recogniser returned nothing for this region.',
        ),
      );
    }
    return evidence;
  }

  /// Converts one region result from the sidecar, pixels to page fractions.
  static HandwritingReading readingFrom(JsonMap result, String engine) {
    final int width = readInt(result['page_width']) ?? 0;
    final int height = readInt(result['page_height']) ?? 0;

    NormalizedBox? box(Object? raw) {
      final List<int?> v = readList(raw).map(readInt).toList();
      if (v.length != 4 || v.contains(null) || width <= 0 || height <= 0) {
        return null;
      }
      return NormalizedBox.fromPixels(
        x: v[0]!,
        y: v[1]!,
        width: v[2]!,
        height: v[3]!,
        pageWidth: width,
        pageHeight: height,
      );
    }

    return HandwritingReading(
      source: ReadingSource.trocr,
      text: readRawString(result['text']) ?? '',
      confidence: readConfidence(result['confidence']),
      engine: engine,
      illegible: readBool(result['illegible']) ?? false,
      lines: <RecognizedLine>[
        for (final JsonMap line in readObjects(result['lines'], (JsonMap m) => m))
          if (box(line['box']) case final NormalizedBox lineBox)
            RecognizedLine(
              text: readRawString(line['text']) ?? '',
              confidence: readConfidence(line['confidence']),
              box: lineBox,
            ),
      ],
      uncertainSpans: <UncertainSpan>[
        for (final JsonMap span
            in readObjects(result['uncertain_spans'], (JsonMap m) => m))
          if (readRawString(span['text']) case final String text)
            UncertainSpan(
              text: text,
              confidence: readConfidence(span['confidence']),
              start: readInt(span['start']),
              end: readInt(span['end']),
              box: box(span['box']),
            ),
      ],
    );
  }

  Map<String, Object?> _request(PageRegion region, int width, int height) {
    List<int> px(NormalizedBox box) {
      final ({int x, int y, int width, int height}) p = box.toPixels(width, height);
      return <int>[p.x, p.y, p.width, p.height];
    }

    return <String, Object?>{
      'region_id': region.regionId,
      'box': px(region.box),
      'lines': <List<int>>[for (final NormalizedBox line in region.lineBoxes) px(line)],
      'line_words': <List<List<int>>>[
        for (final List<NormalizedBox> words in region.lineWords)
          <List<int>>[for (final NormalizedBox word in words) px(word)],
      ],
    };
  }

  Future<String> _cropsDirectory(ExamDocument document) async {
    final ExamPage first = document.pages.first;
    final String? image = first.imagePath;
    if (image == null) {
      throw const PipelineException(
        'The pages have no images to read handwriting from.',
        stage: 'recognising handwriting',
      );
    }
    final int cut = image.lastIndexOf(RegExp(r'[/\\]'));
    return '${cut < 0 ? '.' : image.substring(0, cut)}/../line-crops';
  }
}
