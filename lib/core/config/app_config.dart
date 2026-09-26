import 'dart:io';

import 'package:exam_corrector/core/constants/app_constants.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/settings_store.dart';

/// Where page regions come from.
enum LayoutEngine {
  /// Local layout analysis first; only pages it cannot explain — any
  /// graphics, or ink it could not account for — go to the vision model.
  /// The default: nearly all of a typical script costs no API requests.
  hybrid,

  /// Every page is analysed by the vision model. Best understanding, one
  /// request per few pages.
  vision,

  /// Local layout analysis only. Free and offline, and weakest on diagrams,
  /// tables and graphs.
  local;

  static LayoutEngine parse(String? value) {
    if (value == null) return hybrid;
    final String normalised = value.trim().toLowerCase();
    for (final LayoutEngine engine in values) {
      if (engine.name == normalised) return engine;
    }
    throw ConfigException(
      'EXAM_CORRECTOR_LAYOUT_ENGINE must be hybrid, vision or local, got '
      '"$value".',
    );
  }
}

/// Application configuration.
///
/// API credentials are never hard-coded. They are resolved from three sources,
/// most explicit first:
///
/// 1. the process environment,
/// 2. the key saved in the application's Settings dialog ([SettingsStore]),
/// 3. a `.env` file beside the executable or in the project tree.
class AppConfig {
  const AppConfig({
    required this.apiKey,
    required this.model,
    required this.effort,
    required this.maxTokens,
    this.fallbackModels = const <String>[],
    this.ocrEnabled = true,
    this.trocrModel = AppConstants.defaultTrocrModel,
    this.ocrConfidenceThreshold = AppConstants.defaultOcrConfidenceThreshold,
    this.visionCrossCheck = true,
    this.ocrDpi = AppConstants.defaultOcrDpi,
    this.visionModel,
    this.diagramModel,
    this.apiEndpoint = AppConstants.apiEndpoint,
    this.requestTimeout = AppConstants.apiIdleTimeout,
    this.retryCount = AppConstants.defaultRetryCount,
    this.layoutEngine = LayoutEngine.hybrid,
    this.reviewThreshold = AppConstants.defaultReviewThreshold,
    this.maxImageDimension = AppConstants.defaultMaxImageDimension,
    this.pagesPerVisionRequest = AppConstants.defaultPagesPerVisionRequest,
    this.questionsPerMarkingRequest =
        AppConstants.defaultQuestionsPerMarkingRequest,
    this.maxImagesPerRequest = AppConstants.defaultMaxImagesPerRequest,
    this.visualAnalysis = true,
    this.developerMode = false,
    this.cacheEnabled = true,
    this.ocrEndpoint,
    this.ocrToken,
  });

  final String? apiKey;
  final String model;
  final String effort;
  final int maxTokens;

  /// Models to fall back to, in order, as each one's daily quota runs out.
  final List<String> fallbackModels;

  /// Whether a scan with no text layer is sent to handwriting recognition.
  /// Turning this off restores the old behaviour: such a paper is rejected.
  final bool ocrEnabled;

  /// The TrOCR checkpoint the sidecar loads.
  final String trocrModel;

  /// Below this confidence a line is cross-checked and flagged for review.
  final double ocrConfidenceThreshold;

  /// Whether low-confidence lines get a second opinion from the vision model.
  /// Costs API requests, so it can be turned off on a tight quota.
  final bool visionCrossCheck;

  /// Resolution pages are rendered at before recognition.
  final int ocrDpi;

  /// The model that reads pages: layout, handwriting second opinions, and a
  /// scanned question paper. Defaults to the marking model.
  final String? visionModel;

  /// The model that analyses diagrams, graphs, tables and equations.
  /// Defaults to the vision model.
  final String? diagramModel;

  /// The model API's URL, overridable for a proxy or a regional endpoint.
  final String apiEndpoint;

  /// How long a request may go without sending anything before it is
  /// abandoned. Bounds the silence, not the whole request.
  final Duration requestTimeout;

  /// Retries of a request that failed for a reason that passes on its own.
  final int retryCount;

  final LayoutEngine layoutEngine;

  /// Marking confidence below this flags a question for teacher review.
  final double reviewThreshold;

  /// Longest side of any image sent to a model, in pixels.
  final int maxImageDimension;

  /// Pages per vision request during page analysis.
  final int pagesPerVisionRequest;

  /// Questions marked per request.
  final int questionsPerMarkingRequest;

  /// Images attached to one request, at most.
  final int maxImagesPerRequest;

  /// Whether diagrams, graphs, tables and equations get their own analysis.
  final bool visualAnalysis;

  /// Shows the page inspector: every region, its type, confidence and
  /// question.
  final bool developerMode;

  /// Whether intermediate results are cached on disk and reused.
  final bool cacheEnabled;

  /// An already-running recogniser to use instead of starting one.
  final String? ocrEndpoint;
  final String? ocrToken;

  String get effectiveVisionModel =>
      (visionModel?.trim().isNotEmpty ?? false) ? visionModel!.trim() : model;

  String get effectiveDiagramModel =>
      (diagramModel?.trim().isNotEmpty ?? false)
          ? diagramModel!.trim()
          : effectiveVisionModel;

  /// The chain for a vision task: the chosen vision model first, then the
  /// marking chain as fallbacks.
  List<String> chainFor(String first) =>
      <String>{first, ...modelChain}.where((String m) => m.isNotEmpty).toList();

  bool get hasApiKey => apiKey != null && apiKey!.isNotEmpty;

  /// Every model marking may use, best first, without repeats.
  List<String> get modelChain =>
      <String>{model, ...fallbackModels}.where((String m) => m.isNotEmpty).toList();

  /// The same configuration with a different credential or model, used when
  /// the teacher saves them in Settings.
  AppConfig withApiKey(String? newApiKey) => copyWith(apiKey: () => newApiKey);

  AppConfig withModel(String newModel) =>
      newModel.trim().isEmpty ? this : copyWith(model: newModel.trim());

  AppConfig withFallbackModels(List<String> models) =>
      copyWith(fallbackModels: models);

  /// [apiKey] is passed as a callback so that clearing it is expressible;
  /// a plain nullable parameter cannot tell "leave it alone" from "set it to
  /// null", and removing a saved key is something Settings must be able to do.
  AppConfig copyWith({
    String? Function()? apiKey,
    String? model,
    String? effort,
    int? maxTokens,
    List<String>? fallbackModels,
    bool? ocrEnabled,
    String? trocrModel,
    double? ocrConfidenceThreshold,
    bool? visionCrossCheck,
    int? ocrDpi,
    String? Function()? visionModel,
    String? Function()? diagramModel,
    String? apiEndpoint,
    Duration? requestTimeout,
    int? retryCount,
    LayoutEngine? layoutEngine,
    double? reviewThreshold,
    int? maxImageDimension,
    int? pagesPerVisionRequest,
    int? questionsPerMarkingRequest,
    int? maxImagesPerRequest,
    bool? visualAnalysis,
    bool? developerMode,
    bool? cacheEnabled,
  }) {
    return AppConfig(
      apiKey: apiKey == null ? this.apiKey : apiKey(),
      model: model ?? this.model,
      effort: effort ?? this.effort,
      maxTokens: maxTokens ?? this.maxTokens,
      fallbackModels: fallbackModels ?? this.fallbackModels,
      ocrEnabled: ocrEnabled ?? this.ocrEnabled,
      trocrModel: trocrModel ?? this.trocrModel,
      ocrConfidenceThreshold:
          ocrConfidenceThreshold ?? this.ocrConfidenceThreshold,
      visionCrossCheck: visionCrossCheck ?? this.visionCrossCheck,
      ocrDpi: ocrDpi ?? this.ocrDpi,
      visionModel: visionModel == null ? this.visionModel : visionModel(),
      diagramModel: diagramModel == null ? this.diagramModel : diagramModel(),
      apiEndpoint: apiEndpoint ?? this.apiEndpoint,
      requestTimeout: requestTimeout ?? this.requestTimeout,
      retryCount: retryCount ?? this.retryCount,
      layoutEngine: layoutEngine ?? this.layoutEngine,
      reviewThreshold: reviewThreshold ?? this.reviewThreshold,
      maxImageDimension: maxImageDimension ?? this.maxImageDimension,
      pagesPerVisionRequest:
          pagesPerVisionRequest ?? this.pagesPerVisionRequest,
      questionsPerMarkingRequest:
          questionsPerMarkingRequest ?? this.questionsPerMarkingRequest,
      maxImagesPerRequest: maxImagesPerRequest ?? this.maxImagesPerRequest,
      visualAnalysis: visualAnalysis ?? this.visualAnalysis,
      developerMode: developerMode ?? this.developerMode,
      cacheEnabled: cacheEnabled ?? this.cacheEnabled,
      ocrEndpoint: ocrEndpoint,
      ocrToken: ocrToken,
    );
  }

  /// Reads configuration from the environment, the saved settings, and `.env`.
  static Future<AppConfig> load({
    SettingsStore settings = const SettingsStore(),
  }) async {
    final Map<String, String> fromDotEnv = await _readDotEnv();
    final Map<String, String> fromSettings = await settings.read();

    return fromMap(
      Platform.environment,
      // A key typed into the application beats a stale .env; a real environment
      // variable beats both.
      fallback: <String, String>{...fromDotEnv, ...fromSettings},
    );
  }

  /// Builds a config from raw key/value sources. Exposed for tests.
  static AppConfig fromMap(
    Map<String, String> environment, {
    Map<String, String> fallback = const <String, String>{},
  }) {
    String? read(String key) {
      final String? value = environment[key] ?? fallback[key];
      return (value == null || value.isEmpty) ? null : value;
    }

    // Distinguishes "not configured" from "deliberately set to nothing", which
    // is how a teacher turns fallbacks off to keep one batch on one model.
    bool isSet(String key) =>
        environment.containsKey(key) || fallback.containsKey(key);

    final String? rawMaxTokens = read('EXAM_CORRECTOR_MAX_TOKENS');
    final int maxTokens;
    if (rawMaxTokens == null) {
      maxTokens = AppConstants.defaultMaxTokens;
    } else {
      final int? parsed = int.tryParse(rawMaxTokens);
      if (parsed == null || parsed <= 0) {
        throw ConfigException(
          'EXAM_CORRECTOR_MAX_TOKENS must be a positive whole number, '
          'got "$rawMaxTokens".',
        );
      }
      maxTokens = parsed;
    }

    const String fallbackKey = 'EXAM_CORRECTOR_FALLBACK_MODELS';
    final List<String> fallbackModels = isSet(fallbackKey)
        ? parseModelList(read(fallbackKey) ?? '')
        : AppConstants.defaultFallbackModels;

    return AppConfig(
      // GOOGLE_API_KEY is accepted too: the Google SDKs read either name.
      apiKey: read('GEMINI_API_KEY') ?? read('GOOGLE_API_KEY'),
      model: read('EXAM_CORRECTOR_MODEL') ?? AppConstants.defaultModel,
      effort: read('EXAM_CORRECTOR_EFFORT') ?? AppConstants.defaultEffort,
      maxTokens: maxTokens,
      fallbackModels: fallbackModels,
      ocrEnabled: _flag(read('EXAM_CORRECTOR_OCR_ENABLED'), orElse: true),
      trocrModel:
          read('EXAM_CORRECTOR_TROCR_MODEL') ?? AppConstants.defaultTrocrModel,
      ocrConfidenceThreshold: _threshold(read('EXAM_CORRECTOR_OCR_THRESHOLD')),
      visionCrossCheck:
          _flag(read('EXAM_CORRECTOR_OCR_VISION_CHECK'), orElse: true),
      ocrDpi: _dpi(read('EXAM_CORRECTOR_OCR_DPI')),
      visionModel: read('EXAM_CORRECTOR_VISION_MODEL'),
      diagramModel: read('EXAM_CORRECTOR_DIAGRAM_MODEL'),
      apiEndpoint: _endpoint(read('EXAM_CORRECTOR_API_ENDPOINT')),
      requestTimeout: Duration(
        seconds: _integer(
          read('EXAM_CORRECTOR_TIMEOUT_SECONDS'),
          'EXAM_CORRECTOR_TIMEOUT_SECONDS',
          min: 10,
          max: 3600,
          orElse: AppConstants.apiIdleTimeout.inSeconds,
        ),
      ),
      retryCount: _integer(
        read('EXAM_CORRECTOR_RETRIES'),
        'EXAM_CORRECTOR_RETRIES',
        min: 0,
        max: 6,
        orElse: AppConstants.defaultRetryCount,
      ),
      layoutEngine: LayoutEngine.parse(read('EXAM_CORRECTOR_LAYOUT_ENGINE')),
      reviewThreshold: _fraction(
        read('EXAM_CORRECTOR_REVIEW_THRESHOLD'),
        'EXAM_CORRECTOR_REVIEW_THRESHOLD',
        orElse: AppConstants.defaultReviewThreshold,
      ),
      maxImageDimension: _integer(
        read('EXAM_CORRECTOR_MAX_IMAGE_DIM'),
        'EXAM_CORRECTOR_MAX_IMAGE_DIM',
        min: 256,
        max: 4096,
        orElse: AppConstants.defaultMaxImageDimension,
      ),
      pagesPerVisionRequest: _integer(
        read('EXAM_CORRECTOR_PAGES_PER_REQUEST'),
        'EXAM_CORRECTOR_PAGES_PER_REQUEST',
        min: 1,
        max: 8,
        orElse: AppConstants.defaultPagesPerVisionRequest,
      ),
      questionsPerMarkingRequest: _integer(
        read('EXAM_CORRECTOR_QUESTIONS_PER_REQUEST'),
        'EXAM_CORRECTOR_QUESTIONS_PER_REQUEST',
        min: 1,
        max: 40,
        orElse: AppConstants.defaultQuestionsPerMarkingRequest,
      ),
      maxImagesPerRequest: _integer(
        read('EXAM_CORRECTOR_MAX_IMAGES_PER_REQUEST'),
        'EXAM_CORRECTOR_MAX_IMAGES_PER_REQUEST',
        min: 0,
        max: 40,
        orElse: AppConstants.defaultMaxImagesPerRequest,
      ),
      visualAnalysis:
          _flag(read('EXAM_CORRECTOR_VISUAL_ANALYSIS'), orElse: true),
      developerMode: _flag(read('EXAM_CORRECTOR_DEBUG'), orElse: false),
      cacheEnabled: _flag(read('EXAM_CORRECTOR_CACHE'), orElse: true),
      ocrEndpoint: read('EXAM_CORRECTOR_OCR_ENDPOINT'),
      ocrToken: read('EXAM_CORRECTOR_OCR_TOKEN'),
    );
  }

  static int _integer(
    String? value,
    String name, {
    required int min,
    required int max,
    required int orElse,
  }) {
    if (value == null) return orElse;
    final int? parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < min || parsed > max) {
      throw ConfigException(
        '$name must be a whole number from $min to $max, got "$value".',
      );
    }
    return parsed;
  }

  static double _fraction(String? value, String name, {required double orElse}) {
    if (value == null) return orElse;
    final double? parsed = double.tryParse(value.trim());
    if (parsed == null || parsed < 0 || parsed > 1) {
      throw ConfigException('$name must be between 0 and 1, got "$value".');
    }
    return parsed;
  }

  static String _endpoint(String? value) {
    if (value == null) return AppConstants.apiEndpoint;
    final Uri? uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
      throw ConfigException(
        'EXAM_CORRECTOR_API_ENDPOINT must be an http(s) URL, got "$value".',
      );
    }
    return value.trim();
  }

  static bool _flag(String? value, {required bool orElse}) {
    if (value == null) return orElse;
    final String normalised = value.trim().toLowerCase();
    if (<String>['1', 'true', 'yes', 'on'].contains(normalised)) return true;
    if (<String>['0', 'false', 'no', 'off'].contains(normalised)) return false;
    throw ConfigException(
      'Expected true or false, got "$value".',
    );
  }

  static double _threshold(String? value) {
    if (value == null) return AppConstants.defaultOcrConfidenceThreshold;

    final double? parsed = double.tryParse(value.trim());
    if (parsed == null || parsed < 0 || parsed > 1) {
      throw ConfigException(
        'EXAM_CORRECTOR_OCR_THRESHOLD must be between 0 and 1, got "$value".',
      );
    }
    return parsed;
  }

  static int _dpi(String? value) {
    if (value == null) return AppConstants.defaultOcrDpi;

    // The sidecar clamps to this range too; rejecting here means a typo is
    // reported rather than silently ignored.
    final int? parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 100 || parsed > 400) {
      throw ConfigException(
        'EXAM_CORRECTOR_OCR_DPI must be between 100 and 400, got "$value".',
      );
    }
    return parsed;
  }

  /// Splits a comma-separated model list, dropping blanks. An explicitly empty
  /// setting means "no fallbacks", which is why it is not defaulted here.
  static List<String> parseModelList(String value) => value
      .split(',')
      .map((String model) => model.trim())
      .where((String model) => model.isNotEmpty)
      .toList();

  static Future<Map<String, String>> _readDotEnv() async {
    for (final File file in _dotEnvCandidates()) {
      if (!await file.exists()) continue;
      try {
        return parseDotEnv(await file.readAsString());
      } on IOException {
        // An unreadable .env is not fatal: the environment or the saved
        // settings may still carry the key, and correction reports a missing
        // credential clearly.
        continue;
      }
    }
    return const <String, String>{};
  }

  /// Where a `.env` may reasonably live.
  ///
  /// A packaged application keeps it beside the executable. During development
  /// the executable sits deep inside `build/`, and the working directory of a
  /// launched app bundle is not the project — so the project root is found by
  /// walking up to the directory that holds `pubspec.yaml`. Anchoring on
  /// `pubspec.yaml` means an unrelated `.env` further up the disk is never
  /// picked up.
  static Iterable<File> _dotEnvCandidates() sync* {
    final String separator = Platform.pathSeparator;
    final Directory executableDirectory =
        File(Platform.resolvedExecutable).parent;

    yield File('${executableDirectory.path}$separator.env');
    yield File('${Directory.current.path}$separator.env');

    for (final Directory start in <Directory>[
      Directory.current,
      executableDirectory,
    ]) {
      Directory directory = start;
      while (true) {
        if (File('${directory.path}${separator}pubspec.yaml').existsSync()) {
          yield File('${directory.path}$separator.env');
          break;
        }
        final Directory parent = directory.parent;
        if (parent.path == directory.path) break;
        directory = parent;
      }
    }
  }

  /// Parses `KEY=value` lines, ignoring comments and surrounding quotes.
  static Map<String, String> parseDotEnv(String contents) {
    final Map<String, String> values = <String, String>{};

    for (final String rawLine in contents.split('\n')) {
      final String line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final int separator = line.indexOf('=');
      if (separator <= 0) continue;

      final String key = line.substring(0, separator).trim();
      String value = line.substring(separator + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      if (key.isNotEmpty) values[key] = value;
    }

    return values;
  }
}
