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

    final File? file = _file;
    if (file == null) return;

    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(values));
  }

  /// Where the settings live, for showing the teacher.
  String get location => _file?.path ?? 'unavailable on this platform';

  File? get _file {
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
    return File('$directory${separator}settings.json');
  }
}
