import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/constants/app_constants.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/services/ai/correction_prompt.dart';
import 'package:exam_corrector/services/ai/correction_service.dart';
import 'package:exam_corrector/services/correction_validation_service.dart';

/// Google Gemini-backed implementation of [CorrectionService].
///
/// This is the only class that knows the model exists. It sends the correction
/// prompt, constrains the response to [CorrectionPrompt.responseSchema], and
/// hands the decoded payload to the validation service.
///
/// There is no official Gemini SDK for Dart, so this speaks the Interactions
/// REST API directly. The request is streamed because a full paper's correction
/// is a long response, and streaming avoids HTTP timeouts on large token
/// limits. Interactions are sent with `store: false` so exam papers are not
/// retained server-side.
class GeminiCorrectionService implements CorrectionService {
  GeminiCorrectionService(
    this._configProvider, {
    http.Client? client,
    CorrectionValidationService validator = const CorrectionValidationService(),
    List<Duration> retryDelays = _defaultRetryDelays,
  })  : _injectedClient = client,
        _validator = validator,
        _retryDelays = retryDelays;

  /// Providers throttle and models get busy; both clear on their own. Marking
  /// is a long, deliberate action, so a couple of quiet retries is far better
  /// than sending the teacher back to the button.
  static const List<Duration> _defaultRetryDelays = <Duration>[
    Duration(seconds: 3),
    Duration(seconds: 9),
  ];

  /// Beyond this the teacher is better served by an explanation than by a
  /// spinner, so the wait is reported rather than taken.
  static const Duration _maxRetryWait = Duration(seconds: 75);

  /// Read per request, so a key entered in Settings takes effect immediately
  /// rather than at the next launch.
  final AppConfig Function() _configProvider;
  final http.Client? _injectedClient;
  final CorrectionValidationService _validator;
  final List<Duration> _retryDelays;

  AppConfig get _config => _configProvider();

  static const String _missingCredentials =
      'No API key was found. Open Settings and enter your Gemini API key, or '
      'set GEMINI_API_KEY in your environment.';

  @override
  Future<CorrectionResult> correct({
    required String paperText,
    required String markSchemeText,
    CorrectionProgress? onProgress,
  }) async {
    if (paperText.trim().isEmpty) {
      throw const CorrectionException(
        'The exam paper contained no text to mark.',
      );
    }
    if (markSchemeText.trim().isEmpty) {
      throw const CorrectionException(
        'A mark scheme is required before correcting.',
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
        final _InteractionOutcome outcome = await _requestWithRetries(
          model: model,
          paperText: paperText,
          markSchemeText: markSchemeText,
          onProgress: onProgress,
          // Waiting out a rate limit is only worth it on the last model. While
          // another one is untried, switching is instant and its allowance is
          // separate.
          canSwitchModel: index < chain.length - 1,
        );

        final Object? payload = _decode(outcome);

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

  /// Sends the request, retrying the failures that pass on their own.
  Future<_InteractionOutcome> _requestWithRetries({
    required String model,
    required String paperText,
    required String markSchemeText,
    CorrectionProgress? onProgress,
    bool canSwitchModel = false,
  }) async {
    for (int attempt = 0;; attempt++) {
      try {
        if (attempt > 0) onProgress?.call('Retrying the correction…');
        return await _request(
          model: model,
          paperText: paperText,
          markSchemeText: markSchemeText,
        );
      } on CorrectionException catch (error) {
        // Out of retries, or nothing a retry could fix: the caller decides
        // whether another model is worth trying.
        if (!error.transient || attempt >= _retryDelays.length) rethrow;

        // A refused request with somewhere else to go should go there now
        // rather than make the teacher wait out a limit twice over.
        if (error.quotaExhausted && canSwitchModel) rethrow;

        // A rate limit comes with the exact wait the API wants; a fixed short
        // backoff would simply be refused again.
        final Duration wait = _waitFor(error, attempt);
        onProgress?.call(
          'The API is rate limited — waiting ${wait.inSeconds}s and trying '
          'again…',
        );
        await Future<void>.delayed(wait);
      }
    }
  }

  /// The API's own retry delay when it gave one, otherwise the schedule.
  ///
  /// A second of headroom is added so the retry clears the window rather than
  /// landing exactly on its edge.
  Duration _waitFor(CorrectionException error, int attempt) {
    final Duration scheduled = _retryDelays[attempt];
    final Duration? requested = error.retryAfter;
    if (requested == null) return scheduled;

    final Duration wait = requested + const Duration(seconds: 1);
    if (wait > _maxRetryWait) return _maxRetryWait;
    if (wait < scheduled) return scheduled;
    return wait;
  }

  Future<_InteractionOutcome> _request({
    required String model,
    required String paperText,
    required String markSchemeText,
  }) async {
    final http.Client client = _injectedClient ?? http.Client();

    try {
      final http.Request request = http.Request(
        'POST',
        Uri.parse('${AppConstants.apiEndpoint}?alt=sse'),
      );
      request.headers.addAll(<String, String>{
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        'x-goog-api-key': _config.apiKey!,
      });
      request.body = jsonEncode(<String, Object?>{
        'model': model,
        'stream': true,
        // Stateless: the paper and mark scheme are not kept by the service.
        'store': false,
        'system_instruction': CorrectionPrompt.systemPrompt,
        'input': CorrectionPrompt.buildUserPrompt(
          paperText: paperText,
          markSchemeText: markSchemeText,
        ),
        'generation_config': <String, Object?>{
          'max_output_tokens': _config.maxTokens,
          'thinking_level': _config.effort,
        },
        'response_format': <String, Object?>{
          'type': 'text',
          'mime_type': 'application/json',
          'schema': CorrectionPrompt.responseSchema,
        },
      });

      final http.StreamedResponse response = await client.send(request);

      if (response.statusCode != 200) {
        throw _errorForStatus(
          response.statusCode,
          await response.stream.bytesToString(),
          response.headers,
          model,
        );
      }

      return await _readStream(response.stream);
    } on CorrectionException {
      rethrow;
    } on TimeoutException {
      throw const CorrectionException(
        'The API stopped responding. Check your internet connection and try '
        'again.',
        transient: true,
      );
    } on SocketException {
      throw const CorrectionException(
        'Could not reach the API. Check your internet connection and try again.',
      );
    } on http.ClientException {
      throw const CorrectionException(
        'The connection to the API was lost before marking finished. Please '
        'try again.',
        transient: true,
      );
    } on FormatException {
      throw const CorrectionException(
        'The API sent a response this application could not read.',
      );
    } finally {
      if (_injectedClient == null) client.close();
    }
  }

  /// Consumes the server-sent event stream, keeping the model's answer text.
  ///
  /// Only `text` deltas are kept: thought summaries arrive on the same stream
  /// and must never reach the JSON parser.
  Future<_InteractionOutcome> _readStream(http.ByteStream body) async {
    final StringBuffer text = StringBuffer();
    String? status;
    String? incompleteReason;

    final Stream<String> lines = body
        .timeout(AppConstants.apiIdleTimeout)
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final String line in lines) {
      if (!line.startsWith('data:')) continue;

      final String data = line.substring(5).trim();
      if (data.isEmpty) continue;

      // The stream is terminated by the `[DONE]` sentinel, which is not JSON.
      if (data == '[DONE]') break;

      final Object? decoded;
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        // A keepalive or an unrecognised sentinel must not discard a
        // correction that has already arrived; the assembled text is
        // validated below regardless.
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;

      switch (decoded['event_type']) {
        case 'step.delta':
          final Object? delta = decoded['delta'];
          if (delta is Map<String, dynamic> && delta['type'] == 'text') {
            final Object? chunk = delta['text'];
            if (chunk is String) text.write(chunk);
          }
        case 'interaction.created':
        case 'interaction.completed':
          final Object? interaction = decoded['interaction'];
          if (interaction is Map<String, dynamic>) {
            final Object? reported = interaction['status'];
            if (reported is String) status = reported;
            final Object? details = interaction['incomplete_details'];
            if (details is Map<String, dynamic>) {
              final Object? reason = details['reason'];
              if (reason is String) incompleteReason = reason;
            }
          }
        case 'error':
          throw _errorForStreamedError(decoded['error']);
      }
    }

    return _InteractionOutcome(
      text: text.toString().trim(),
      status: status,
      incompleteReason: incompleteReason,
    );
  }

  Object? _decode(_InteractionOutcome outcome) {
    final String reason = outcome.incompleteReason?.toLowerCase() ?? '';

    if (reason.contains('token') || reason.contains('length')) {
      throw const CorrectionException(
        'The correction was cut short because it exceeded the output limit. '
        'Try marking fewer questions at once, or raise '
        'EXAM_CORRECTOR_MAX_TOKENS.',
      );
    }
    if (reason.contains('safety') ||
        reason.contains('block') ||
        reason.contains('refus') ||
        reason.contains('prohibited')) {
      throw const CorrectionException(
        'The AI declined to mark this paper. Please review the uploaded '
        'content.',
      );
    }
    if (outcome.status == 'failed') {
      throw const CorrectionException(
        'The API stopped the correction before it finished. Please try again.',
      );
    }

    if (outcome.text.isEmpty) {
      throw const CorrectionException('The AI returned an empty response.');
    }

    try {
      return jsonDecode(outcome.text);
    } on FormatException catch (error) {
      throw CorrectionException(
        'The AI response was not valid JSON: ${error.message}',
      );
    }
  }

  CorrectionException _errorForStatus(
    int statusCode,
    String body,
    Map<String, String> headers,
    String model,
  ) {
    final String detail = _messageFromErrorBody(body);
    final Duration? retryAfter = _retryAfterFrom(detail, headers);

    // An unusable key is reported as 400 INVALID_ARGUMENT as often as 401, so
    // the message decides rather than the status alone.
    if (statusCode == 400 && detail.toLowerCase().contains('api key')) {
      return const CorrectionException(
        'The API key was rejected. Check GEMINI_API_KEY and try again.',
      );
    }

    switch (statusCode) {
      case 401:
        return const CorrectionException(
          'The API key was rejected. Check GEMINI_API_KEY and try again.',
        );
      case 403:
        return CorrectionException(
          'This API key does not have access to the configured model '
          '($model).',
        );
      case 404:
        return CorrectionException(
          'The configured model ($model) was not found.',
        );
      case 413:
        return const CorrectionException(
          'The exam paper and mark scheme are too large to send in one '
          'request. Try marking a shorter paper.',
        );
      case 429:
        // Retried first (the window may be short), then treated as an empty
        // allowance so the chain moves to the next model.
        return CorrectionException(
          _rateLimitMessage(detail, retryAfter, model),
          transient: true,
          retryAfter: retryAfter,
          quotaExhausted: true,
        );
      case 503:
        return const CorrectionException(
          'The API is temporarily overloaded. Please try again in a moment.',
          transient: true,
        );
      case 504:
        return const CorrectionException(
          'The API took too long to mark this paper. Try marking a shorter '
          'paper, or try again in a moment.',
          transient: true,
        );
    }

    if (statusCode >= 500) {
      // The provider reports a busy model as a 500 whose body says so; that
      // reads very differently to a teacher than "something went wrong".
      final String lower = detail.toLowerCase();
      if (lower.contains('high demand') ||
          lower.contains('overloaded') ||
          lower.contains('try again later')) {
        return CorrectionException(
          'The $model model is busy right now. Please try again in '
          'a moment.',
          transient: true,
        );
      }
      return const CorrectionException(
        'The API had a temporary problem. Please try again in a moment.',
        transient: true,
      );
    }

    return CorrectionException('The API returned an error: $detail');
  }

  /// Explains a rate limit in terms the teacher can act on: which model ran out
  /// of quota, and how long until it is worth trying again.
  String _rateLimitMessage(String detail, Duration? retryAfter, String model) {
    final StringBuffer message = StringBuffer(
      detail.toLowerCase().contains('free_tier') ||
              detail.toLowerCase().contains('free tier')
          ? 'The free-tier quota for $model has run out.'
          : 'The API rate limit for $model was reached.',
    );

    if (retryAfter != null) {
      message.write(' Try again in about ${retryAfter.inSeconds} seconds.');
    } else {
      message.write(' Please wait a moment and try again.');
    }
    message.write(
      ' You can also choose a different model in Settings, or raise the quota '
      'on your Google AI Studio plan.',
    );

    return message.toString();
  }

  /// The API states the wait in the error text ("Please retry in 34.7s") and
  /// sometimes in a `retry-after` header. Either will do.
  Duration? _retryAfterFrom(String detail, Map<String, String> headers) {
    final String? header = headers['retry-after'];
    if (header != null) {
      final int? seconds = int.tryParse(header.trim());
      if (seconds != null && seconds > 0) return Duration(seconds: seconds);
    }

    final RegExpMatch? match =
        RegExp(r'retry in ([0-9]+(?:\.[0-9]+)?)s', caseSensitive: false)
            .firstMatch(detail);
    if (match != null) {
      final double? seconds = double.tryParse(match.group(1)!);
      // Rounded up, exactly as the API stated it — the extra second of
      // headroom belongs to the wait, not to what the teacher is told.
      if (seconds != null && seconds > 0) {
        return Duration(seconds: seconds.ceil());
      }
    }

    return null;
  }

  CorrectionException _errorForStreamedError(Object? error) {
    if (error is Map<String, dynamic>) {
      final Object? code = error['code'];
      if (code is String &&
          (code.contains('unavailable') || code.contains('overloaded'))) {
        return const CorrectionException(
          'The API is temporarily overloaded. Please try again in a moment.',
          transient: true,
        );
      }
      final Object? message = error['message'];
      if (message is String && message.isNotEmpty) {
        return CorrectionException('The API returned an error: $message');
      }
    }
    return const CorrectionException(
      'The API stopped the correction before it finished. Please try again.',
    );
  }

  String _messageFromErrorBody(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final Object? error = decoded['error'];
        if (error is Map<String, dynamic> && error['message'] is String) {
          return error['message'] as String;
        }
      }
    } on FormatException {
      // Fall through to the raw body below.
    }
    return body.isEmpty ? 'no details were provided' : body;
  }
}

/// What the streamed interaction amounted to: its text, and how it ended.
class _InteractionOutcome {
  const _InteractionOutcome({
    required this.text,
    required this.status,
    required this.incompleteReason,
  });

  final String text;
  final String? status;
  final String? incompleteReason;
}
