import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/providers.dart';

void main() {
  test('a new install has the chosen models and asks for keys', () {
    final AiSettings settings = AiSettings.fromMap(const <String, String>{});

    expect(settings.roles.prep.first, 'nvidia/moonshotai/kimi-k3');
    expect(settings.roles.reader.first, startsWith('gemini/'));
    expect(settings.retries, AiSettings.defaultRetries);
    expect(settings.warnings, isEmpty);
    expect(settings.hasModelAccess, isFalse);
    expect(settings.providers.byId('ollama')!.isConfigured, isTrue, reason: 'Ollama needs no key');
  });

  test('a Gemini key alone gives access', () {
    final AiSettings settings = AiSettings.fromMap(const <String, String>{Providers.geminiKeyName: 'k'});
    expect(settings.hasModelAccess, isTrue);
    expect(AiSettings.fromMap(const <String, String>{Providers.googleKeyName: 'k'}).hasModelAccess, isTrue);
  });

  test('the environment beats saved settings and .env', () {
    final AiSettings settings = AiSettings.fromMap(
      const <String, String>{Providers.nvidiaKeyName: 'from-env'},
      fallback: const <String, String>{Providers.nvidiaKeyName: 'from-file', Providers.geminiKeyName: 'g'},
    );
    expect(settings.providers.byId('nvidia')!.apiKey, 'from-env');
    expect(settings.providers.byId('gemini')!.apiKey, 'g');
  });

  test("each role's models are read in order, and a role not set keeps its default", () {
    final AiSettings settings = AiSettings.fromMap(const <String, String>{
      'EXAM_CORRECTOR_READER_MODELS': ' gemini/gemini-3.5-flash-lite , server/Qwen/Qwen3-VL-8B-Instruct ,',
    });
    expect(settings.roles.chain(ModelRole.reader),
        <String>['gemini/gemini-3.5-flash-lite', 'server/Qwen/Qwen3-VL-8B-Instruct']);
    expect(settings.roles.marker, ModelRoles.defaults.marker);
  });

  test('a setting that cannot be used never stops the app: it is named and defaulted', () {
    final AiSettings settings = AiSettings.fromMap(const <String, String>{
      AiSettings.retriesName: 'lots',
      'EXAM_CORRECTOR_MARKER_MODELS': 'gemini-3.6-flash',
    });
    expect(settings.retries, AiSettings.defaultRetries);
    expect(settings.warnings, hasLength(2));
    expect(settings.warnings.first, contains(AiSettings.retriesName));
    expect(settings.warnings.last, contains('"gemini-3.6-flash" (marking)'));
  });

  test("a server's address loses its trailing slash; an empty one is not configured", () {
    final AiSettings settings = AiSettings.fromMap(const <String, String>{
      Providers.serverAddressName: 'https://abc.trycloudflare.com/v1/',
    });
    expect(settings.providers.byId('server')!.baseUrl, 'https://abc.trycloudflare.com/v1');
    expect(AiSettings.fromMap(const <String, String>{}).providers.byId('server')!.isConfigured, isFalse);
  });
}
