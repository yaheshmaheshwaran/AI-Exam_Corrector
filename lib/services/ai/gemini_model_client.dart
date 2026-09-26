import 'dart:convert';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/ai/gemini_client.dart';
import 'package:exam_corrector/services/ai/model_client.dart';

/// [ModelClient] for Google Gemini, over the Interactions API.
///
/// Owns the model chain: each model has its own daily allowance, so an
/// exhausted or busy model is a reason to move down the list rather than to
/// give up. A rejected key or a malformed request fails immediately, because
/// no other model would do better.
class GeminiModelClient implements ModelClient {
  GeminiModelClient(this._configProvider, {GeminiClient? client})
      : _client = client ?? GeminiClient();

  final AppConfig Function() _configProvider;
  final GeminiClient _client;

  AppConfig get _config => _configProvider();

  static const String _missingCredentials =
      'No API key was found. Open Settings and enter your Gemini API key, or '
      'set GEMINI_API_KEY in your environment.';

  @override
  bool get isAvailable => _config.hasApiKey;

  @override
  Future<ModelResponse> requestJson(
    ModelRequest request, {
    required List<String> models,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) async {
    final AppConfig config = _config;
    if (!config.hasApiKey) {
      throw const CorrectionException(_missingCredentials);
    }

    final List<String> chain =
        models.where((String model) => model.trim().isNotEmpty).toList();
    if (chain.isEmpty) {
      throw const CorrectionException('No model is configured.');
    }

    final Object input = _encode(request.parts);
    final List<String> tried = <String>[];
    bool everyFailureWasQuota = true;

    for (int index = 0; index < chain.length; index++) {
      cancel?.throwIfCancelled();
      final String model = chain[index];

      try {
        final InteractionOutcome outcome = await _client.sendWithRetries(
          apiKey: config.apiKey!,
          model: model,
          systemInstruction: request.systemInstruction,
          input: input,
          responseSchema: request.schema,
          maxTokens: request.maxTokens,
          effort: request.effort,
          onProgress: onProgress,
          retryingMessage: 'Retrying the ${request.purpose}…',
          // Waiting out a rate limit is only worth it on the last model.
          canSwitchModel: index < chain.length - 1,
          endpoint: config.apiEndpoint,
          idleTimeout: config.requestTimeout,
          maxRetries: config.retryCount,
          cancel: cancel,
        );

        final Object? payload = _client.decode(
          outcome,
          truncationHint: request.truncationHint,
          refusalMessage: request.refusalMessage,
        );
        return ModelResponse(payload: payload, model: model);
      } on CorrectionException catch (error) {
        if (!error.quotaExhausted && !error.transient) rethrow;

        tried.add(model);
        if (!error.quotaExhausted) everyFailureWasQuota = false;

        if (index == chain.length - 1) {
          if (chain.length == 1) rethrow;
          throw everyFailureWasQuota
              ? CorrectionException(
                  'The free-tier quota is used up for every configured model '
                  '(${tried.join(', ')}). Google resets the daily allowance at '
                  'midnight Pacific time. Add another model in Settings, or '
                  'raise the quota on your Google AI Studio plan.',
                  quotaExhausted: true,
                )
              : CorrectionException(
                  '${error.message} Every configured model was tried '
                  '(${tried.join(', ')}).',
                  quotaExhausted: error.quotaExhausted,
                );
        }

        onProgress?.call(
          error.quotaExhausted
              ? '$model has no quota left today — continuing the '
                  '${request.purpose} with ${chain[index + 1]}…'
              : '$model is unavailable — continuing the ${request.purpose} '
                  'with ${chain[index + 1]}…',
        );
      }
    }

    throw const CorrectionException('No model could serve the request.');
  }

  /// The Interactions API takes a plain string for text-only input and a list
  /// of typed parts once images are attached.
  Object _encode(List<ContentPart> parts) {
    if (parts.every((ContentPart part) => part is TextPart)) {
      return parts.map((ContentPart part) => (part as TextPart).text).join('\n\n');
    }
    return <Object>[
      for (final ContentPart part in parts)
        switch (part) {
          TextPart(:final String text) => <String, Object?>{
              'type': 'text',
              'text': text,
            },
          ImagePart(:final bytes, :final String mimeType) => <String, Object?>{
              'type': 'image',
              'mime_type': mimeType,
              'data': base64Encode(bytes),
            },
        },
    ];
  }
}
