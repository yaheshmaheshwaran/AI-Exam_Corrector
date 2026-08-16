import 'dart:io';

import 'package:exam_corrector/core/constants/app_constants.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/settings_store.dart';

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
  });

  final String? apiKey;
  final String model;
  final String effort;
  final int maxTokens;

  /// Models to fall back to, in order, as each one's daily quota runs out.
  final List<String> fallbackModels;

  bool get hasApiKey => apiKey != null && apiKey!.isNotEmpty;

  /// Every model marking may use, best first, without repeats.
  List<String> get modelChain =>
      <String>{model, ...fallbackModels}.where((String m) => m.isNotEmpty).toList();

  /// The same configuration with a different credential or model, used when
  /// the teacher saves them in Settings.
  AppConfig withApiKey(String? newApiKey) => AppConfig(
        apiKey: newApiKey,
        model: model,
        effort: effort,
        maxTokens: maxTokens,
        fallbackModels: fallbackModels,
      );

  AppConfig withModel(String newModel) => AppConfig(
        apiKey: apiKey,
        model: newModel.trim().isEmpty ? model : newModel.trim(),
        effort: effort,
        maxTokens: maxTokens,
        fallbackModels: fallbackModels,
      );

  AppConfig withFallbackModels(List<String> models) => AppConfig(
        apiKey: apiKey,
        model: model,
        effort: effort,
        maxTokens: maxTokens,
        fallbackModels: models,
      );

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
    );
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
