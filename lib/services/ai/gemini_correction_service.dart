import 'package:http/http.dart' as http;

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/services/ai/correction_prompt.dart';
import 'package:exam_corrector/services/ai/correction_service.dart';
import 'package:exam_corrector/services/ai/gemini_client.dart';
import 'package:exam_corrector/services/correction_validation_service.dart';

/// Google Gemini-backed implementation of [CorrectionService].
///
/// Owns the *marking* decisions: which prompt is sent, how the response is
/// validated, and how the model chain is walked as each model's daily quota
/// runs out. Speaking to the provider is [GeminiClient]'s job.
class GeminiCorrectionService implements CorrectionService {
  GeminiCorrectionService(
    this._configProvider, {
    http.Client? client,
    GeminiClient? geminiClient,
    CorrectionValidationService validator = const CorrectionValidationService(),
    List<Duration> retryDelays = GeminiClient.defaultRetryDelays,
  })  : _client = geminiClient ??
            GeminiClient(client: client, retryDelays: retryDelays),
        _validator = validator;

  /// Read per request, so a key entered in Settings takes effect immediately
  /// rather than at the next launch.
  final AppConfig Function() _configProvider;
  final GeminiClient _client;
  final CorrectionValidationService _validator;

  AppConfig get _config => _configProvider();

  static const String _missingCredentials =
      'No API key was found. Open Settings and enter your Gemini API key, or '
      'set GEMINI_API_KEY in your environment.';

  @override
  Future<CorrectionResult> correct({
    required String questionPaperText,
    required String answerSheetText,
    String guidanceText = '',
    CorrectionProgress? onProgress,
    bool fromHandwriting = false,
  }) async {
    if (answerSheetText.trim().isEmpty) {
      throw const CorrectionException(
        'The answer sheet contained no text to mark.',
      );
    }
    if (questionPaperText.trim().isEmpty) {
      throw const CorrectionException(
        'The question paper contained no text. It is what establishes the '
        'questions and their marks, so marking cannot proceed without it.',
      );
    }
    if (!_config.hasApiKey) {
      throw const CorrectionException(_missingCredentials);
    }

    // Each model has its own daily allowance, so an exhausted one is a reason
    // to move down the chain rather than to give up on the paper.
    final List<String> chain = _config.modelChain;
    final List<String> tried = <String>[];
    bool everyFailureWasQuota = true;

    for (int index = 0; index < chain.length; index++) {
      final String model = chain[index];

      try {
        final InteractionOutcome outcome = await _client.sendWithRetries(
          apiKey: _config.apiKey!,
          model: model,
          systemInstruction: CorrectionPrompt.systemPromptFor(
            hasGuidance: guidanceText.trim().isNotEmpty,
            fromHandwriting: fromHandwriting,
          ),
          input: CorrectionPrompt.buildUserPrompt(
            questionPaperText: questionPaperText,
            answerSheetText: answerSheetText,
            guidanceText: guidanceText,
          ),
          responseSchema: CorrectionPrompt.responseSchema,
          maxTokens: _config.maxTokens,
          effort: _config.effort,
          onProgress: onProgress,
          retryingMessage: 'Retrying the correction…',
          // Waiting out a rate limit is only worth it on the last model. While
          // another one is untried, switching is instant and its allowance is
          // separate.
          canSwitchModel: index < chain.length - 1,
        );

        final Object? payload = _client.decode(
          outcome,
          truncationHint:
              'The correction was cut short because it exceeded the output '
              'limit. Try marking fewer questions at once, or raise '
              'EXAM_CORRECTOR_MAX_TOKENS.',
          refusalMessage:
              'The AI declined to mark this paper. Please review the uploaded '
              'content.',
        );

        try {
          return _validator.validate(payload, model: model);
        } on ResultValidationException catch (error) {
          throw CorrectionException(
            'The AI returned a result that failed validation: ${error.message}',
          );
        }
      } on CorrectionException catch (error) {
        // A refusal that survived its retries is worth trying elsewhere: the
        // allowance is gone, or the model is busy. A rejected key or a
        // malformed response would fail identically on every other model.
        if (!error.quotaExhausted && !error.transient) rethrow;

        tried.add(model);
        if (!error.quotaExhausted) everyFailureWasQuota = false;

        if (index == chain.length - 1) {
          // With a single model configured, its own message already names the
          // model, the wait and what to do — better than a summary of one.
          if (chain.length == 1) rethrow;

          throw everyFailureWasQuota
              ? _allModelsExhausted(tried)
              : CorrectionException(
                  '${error.message} Every configured model was tried '
                  '(${tried.join(', ')}).',
                  quotaExhausted: error.quotaExhausted,
                );
        }

        onProgress?.call(
          error.quotaExhausted
              ? '$model has no quota left today — marking with '
                  '${chain[index + 1]}…'
              : '$model is unavailable — marking with ${chain[index + 1]}…',
        );
      }
    }

    // Unreachable: the loop above either returns or throws.
    throw _allModelsExhausted(tried);
  }

  CorrectionException _allModelsExhausted(List<String> tried) {
    return CorrectionException(
      'The free-tier quota is used up for every configured model '
      '(${tried.join(', ')}). Google resets the daily allowance at midnight '
      'Pacific time. Add another model in Settings, or raise the quota on your '
      'Google AI Studio plan.',
      quotaExhausted: true,
    );
  }
}
