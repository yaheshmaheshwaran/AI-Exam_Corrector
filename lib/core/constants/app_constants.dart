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
  /// (typically a scan or a photo of a handwritten script).
  static const int minUsefulPdfChars = 40;

  /// Google Gemini Interactions API.
  static const String apiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/interactions';

  /// A full paper can take minutes to mark. The request is streamed, so this
  /// bounds the gap between chunks rather than the whole correction.
  static const Duration apiIdleTimeout = Duration(minutes: 5);
}
