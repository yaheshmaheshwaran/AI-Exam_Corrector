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

  // The AI providers and which models do each job (lib/ai). The names match
  // the environment variables, so the settings and a .env are read alike.
  static const String apiKeyField = 'GEMINI_API_KEY';
  static const String nvidiaKeyField = 'NVIDIA_API_KEY';
  static const String prepModelsField = 'EXAM_CORRECTOR_PREP_MODELS';
  static const String readerModelsField = 'EXAM_CORRECTOR_READER_MODELS';
  static const String markerModelsField = 'EXAM_CORRECTOR_MARKER_MODELS';

  // How marking behaves (AppConfig).
  static const String reviewThresholdField = 'EXAM_CORRECTOR_REVIEW_THRESHOLD';
  static const String backgroundField = 'EXAM_CORRECTOR_BACKGROUND';
  static const String developerModeField = 'EXAM_CORRECTOR_DEBUG';

  /// Settings of the pipeline before the 2026 rewrite: one Gemini model and
  /// its backups, the open-model presets, TrOCR and the layout engine. Removed
  /// whenever settings are saved: read now, they would only mislead.
  static const List<String> retiredFields = <String>[
    'EXAM_CORRECTOR_MODEL',
    'EXAM_CORRECTOR_FALLBACK_MODELS',
    'EXAM_CORRECTOR_READING_MODELS',
    'EXAM_CORRECTOR_USE_GEMINI',
    'EXAM_CORRECTOR_OPEN_PRESET',
    'EXAM_CORRECTOR_OPEN_MODEL',
    'EXAM_CORRECTOR_OCR_ENABLED',
    'EXAM_CORRECTOR_TROCR_MODEL',
    'EXAM_CORRECTOR_OCR_THRESHOLD',
    'EXAM_CORRECTOR_OCR_VISION_CHECK',
    'EXAM_CORRECTOR_OCR_DPI',
    'EXAM_CORRECTOR_LAYOUT_ENGINE',
    'EXAM_CORRECTOR_VISION_MODEL',
    'EXAM_CORRECTOR_VISUAL_ANALYSIS',
    'EXAM_CORRECTOR_EXAM_PREP',
    'HF_TOKEN',
  ];

  // Click sounds on controls: on unless turned off.
  static const String soundsField = 'EXAM_CORRECTOR_SOUNDS';

  // Glass blur on the floating bars: from 0 (solid) to 1. Older versions
  // saved 'true' or 'false'.
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
    String? nvidiaKey,
    String? prepModels,
    String? readerModels,
    String? markerModels,
    double? reviewThreshold,
    bool? backgroundProcessing,
    bool? developerMode,
    bool? sounds,
    double? transparency,
    String? supabaseUrl,
    String? supabaseAnonKey,
    Map<String, String> openModels = const <String, String>{},
  }) async {
    final Map<String, String> values = Map<String, String>.from(await read())
      ..removeWhere((String field, String _) => retiredFields.contains(field));

    void put(String field, String? value) {
      if (value == null) return;
      if (value.trim().isEmpty) {
        values.remove(field);
      } else {
        values[field] = value.trim();
      }
    }

    put(apiKeyField, apiKey);
    // Booleans are written as the same words AppConfig parses from the
    // environment, so a settings file can be read as if it were a .env.
    if (reviewThreshold != null) {
      values[reviewThresholdField] = reviewThreshold.toStringAsFixed(2);
    }
    if (backgroundProcessing != null) values[backgroundField] = '$backgroundProcessing';
    if (developerMode != null) values[developerModeField] = '$developerMode';
    if (sounds != null) values[soundsField] = '$sounds';
    if (transparency != null) {
      values[transparencyField] = transparency.toStringAsFixed(2);
    }

    put(supabaseUrlField, supabaseUrl);
    put(supabaseAnonKeyField, supabaseAnonKey);

    put(nvidiaKeyField, nvidiaKey);
    put(prepModelsField, prepModels);
    put(readerModelsField, readerModels);
    put(markerModelsField, markerModels);

    // Our own model servers' addresses and keys, as lib/ai/providers.dart
    // names them.
    openModels.forEach(put);

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
