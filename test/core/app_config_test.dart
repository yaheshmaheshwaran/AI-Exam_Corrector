import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/constants/app_constants.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';

void main() {
  group('AppConfig', () {
    test('falls back to defaults when nothing is set', () {
      final AppConfig config = AppConfig.fromMap(const <String, String>{});

      expect(config.apiKey, isNull);
      expect(config.hasApiKey, isFalse);
      expect(config.model, AppConstants.defaultModel);
      expect(config.effort, AppConstants.defaultEffort);
      expect(config.maxTokens, AppConstants.defaultMaxTokens);
    });

    test('reads overrides from the environment', () {
      final AppConfig config = AppConfig.fromMap(const <String, String>{
        'GEMINI_API_KEY': 'test-key',
        'EXAM_CORRECTOR_MODEL': 'gemini-2.5-pro',
        'EXAM_CORRECTOR_EFFORT': 'medium',
        'EXAM_CORRECTOR_MAX_TOKENS': '8000',
      });

      expect(config.hasApiKey, isTrue);
      expect(config.model, 'gemini-2.5-pro');
      expect(config.effort, 'medium');
      expect(config.maxTokens, 8000);
    });

    test('lets real environment variables win over .env values', () {
      final AppConfig config = AppConfig.fromMap(
        const <String, String>{'GEMINI_API_KEY': 'from-environment'},
        fallback: const <String, String>{'GEMINI_API_KEY': 'from-dotenv'},
      );

      expect(config.apiKey, 'from-environment');
    });

    test('uses .env values when the environment is silent', () {
      final AppConfig config = AppConfig.fromMap(
        const <String, String>{},
        fallback: const <String, String>{'GEMINI_API_KEY': 'from-dotenv'},
      );

      expect(config.apiKey, 'from-dotenv');
    });

    test('defaults to the built-in fallback chain', () {
      final AppConfig config = AppConfig.fromMap(const <String, String>{});

      expect(config.fallbackModels, AppConstants.defaultFallbackModels);
      expect(config.modelChain.first, AppConstants.defaultModel);
    });

    test('reads a comma-separated fallback chain', () {
      final AppConfig config = AppConfig.fromMap(const <String, String>{
        'EXAM_CORRECTOR_MODEL': 'gemini-3.6-flash',
        'EXAM_CORRECTOR_FALLBACK_MODELS':
            ' gemini-3.5-flash , gemini-3.5-flash-lite ,, ',
      });

      expect(config.modelChain, <String>[
        'gemini-3.6-flash',
        'gemini-3.5-flash',
        'gemini-3.5-flash-lite',
      ]);
    });

    test('never repeats the primary model in the chain', () {
      final AppConfig config = AppConfig.fromMap(const <String, String>{
        'EXAM_CORRECTOR_MODEL': 'gemini-3.6-flash',
        'EXAM_CORRECTOR_FALLBACK_MODELS': 'gemini-3.6-flash, gemini-3.5-flash',
      });

      expect(config.modelChain, <String>['gemini-3.6-flash', 'gemini-3.5-flash']);
    });

    test('an empty setting turns fallbacks off', () {
      // Deliberate: it keeps every paper in a batch on one model.
      final AppConfig config = AppConfig.fromMap(const <String, String>{
        'EXAM_CORRECTOR_FALLBACK_MODELS': '',
      });

      expect(config.fallbackModels, isEmpty);
      expect(config.modelChain, hasLength(1));
    });

    test('rejects a non-numeric token limit', () {
      expect(
        () => AppConfig.fromMap(
          const <String, String>{'EXAM_CORRECTOR_MAX_TOKENS': 'lots'},
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('parses .env files, ignoring comments and quotes', () {
      final Map<String, String> values = AppConfig.parseDotEnv('''
# a comment
GEMINI_API_KEY="gemini-quoted"

EXAM_CORRECTOR_EFFORT = high
not a pair
''');

      expect(values['GEMINI_API_KEY'], 'gemini-quoted');
      expect(values['EXAM_CORRECTOR_EFFORT'], 'high');
      expect(values.containsKey('not a pair'), isFalse);
    });
  });

  group('formatting', () {
    test('formats marks without trailing zeros', () {
      expect(formatMarks(4), '4');
      expect(formatMarks(4.5), '4.5');
      expect(formatMarks(0.25), '0.25');
    });

    test('formats percentages and counts', () {
      expect(formatPercentage(83.6), '84%');
      expect(formatCount(12480), '12,480');
      expect(formatCount(42), '42');
    });
  });
}
