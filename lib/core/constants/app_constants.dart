/// Values shared across layers. Nothing here knows about widgets.
class AppConstants {
  const AppConstants._();

  /// Correction defaults. Overridable through the environment — see AppConfig.
  ///
  /// The free tier allows only about 20 requests a day per model, counted per
  /// model, so marking walks down this chain as each model's allowance runs
  /// out. The newest model sits last: it marks best but has the least room, so
  /// it is kept as a reserve rather than spent first.
  static const String defaultModel = 'gemini-3.6-flash';

  static const List<String> defaultFallbackModels = <String>[
    'gemini-3.5-flash',
    'gemini-3.5-flash-lite',
    'gemini-3.7-flash',
  ];

  /// Maps to the Gemini `thinking_level`: minimal, low, medium or high.
  /// Marking is reasoning-heavy, so the default is the top of that range.
  static const String defaultEffort = 'high';
  static const int defaultMaxTokens = 32000;

  /// PDF limits.
  static const int maxPdfBytes = 25 * 1024 * 1024; // 25 MB

  /// Below this many characters we assume the PDF carries no real text layer
  /// (typically a scan or a photo of a handwritten script). Such a document is
  /// routed to handwriting recognition rather than rejected.
  static const int minUsefulPdfChars = 40;

  /// Handwriting recognition defaults. Overridable through the environment and
  /// the Settings dialog — see AppConfig.
  ///
  /// The large model is the default because exam scripts are the hard case:
  /// unfamiliar hands, pencil, corrections. `trocr-base-handwritten` is roughly
  /// four times faster and noticeably less accurate, which suits a slow machine
  /// but not a first choice.
  static const String defaultTrocrModel = 'microsoft/trocr-large-handwritten';

  /// Lines scoring below this get a second opinion from the vision model, and
  /// are highlighted for the teacher in review.
  ///
  /// Measured, not guessed. On a scanned handwritten script TrOCR's
  /// geometric-mean token probability separates cleanly: correctly read prose
  /// lands at 0.97–1.00, while every line it got wrong — "+" read as "t", "="
  /// as "-", "100 / 0.05" as "( 100 ) 0.05" — landed between 0.77 and 0.91.
  /// 0.92 sits in that gap. A lower threshold looks safer and is not: it lets
  /// through exactly the mangled arithmetic that costs a student marks.
  static const double defaultOcrConfidenceThreshold = 0.92;

  /// 300 dpi is the sweet spot for TrOCR. Below ~200 thin pen strokes break up;
  /// above ~400 nothing improves and memory use climbs quadratically.
  static const int defaultOcrDpi = 300;

  /// Line crops sent per vision request. The free tier counts requests, not
  /// images, so batching is what keeps a cross-check affordable.
  static const int visionBatchSize = 12;

  /// A cold sidecar imports torch and may download weights.
  static const Duration ocrStartupTimeout = Duration(seconds: 90);

  /// Google Gemini Interactions API.
  static const String apiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/interactions';

  /// Retries of a request that failed for a reason that passes on its own.
  static const int defaultRetryCount = 2;

  /// Marking confidence below this flags a question for teacher review.
  static const double defaultReviewThreshold = 0.7;

  /// Longest side of an image sent to a model. Page analysis gains nothing
  /// from 300 dpi, and every pixel is paid for.
  static const int defaultMaxImageDimension = 1600;

  /// Page images per vision request during page analysis.
  static const int defaultPagesPerVisionRequest = 2;

  /// Questions per marking request. Batching keeps a paper to a few requests;
  /// capping keeps each response well inside the output limit.
  static const int defaultQuestionsPerMarkingRequest = 8;

  /// Images attached to a single request.
  static const int defaultMaxImagesPerRequest = 16;

  /// A full paper can take minutes to mark. The request is streamed, so this
  /// bounds the gap between chunks rather than the whole correction.
  static const Duration apiIdleTimeout = Duration(minutes: 5);
}
