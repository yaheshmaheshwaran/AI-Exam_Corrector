import 'dart:io';

import 'package:exam_corrector/core/config/dotenv.dart';
import 'package:exam_corrector/core/constants/app_constants.dart';
import 'package:exam_corrector/services/settings_store.dart';

/// The application's own settings: how marking behaves around the AI, not
/// the AI itself — where models run and which do each job is
/// `lib/ai/ai_settings.dart`.
///
/// Reading settings never fails. A value that cannot be used is replaced by
/// its default and named in [warnings], so a stale or mistyped setting can
/// never stop the application from starting.
class AppConfig {
  const AppConfig({
    this.reviewThreshold = AppConstants.defaultReviewThreshold,
    this.backgroundProcessing = false,
    this.developerMode = false,
    this.cacheEnabled = true,
    this.warnings = const <String>[],
  });

  /// A mark the AI is less sure of than this goes to the teacher for review.
  final double reviewThreshold;

  /// Marking starts by itself once the scripts and the question paper are
  /// in, and the class table stays usable while it runs.
  final bool backgroundProcessing;

  /// Adds the page inspector, for looking at what the reader found.
  final bool developerMode;

  /// Whether stage results are read back from the cache. Off, every stage
  /// runs again (images are still written).
  final bool cacheEnabled;

  /// Settings that were ignored, and why.
  final List<String> warnings;

  static const String reviewThresholdName = 'EXAM_CORRECTOR_REVIEW_THRESHOLD';
  static const String backgroundName = 'EXAM_CORRECTOR_BACKGROUND';
  static const String developerModeName = 'EXAM_CORRECTOR_DEBUG';
  static const String cacheName = 'EXAM_CORRECTOR_CACHE';

  AppConfig copyWith({
    double? reviewThreshold,
    bool? backgroundProcessing,
    bool? developerMode,
    bool? cacheEnabled,
  }) =>
      AppConfig(
        reviewThreshold: reviewThreshold ?? this.reviewThreshold,
        backgroundProcessing: backgroundProcessing ?? this.backgroundProcessing,
        developerMode: developerMode ?? this.developerMode,
        cacheEnabled: cacheEnabled ?? this.cacheEnabled,
        warnings: warnings,
      );

  /// Reads the environment, the saved settings and `.env`. A real environment
  /// variable beats a value typed into the application, which beats `.env`.
  static Future<AppConfig> load({SettingsStore settings = const SettingsStore()}) async {
    final Map<String, String> fromDotEnv = await DotEnv.read();
    final Map<String, String> fromSettings = await settings.read();
    return fromMap(Platform.environment, fallback: <String, String>{...fromDotEnv, ...fromSettings});
  }

  static AppConfig fromMap(
    Map<String, String> environment, {
    Map<String, String> fallback = const <String, String>{},
  }) {
    String? read(String key) {
      final String? value = environment[key] ?? fallback[key];
      return (value == null || value.trim().isEmpty) ? null : value.trim();
    }

    final List<String> warnings = <String>[];

    bool flag(String name, {required bool orElse}) {
      final String? value = read(name);
      if (value == null) return orElse;
      final String normalised = value.toLowerCase();
      if (const <String>['1', 'true', 'yes', 'on'].contains(normalised)) return true;
      if (const <String>['0', 'false', 'no', 'off'].contains(normalised)) return false;
      warnings.add('$name must be true or false, not "$value"; using $orElse.');
      return orElse;
    }

    double threshold = AppConstants.defaultReviewThreshold;
    if (read(reviewThresholdName) case final String raw) {
      final double? parsed = double.tryParse(raw);
      if (parsed == null || parsed < 0 || parsed > 1) {
        warnings.add('$reviewThresholdName must be between 0 and 1, not "$raw"; using $threshold.');
      } else {
        threshold = parsed;
      }
    }

    return AppConfig(
      reviewThreshold: threshold,
      backgroundProcessing: flag(backgroundName, orElse: false),
      developerMode: flag(developerModeName, orElse: false),
      cacheEnabled: flag(cacheName, orElse: true),
      warnings: warnings,
    );
  }
}
