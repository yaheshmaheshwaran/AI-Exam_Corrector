import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/config/dotenv.dart';
import 'package:exam_corrector/core/constants/app_constants.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';

void main() {
  group('AppConfig', () {
    test('falls back to defaults when nothing is set', () {
      final AppConfig config = AppConfig.fromMap(const <String, String>{});
      expect(config.reviewThreshold, AppConstants.defaultReviewThreshold);
      expect(config.backgroundProcessing, isFalse);
      expect(config.developerMode, isFalse);
      expect(config.cacheEnabled, isTrue);
      expect(config.warnings, isEmpty);
    });

    test('reads overrides, and real environment variables win over saved settings and .env', () {
      final AppConfig config = AppConfig.fromMap(
        const <String, String>{AppConfig.backgroundName: 'yes'},
        fallback: const <String, String>{
          AppConfig.backgroundName: 'false',
          AppConfig.reviewThresholdName: '0.85',
          AppConfig.developerModeName: 'on',
          AppConfig.cacheName: '0',
        },
      );
      expect(config.backgroundProcessing, isTrue);
      expect(config.reviewThreshold, 0.85);
      expect(config.developerMode, isTrue);
      expect(config.cacheEnabled, isFalse);
    });

    test('a value that cannot be used never stops the app: it is named and defaulted', () {
      final AppConfig config = AppConfig.fromMap(const <String, String>{
        AppConfig.reviewThresholdName: '1.5',
        AppConfig.backgroundName: 'sometimes',
      });
      expect(config.reviewThreshold, AppConstants.defaultReviewThreshold);
      expect(config.backgroundProcessing, isFalse);
      expect(config.warnings, hasLength(2));
    });

    test('parses .env files, ignoring comments and quotes', () {
      final Map<String, String> values = DotEnv.parse('''
# a comment
GEMINI_API_KEY="quoted key"
EMPTY=
NOT A LINE
EXAM_CORRECTOR_DEBUG='true'
''');
      expect(values['GEMINI_API_KEY'], 'quoted key');
      expect(values['EMPTY'], '');
      expect(values['EXAM_CORRECTOR_DEBUG'], 'true');
      expect(values.containsKey('NOT A LINE'), isFalse);
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
