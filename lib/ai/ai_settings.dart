import 'dart:io';

import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/core/config/dotenv.dart';
import 'package:exam_corrector/services/settings_store.dart';

/// Everything the AI layer needs to know: where each provider is, which
/// models do which job, and how hard to retry.
///
/// Reading settings never fails. A value that cannot be used is replaced by
/// its default and named in [warnings], so a stale or mistyped setting can
/// never stop the application from starting.
class AiSettings {
  const AiSettings({
    required this.providers,
    this.roles = ModelRoles.defaults,
    this.retries = defaultRetries,
    this.warnings = const <String>[],
  });

  final Providers providers;
  final ModelRoles roles;

  /// Times a request that may pass on its own — a rate limit, a busy server,
  /// a dropped connection — is retried on the same model.
  final int retries;

  /// Settings that were ignored, and why.
  final List<String> warnings;

  static const int defaultRetries = 2;

  /// What the teacher is told while no model can be reached at all.
  static const String notReadyMessage =
      'Add a Gemini API key in Settings to start marking — it is free at aistudio.google.com/apikey.';
  static const String retriesName = 'EXAM_CORRECTOR_RETRIES';

  /// Whether any model of any role can be asked at all.
  bool get hasModelAccess => ModelRole.values.any(
        (ModelRole role) => roles.chain(role).any((String model) => providers.of(model)?.isConfigured ?? false),
      );

  AiSettings copyWith({Providers? providers, ModelRoles? roles, int? retries}) => AiSettings(
        providers: providers ?? this.providers,
        roles: roles ?? this.roles,
        retries: retries ?? this.retries,
        warnings: warnings,
      );

  /// Reads the environment, the saved settings and `.env`. A real environment
  /// variable beats a value typed into the application, which beats `.env`.
  static Future<AiSettings> load({SettingsStore settings = const SettingsStore()}) async {
    final Map<String, String> fromDotEnv = await DotEnv.read();
    final Map<String, String> fromSettings = await settings.read();
    return fromMap(Platform.environment, fallback: <String, String>{...fromDotEnv, ...fromSettings});
  }

  static AiSettings fromMap(
    Map<String, String> environment, {
    Map<String, String> fallback = const <String, String>{},
  }) {
    String? read(String key) {
      final String? value = environment[key] ?? fallback[key];
      return (value == null || value.trim().isEmpty) ? null : value.trim();
    }

    final List<String> warnings = <String>[];
    int retries = defaultRetries;
    if (read(retriesName) case final String raw) {
      final int? parsed = int.tryParse(raw);
      if (parsed == null || parsed < 0 || parsed > 6) {
        warnings.add('$retriesName must be a whole number from 0 to 6, not "$raw"; using $defaultRetries.');
      } else {
        retries = parsed;
      }
    }

    final Providers providers = Providers.fromSettings(read);
    final ModelRoles roles = ModelRoles.fromSettings(read);
    for (final ModelRole role in ModelRole.values) {
      for (final String model in roles.chain(role)) {
        if (providers.of(model) == null) {
          warnings.add('"$model" (${role.label}) does not start with a known provider: '
              '${providers.all.map((ModelProvider p) => '${p.id}/').join(', ')}.');
        }
      }
    }
    return AiSettings(providers: providers, roles: roles, retries: retries, warnings: warnings);
  }
}
