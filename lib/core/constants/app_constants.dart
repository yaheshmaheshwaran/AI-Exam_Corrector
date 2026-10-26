/// Values shared across layers. Nothing here knows about widgets.
///
/// The AI's defaults — providers and which models do each job — live in
/// `lib/ai/`; these are the application's own.
class AppConstants {
  const AppConstants._();

  /// The largest PDF accepted.
  static const int maxPdfBytes = 25 * 1024 * 1024; // 25 MB

  /// Below this many characters a PDF is taken to carry no real text layer
  /// (typically a scan or a photo of a handwritten script), and its pages are
  /// read from their images rather than rejected.
  static const int minUsefulPdfChars = 40;

  /// Marking confidence below this flags a question for teacher review.
  static const double defaultReviewThreshold = 0.7;
}
