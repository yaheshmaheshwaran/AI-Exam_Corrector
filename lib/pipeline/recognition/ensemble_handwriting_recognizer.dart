import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/recognition/text_similarity.dart';

/// Combines every available reading of each region, and says how far they
/// agree.
///
/// The policy, in order:
/// 1. A text-layer reading is exact and final.
/// 2. The local recogniser (TrOCR) reads every other textual region. It is
///    free, so it also serves as an independent check on a region the vision
///    model already read during page analysis.
/// 3. Regions TrOCR was unsure of, and that no vision reading covers yet, are
///    shown to the vision model.
/// 4. Where there are two machine readings, the vision reading is primary —
///    it has the broader training — and their agreement is recorded. A
///    disagreement is never resolved silently: it is kept, and flags the
///    region for the teacher.
///
/// Every reading is kept. Nothing here edits text.
class EnsembleHandwritingRecognizer implements HandwritingRecognizer {
  EnsembleHandwritingRecognizer({
    required HandwritingRecognizer? local,
    required HandwritingRecognizer? vision,
    required AppConfig Function() configProvider,
    bool Function()? visionAvailable,
  })  : _local = local,
        _vision = vision,
        _configProvider = configProvider,
        _visionAvailable = visionAvailable ?? (() => vision != null);

  final HandwritingRecognizer? _local;
  final HandwritingRecognizer? _vision;
  final AppConfig Function() _configProvider;
  final bool Function() _visionAvailable;

  AppConfig get _config => _configProvider();

  bool get _useVision => _vision != null && _config.visionCrossCheck && _visionAvailable();

  @override
  String get fingerprint => 'ensemble:v5:${_local?.fingerprint ?? '-'}:'
      '${_useVision ? _vision!.fingerprint : '-'}';

  @override
  Future<Map<String, HandwritingEvidence>> recognize(
    ExamDocument document,
    List<PageRegion> regions, {
    Map<String, HandwritingReading> priorReadings =
        const <String, HandwritingReading>{},
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final Map<String, List<HandwritingReading>> readings =
        <String, List<HandwritingReading>>{
      for (final PageRegion region in regions)
        region.regionId: <HandwritingReading>[
          if (priorReadings[region.regionId] case final HandwritingReading prior)
            prior,
        ],
    };
    final Map<String, String> errors = <String, String>{};

    bool exact(PageRegion region) => readings[region.regionId]!
        .any((HandwritingReading r) => r.source == ReadingSource.textLayer);

    // TrOCR over everything not already exact.
    final List<PageRegion> forLocal =
        regions.where((PageRegion region) => !exact(region)).toList();
    final HandwritingRecognizer? local = _local;
    if (local != null && forLocal.isNotEmpty) {
      try {
        final Map<String, HandwritingEvidence> result = await local.recognize(
          document,
          forLocal,
          onProgress: (String m, double f) => onProgress?.call(m, f * 0.7),
          cancel: cancel,
        );
        result.forEach((String id, HandwritingEvidence evidence) {
          readings[id]?.addAll(evidence.readings);
          if (evidence.failed) errors[id] = evidence.error!;
        });
      } on OcrException catch (error) {
        for (final PageRegion region in forLocal) {
          errors[region.regionId] = '$recognitionUnavailable: ${error.message}';
        }
      }
    }

    // The vision model for what is still uncertain and has no vision reading.
    final double threshold = _config.ocrConfidenceThreshold;
    final List<PageRegion> forVision = <PageRegion>[
      for (final PageRegion region in regions)
        if (!exact(region) &&
            !readings[region.regionId]!
                .any((HandwritingReading r) => r.source == ReadingSource.vision) &&
            (_uncertain(readings[region.regionId]!, threshold) ||
                _strikeUnconfirmed(region)))
          region,
    ];
    final HandwritingRecognizer? vision = _vision;
    if (_useVision && vision != null && forVision.isNotEmpty) {
      try {
        final Map<String, HandwritingEvidence> result = await vision.recognize(
          document,
          forVision,
          onProgress: (String m, double f) => onProgress?.call(m, 0.7 + f * 0.3),
          cancel: cancel,
        );
        result.forEach((String id, HandwritingEvidence evidence) {
          readings[id]?.addAll(evidence.readings);
        });
      } on CorrectionException catch (error) {
        // Best effort: the TrOCR reading stands, flagged by its confidence.
        for (final PageRegion region in forVision) {
          errors.putIfAbsent(
            region.regionId,
            () => '$secondOpinionUnavailable: ${error.message}',
          );
        }
      }
    }

    onProgress?.call('Handwriting read.', 1);
    return <String, HandwritingEvidence>{
      for (final PageRegion region in regions)
        region.regionId: combine(
          region.regionId,
          readings[region.regionId]!,
          error: errors[region.regionId],
        ),
    };
  }

  /// Words scoring below this are doubtful enough to ask again, even when
  /// the region as a whole read well. Misread symbols in working — "=" read
  /// as "-", "+" as "t" — score like this inside otherwise confident lines.
  static const double doubtfulWord = 0.5;

  /// A strike local analysis only suspected: the vision model is asked to
  /// confirm it, because the answer to "was this crossed out?" decides
  /// whether the writing counts.
  static bool _strikeUnconfirmed(PageRegion region) =>
      region.type == RegionType.crossedOut && region.confidence < 0.6;

  static bool _uncertain(List<HandwritingReading> readings, double threshold) {
    if (readings.isEmpty) return true;
    // Judged at the weakest line, not the region's average: a block often
    // holds the end of one answer and the printed heading of the next, and
    // a well-read heading must not hide a badly read answer.
    return readings.every(
      (HandwritingReading r) =>
          r.illegible ||
          r.confidence < threshold ||
          r.lines.any((RecognizedLine line) => line.confidence < threshold) ||
          r.uncertainSpans.any((UncertainSpan s) => s.confidence < doubtfulWord),
    );
  }

  static const String recognitionUnavailable = 'Recognition unavailable';
  static const String secondOpinionUnavailable = 'Second opinion unavailable';

  /// Evidence missing a reading only because an engine could not be reached —
  /// a rate limit, a recogniser not yet started — and worth another attempt.
  /// "Nothing legible" is a real answer and is not retried.
  static bool retryable(HandwritingEvidence evidence) {
    final String? error = evidence.error;
    return error != null &&
        (error.startsWith(recognitionUnavailable) ||
            error.startsWith(secondOpinionUnavailable));
  }

  /// A second reading below this is too unsure of itself to contradict the
  /// primary one.
  static const double confidentSecondReading = 0.85;

  /// Picks the primary reading and measures agreement. Pure, and tested
  /// directly.
  static HandwritingEvidence combine(
    String regionId,
    List<HandwritingReading> readings, {
    String? error,
  }) {
    final List<HandwritingReading> usable = readings
        .where((HandwritingReading r) => r.text.trim().isNotEmpty || r.illegible)
        .toList();
    if (usable.isEmpty) {
      return HandwritingEvidence.failed(
        regionId,
        error ?? 'Nothing legible was read in this region.',
      );
    }

    int primary = usable.indexWhere(
      (HandwritingReading r) => r.source == ReadingSource.textLayer,
    );
    if (primary < 0) {
      primary = usable.indexWhere(
        (HandwritingReading r) => r.source == ReadingSource.vision && !r.illegible,
      );
    }
    if (primary < 0) {
      // Otherwise the most confident reading.
      primary = 0;
      for (int i = 1; i < usable.length; i++) {
        if (usable[i].confidence > usable[primary].confidence) primary = i;
      }
    }

    // Agreement is measured only against confident second readings. TrOCR
    // reading a lone label badly is TrOCR failing, not a genuine doubt about
    // what is written — counting it would flag every diagram label.
    double? agreement;
    final HandwritingReading chosen = usable[primary];
    for (int i = 0; i < usable.length; i++) {
      if (i == primary || usable[i].source == chosen.source) continue;
      if (usable[i].confidence < confidentSecondReading) continue;
      final double similarity = textSimilarity(chosen.text, usable[i].text);
      agreement = agreement == null ? similarity : (agreement < similarity ? agreement : similarity);
    }

    return HandwritingEvidence(
      regionId: regionId,
      readings: usable,
      primaryIndex: primary,
      agreement: agreement,
      error: error,
    );
  }
}
