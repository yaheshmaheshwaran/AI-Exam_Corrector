import 'dart:convert';
import 'dart:io';

/// Per-user settings, stored where a Windows application is expected to keep
/// them: `%APPDATA%\Exam Corrector\settings.json`.
///
/// This exists so a teacher who runs the packaged `.exe` can enter their API
/// key in the application instead of setting an environment variable. The key
/// is written to the user's own profile and never to the project folder.
class SettingsStore {
  const SettingsStore();

  static const String apiKeyField = 'GEMINI_API_KEY';
  static const String modelField = 'EXAM_CORRECTOR_MODEL';
  static const String fallbackModelsField = 'EXAM_CORRECTOR_FALLBACK_MODELS';

  // Handwriting recognition. The field names match the environment variables
  // so that AppConfig can merge both sources without translating between them.
  static const String ocrEnabledField = 'EXAM_CORRECTOR_OCR_ENABLED';
  static const String trocrModelField = 'EXAM_CORRECTOR_TROCR_MODEL';
  static const String ocrThresholdField = 'EXAM_CORRECTOR_OCR_THRESHOLD';
  static const String visionCrossCheckField =
      'EXAM_CORRECTOR_OCR_VISION_CHECK';
  static const String ocrDpiField = 'EXAM_CORRECTOR_OCR_DPI';

  // Page understanding and marking.
  static const String layoutEngineField = 'EXAM_CORRECTOR_LAYOUT_ENGINE';
  static const String visionModelField = 'EXAM_CORRECTOR_VISION_MODEL';
  static const String reviewThresholdField = 'EXAM_CORRECTOR_REVIEW_THRESHOLD';
  static const String visualAnalysisField = 'EXAM_CORRECTOR_VISUAL_ANALYSIS';
  static const String developerModeField = 'EXAM_CORRECTOR_DEBUG';

  // Appearance: system, light or dark.
  static const String themeField = 'EXAM_CORRECTOR_THEME';

  // Click sounds on controls: on unless turned off.
  static const String soundsField = 'EXAM_CORRECTOR_SOUNDS';

  // Frosted surfaces: how clear, from 0 (solid) to 1. Older versions saved
  // 'true' or 'false'.
  static const String transparencyField = 'EXAM_CORRECTOR_TRANSPARENCY';

  // The college server: where accounts and published results live. The URL
  // and public key of a Supabase project, entered once on this computer.
  static const String supabaseUrlField = 'SUPABASE_URL';
  static const String supabaseAnonKeyField = 'SUPABASE_ANON_KEY';

  /// Returns the stored values, or an empty map when nothing is saved yet.
  Future<Map<String, String>> read() async {
    final File? file = _file;
    if (file == null || !await file.exists()) return const <String, String>{};

    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return const <String, String>{};

      return <String, String>{
        for (final MapEntry<String, dynamic> entry in decoded.entries)
          if (entry.value is String && (entry.value as String).isNotEmpty)
            entry.key: entry.value as String,
      };
    } on IOException {
      return const <String, String>{};
    } on FormatException {
      return const <String, String>{};
    }
  }

  /// Saves the settings the teacher can change, removing any left empty.
  Future<void> save({
    String? apiKey,
    String? model,
    String? fallbackModels,
    bool? ocrEnabled,
    String? trocrModel,
    double? ocrThreshold,
    bool? visionCrossCheck,
    int? ocrDpi,
    String? layoutEngine,
    String? visionModel,
    double? reviewThreshold,
    bool? visualAnalysis,
    bool? developerMode,
    String? theme,
    bool? sounds,
    double? transparency,
    String? supabaseUrl,
    String? supabaseAnonKey,
  }) async {
    final Map<String, String> values = Map<String, String>.from(await read());

    void put(String field, String? value) {
      if (value == null) return;
      if (value.trim().isEmpty) {
        values.remove(field);
      } else {
        values[field] = value.trim();
      }
    }

    put(apiKeyField, apiKey);
    put(modelField, model);
    // An empty list is a deliberate choice ("keep every paper on one model"),
    // so it is stored as an empty value rather than removed.
    if (fallbackModels != null) values[fallbackModelsField] = fallbackModels.trim();

    // Booleans are written as the same words AppConfig parses from the
    // environment, so a settings file can be read as if it were a .env.
    if (ocrEnabled != null) values[ocrEnabledField] = '$ocrEnabled';
    if (visionCrossCheck != null) {
      values[visionCrossCheckField] = '$visionCrossCheck';
    }
    put(trocrModelField, trocrModel);
    if (ocrThreshold != null) {
      values[ocrThresholdField] = ocrThreshold.toStringAsFixed(2);
    }
    if (ocrDpi != null) values[ocrDpiField] = '$ocrDpi';

    put(layoutEngineField, layoutEngine);
    put(visionModelField, visionModel);
    if (reviewThreshold != null) {
      values[reviewThresholdField] = reviewThreshold.toStringAsFixed(2);
    }
    if (visualAnalysis != null) values[visualAnalysisField] = '$visualAnalysis';
    if (developerMode != null) values[developerModeField] = '$developerMode';
    put(themeField, theme);
    if (sounds != null) values[soundsField] = '$sounds';
    if (transparency != null) {
      values[transparencyField] = transparency.toStringAsFixed(2);
    }

    put(supabaseUrlField, supabaseUrl);
    put(supabaseAnonKeyField, supabaseAnonKey);

    final File? file = _file;
    if (file == null) return;

    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(values));
  }

  /// Where the settings live, for showing the teacher.
  String get location => _file?.path ?? 'unavailable on this platform';

  File? get _file {
    final Directory? directory = supportDirectory();
    if (directory == null) return null;
    return File('${directory.path}${Platform.pathSeparator}settings.json');
  }

  /// The application's per-user folder: `%APPDATA%\Exam Corrector` on
  /// Windows. Settings live here, and so does the processing cache.
  static Directory? supportDirectory() {
    final Map<String, String> environment = Platform.environment;
    final String separator = Platform.pathSeparator;

    String? directory;
    if (Platform.isWindows) {
      directory = environment['APPDATA'];
      if (directory != null) directory = '$directory${separator}Exam Corrector';
    } else if (Platform.isMacOS) {
      final String? home = environment['HOME'];
      if (home != null) {
        directory = '$home/Library/Application Support/Exam Corrector';
      }
    } else {
      final String? config = environment['XDG_CONFIG_HOME'] ??
          (environment['HOME'] == null ? null : '${environment['HOME']}/.config');
      if (config != null) directory = '$config/exam-corrector';
    }

    if (directory == null) return null;
    return Directory(directory);
  }
}
