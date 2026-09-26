import 'dart:convert';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/ai/gemini_client.dart';
import 'package:exam_corrector/services/ai/model_client.dart';
import 'package:exam_corrector/services/ai/model_usage.dart';

/// [ModelClient] for Google Gemini, over the Interactions API.
///
/// Owns the model chain: each model has its own daily allowance, so an
/// exhausted or busy model is a reason to move down the list rather than to
/// give up. A rejected key or a malformed request fails immediately, because
/// no other model would do better.
class GeminiModelClient implements ModelClient {
  GeminiModelClient(this._configProvider, {GeminiClient? client, this.usage})
      : _client = client ?? GeminiClient();

  final AppConfig Function() _configProvider;
  final GeminiClient _client;

  /// Counts every request and remembers each model's limits, for the teacher
  /// to see; a model it knows is out of quota for the day is not asked.
  final ModelUsageMonitor? usage;

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

    final List<String> configured =
        models.where((String model) => model.trim().isNotEmpty).toList();
    if (configured.isEmpty) {
      throw const CorrectionException('No model is configured.');
    }

    // A model already out of quota today would only refuse again.
    final ModelUsageMonitor? usage = this.usage;
    final List<String> chain = <String>[
      for (final String model in configured)
        if (usage == null || !usage.isExhausted(model)) model,
    ];
    if (chain.isEmpty) {
      final DateTime reset = configured
          .map((String model) => usage!.exhaustedUntil(model)!)
          .reduce((DateTime a, DateTime b) => a.isBefore(b) ? a : b);
      throw CorrectionException(
        'Every configured model (${configured.join(', ')}) is out of quota. '
        'It comes back at ${_clock(reset)} — or add another model in Settings.',
        quotaExhausted: true,
        dailyQuota: true,
      );
    }

    final Object input = _encode(request.parts);
    final List<String> tried = <String>[];
    bool everyFailureWasQuota = true;
    final ModelCall? call = usage?.started(chain.first, request.purpose);

    try {
      for (int index = 0; index < chain.length; index++) {
        cancel?.throwIfCancelled();
        final String model = chain[index];
        if (call != null && index > 0) usage!.switchedModel(call, model);

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
            onAttempt: call == null ? null : () => usage!.attempted(call),
            onWait: call == null
                ? null
                : (Duration wait, CorrectionException reason) => usage!.waiting(call, wait, reason),
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
          if (call != null) usage!.succeeded(call);
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
                    dailyQuota: error.dailyQuota,
                  )
                : CorrectionException(
                    '${error.message} Every configured model was tried '
                    '(${tried.join(', ')}).',
                    quotaExhausted: error.quotaExhausted,
                    dailyQuota: error.dailyQuota,
                  );
          }

          if (call != null) usage!.modelFailed(call, model, error);
          onProgress?.call(
            error.quotaExhausted
                ? '$model has no quota left today — continuing the '
                    '${request.purpose} with ${chain[index + 1]}…'
                : '$model is unavailable — continuing the ${request.purpose} '
                    'with ${chain[index + 1]}…',
          );
        }
      }
    } on AppException catch (error) {
      if (call != null) usage!.failed(call, error);
      rethrow;
    }

    throw const CorrectionException('No model could serve the request.');
  }

  static String _clock(DateTime time) {
    final DateTime local = time.toLocal();
    final int hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    return '$hour:${local.minute.toString().padLeft(2, '0')} ${local.hour < 12 ? 'AM' : 'PM'}';
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
