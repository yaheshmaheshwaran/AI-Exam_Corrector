// Which models can be used right now, through the application's own client?
//
//   dart run tool/quota_probe.dart              # the first model of each job
//   dart run tool/quota_probe.dart <model> …    # specific models, e.g.
//                                               # gemini/gemini-3.1-flash-lite
//                                               # nvidia/moonshotai/kimi-k3
//                                               # ollama/qwen2.5:1.5b
//
// Sends one tiny request per model, so it costs one request from each model's
// allowance, and counts it where the application does. A diagnostic, not
// something the application runs.
import 'dart:io';

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/llm_client.dart';
import 'package:exam_corrector/ai/model_request.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';

Future<void> main(List<String> args) async {
  final AiSettings settings = await AiSettings.load();
  for (final String warning in settings.warnings) {
    stdout.writeln('Setting ignored: $warning');
  }
  final UsageMonitor usage = await UsageMonitor.ofApp(
    dailyAllowance: (String model) => settings.providers.of(model)?.dailyAllowance ?? false,
  );
  // One model at a time, so each verdict is that model's own.
  final LlmClient client = LlmClient(() => settings.copyWith(retries: 0), usage: usage);

  final List<String> models = args.isNotEmpty
      ? args
      : <String>{for (final ModelRole role in ModelRole.values) settings.roles.chain(role).first}.toList();
  stdout.writeln('Checking ${models.length} model(s).\n');

  for (final String model in models) {
    final ModelProvider? provider = settings.providers.of(model);
    final Stopwatch watch = Stopwatch()..start();
    String verdict;
    try {
      final ModelResponse response = await client.requestJson(
        const ModelRequest(
          purpose: 'availability check',
          systemInstruction: 'Answer exactly as asked.',
          parts: <ContentPart>[TextPart('Reply with {"ok": true}.')],
          schema: <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'ok': <String, Object?>{'type': 'boolean'},
            },
            'required': <String>['ok'],
          },
          maxTokens: 200,
          effort: 'low',
        ),
        models: <String>[model],
      );
      verdict = 'OK in ${watch.elapsedMilliseconds} ms → ${response.payload}';
    } on CorrectionException catch (error) {
      verdict = 'NOT USABLE: ${error.message}';
    }
    stdout.writeln('${model.padRight(40)} ${provider?.label ?? '?'}: $verdict');
  }
  await usage.saved;
  stdout.writeln('\nGemini free allowances reset at midnight Pacific time.');
}
