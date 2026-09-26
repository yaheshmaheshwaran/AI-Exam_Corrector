import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/layout/local_region_detector.dart';
import 'package:exam_corrector/pipeline/layout/vision_region_detector.dart';

/// Local layout for every page; the vision model only where local analysis
/// admits it is out of its depth.
///
/// A handwritten script is mostly prose, which local analysis handles well
/// and for free. Diagrams, graphs, tables and pages with ink it cannot account
/// for are where a vision model earns its cost, so those pages — and only
/// those — are sent. If the vision model is unavailable the local result
/// stands, and the teacher is told which pages deserved a better look.
class HybridRegionDetector implements RegionDetector {
  HybridRegionDetector({
    required LocalRegionDetector? local,
    required VisionRegionDetector? vision,
  })  : _local = local,
        _vision = vision;

  final LocalRegionDetector? _local;
  final VisionRegionDetector? _vision;

  @override
  String get fingerprint =>
      'hybrid:${_local?.fingerprint ?? '-'}:${_vision?.fingerprint ?? '-'}';

  @override
  Future<RegionDetection> detect(
    ExamDocument document,
    List<ExamPage> pages, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final LocalRegionDetector? local = _local;
    final VisionRegionDetector? vision = _vision;
    final bool visionReady = vision != null && vision.isAvailable;

    if (local == null) {
      if (!visionReady) {
        throw const PipelineException(
          'Neither the local recogniser nor the vision model is available, so '
          'the pages cannot be analysed. Install the recogniser (see '
          'ocr_service/README.md) or add an API key in Settings.',
          stage: 'detecting regions',
        );
      }
      return vision.detect(document, pages, onProgress: onProgress, cancel: cancel);
    }

    Map<int, LocalPageLayout> layouts;
    try {
      layouts = await local.analyze(
        pages,
        onProgress: (String message, double fraction) =>
            onProgress?.call(message, fraction * 0.5),
        cancel: cancel,
      );
    } on OcrException catch (error) {
      if (!visionReady) rethrow;
      // The recogniser is not there; the vision model can do the whole job.
      final RegionDetection result = await vision.detect(
        document,
        pages,
        onProgress: onProgress,
        cancel: cancel,
      );
      return RegionDetection(
        pages: result.pages,
        readings: result.readings,
        warnings: <String>[
          'Local layout analysis was unavailable (${error.message}); every '
              'page was analysed by the vision model.',
          ...result.warnings,
        ],
      );
    }

    final List<ExamPage> escalated = <ExamPage>[
      for (final ExamPage page in pages)
        if (layouts[page.pageNumber]?.needsVision ?? true) page,
    ];
    final List<String> warnings = <String>[];
    final Map<int, ExamPage> fromVision = <int, ExamPage>{};
    final Map<String, HandwritingReading> readings =
        <String, HandwritingReading>{};

    if (escalated.isNotEmpty && visionReady) {
      try {
        final RegionDetection result = await vision.detect(
          document,
          escalated,
          onProgress: (String message, double fraction) =>
              onProgress?.call(message, 0.5 + fraction * 0.5),
          cancel: cancel,
        );
        warnings.addAll(result.warnings);
        readings.addAll(result.readings);
        for (final ExamPage page in result.pages) {
          if (page.regions.isNotEmpty || page.isBlank) {
            fromVision[page.pageNumber] = page;
          }
        }
      } on CorrectionException catch (error) {
        warnings.add(
          'The vision model could not analyse page(s) '
          '${escalated.map((ExamPage p) => p.pageNumber).join(', ')} '
          '(${error.message}). Local layout analysis was used instead; '
          'check diagrams and tables on those pages yourself.',
        );
      }
    } else if (escalated.isNotEmpty) {
      warnings.add(
        'Page(s) ${escalated.map((ExamPage p) => p.pageNumber).join(', ')} '
        'contain drawings, tables or content local analysis could not place, '
        'and no API key is set for the vision model. Check those pages '
        'yourself.',
      );
    }

    for (final MapEntry<int, LocalPageLayout> entry in layouts.entries) {
      if (entry.value.error != null && !fromVision.containsKey(entry.key)) {
        warnings.add('Page ${entry.key}: layout analysis failed '
            '(${entry.value.error}).');
      }
    }

    return RegionDetection(
      pages: <ExamPage>[
        for (final ExamPage page in pages)
          fromVision[page.pageNumber] ??
              page.copyWith(
                regions: layouts[page.pageNumber]?.regions ?? const <PageRegion>[],
                detector: local.fingerprint,
              ),
      ],
      readings: readings,
      warnings: warnings,
    );
  }
}
