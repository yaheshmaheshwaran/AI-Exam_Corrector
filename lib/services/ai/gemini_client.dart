import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/constants/app_constants.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';

/// Which allowance a rate-limited request ran into.
enum QuotaWindow { perMinute, perDay, unknown }

/// What a streamed interaction amounted to: its text, and how it ended.
class InteractionOutcome {
  const InteractionOutcome({
    required this.text,
    required this.status,
    required this.incompleteReason,
  });

  final String text;
  final String? status;
  final String? incompleteReason;
}

/// Transport for the Gemini Interactions API.
///
/// Everything about *speaking to the provider* lives here — request framing,
/// the server-sent event stream, error translation, and the retry schedule —
/// and nothing about what is being asked. Marking and handwriting
/// cross-checking are very different jobs that share exactly this, so it is
/// factored out rather than written twice.
///
/// There is no official Gemini SDK for Dart, so this speaks REST directly.
/// Requests are streamed because a long response would otherwise risk an HTTP
/// timeout, and sent with `store: false` so exam papers are not retained
/// server-side.
class GeminiClient {
  GeminiClient({
    http.Client? client,
    List<Duration> retryDelays = defaultRetryDelays,
  })  : _injectedClient = client,
        _retryDelays = retryDelays;

  /// Providers throttle and models get busy; both clear on their own. Marking
  /// is a long, deliberate action, so a couple of quiet retries is far better
  /// than sending the teacher back to the button.
  static const List<Duration> defaultRetryDelays = <Duration>[
    Duration(seconds: 3),
    Duration(seconds: 9),
  ];

  /// Beyond this the teacher is better served by an explanation than by a
  /// spinner, so the wait is reported rather than taken.
  static const Duration maxRetryWait = Duration(seconds: 75);

  final http.Client? _injectedClient;
  final List<Duration> _retryDelays;

  /// Sends one interaction, retrying the failures that pass on their own.
  ///
  /// [canSwitchModel] tells the client that the caller has another model to
  /// try: a refused request with somewhere else to go should go there now
  /// rather than make the teacher wait out a limit twice over.
  Future<InteractionOutcome> sendWithRetries({
    required String apiKey,
    required String model,
    required String systemInstruction,
    required Object input,
    required Map<String, Object?> responseSchema,
    required int maxTokens,
    required String effort,
    void Function(String message)? onProgress,
    bool canSwitchModel = false,
    String retryingMessage = 'Retrying…',
    String endpoint = AppConstants.apiEndpoint,
    Duration idleTimeout = AppConstants.apiIdleTimeout,
    int? maxRetries,
    CancellationToken? cancel,
  }) async {
    final int retries = maxRetries ?? _retryDelays.length;
    for (int attempt = 0;; attempt++) {
      cancel?.throwIfCancelled();
      try {
        if (attempt > 0) onProgress?.call(retryingMessage);
        return await send(
          apiKey: apiKey,
          model: model,
          systemInstruction: systemInstruction,
          input: input,
          responseSchema: responseSchema,
          maxTokens: maxTokens,
          effort: effort,
          endpoint: endpoint,
          idleTimeout: idleTimeout,
          cancel: cancel,
        );
      } on CorrectionException catch (error) {
        if (!error.transient || attempt >= retries) rethrow;
        if (error.quotaExhausted && canSwitchModel) rethrow;

        // A rate limit comes with the exact wait the API wants; a fixed short
        // backoff would simply be refused again.
        final Duration wait = waitFor(error, attempt);
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
  Duration waitFor(CorrectionException error, int attempt) {
    final Duration scheduled = _retryDelays.isEmpty
        ? Duration.zero
        : _retryDelays[attempt.clamp(0, _retryDelays.length - 1)];
    final Duration? requested = error.retryAfter;
    if (requested == null) return scheduled;

    final Duration wait = requested + const Duration(seconds: 1);
    if (wait > maxRetryWait) return maxRetryWait;
    if (wait < scheduled) return scheduled;
    return wait;
  }

  /// Sends one interaction and returns what came back.
  ///
  /// [input] is the API's `input` field: a plain string for a text-only turn,
  /// or a structured list of content parts when images are attached.
  Future<InteractionOutcome> send({
    required String apiKey,
    required String model,
    required String systemInstruction,
    required Object input,
    required Map<String, Object?> responseSchema,
    required int maxTokens,
    required String effort,
    String endpoint = AppConstants.apiEndpoint,
    Duration idleTimeout = AppConstants.apiIdleTimeout,
    CancellationToken? cancel,
  }) async {
    final http.Client client = _injectedClient ?? http.Client();
    // Closing the client is the only way to abandon a streaming response.
    // An injected client is shared, so it is left alone and the stream is
    // abandoned at the next chunk instead.
    final void Function()? unregister = cancel?.onCancel(() {
      if (_injectedClient == null) client.close();
    });

    try {
      final http.Request request = http.Request(
        'POST',
        Uri.parse('$endpoint?alt=sse'),
      );
      request.headers.addAll(<String, String>{
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        'x-goog-api-key': apiKey,
      });
      request.body = jsonEncode(<String, Object?>{
        'model': model,
        'stream': true,
        // Stateless: exam papers are not kept by the service.
        'store': false,
        'system_instruction': systemInstruction,
        'input': input,
        'generation_config': <String, Object?>{
          'max_output_tokens': maxTokens,
          'thinking_level': effort,
        },
        'response_format': <String, Object?>{
          'type': 'text',
          'mime_type': 'application/json',
          'schema': responseSchema,
        },
      });

      final http.StreamedResponse response = await client.send(request);

      if (response.statusCode != 200) {
        throw errorForStatus(
          response.statusCode,
          await response.stream.bytesToString(),
          response.headers,
          model,
        );
      }

      return await readStream(
        response.stream,
        idleTimeout: idleTimeout,
        cancel: cancel,
      );
    } on CorrectionException {
      rethrow;
    } on CancelledException {
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
      // Closing the client is how cancellation abandons a request, and it
      // surfaces here as a dropped connection.
      if (cancel?.isCancelled ?? false) throw const CancelledException();
      throw const CorrectionException(
        'The connection to the API was lost before it finished. Please try '
        'again.',
        transient: true,
      );
    } on FormatException {
      throw const CorrectionException(
        'The API sent a response this application could not read.',
      );
    } finally {
      unregister?.call();
      if (_injectedClient == null) client.close();
    }
  }

  /// Consumes the server-sent event stream, keeping the model's answer text.
  ///
  /// Only `text` deltas are kept: thought summaries arrive on the same stream
  /// and must never reach the JSON parser.
  Future<InteractionOutcome> readStream(
    http.ByteStream body, {
    Duration idleTimeout = AppConstants.apiIdleTimeout,
    CancellationToken? cancel,
  }) async {
    final StringBuffer text = StringBuffer();
    String? status;
    String? incompleteReason;

    final Stream<String> lines = body
        .timeout(idleTimeout)
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final String line in lines) {
      cancel?.throwIfCancelled();
      if (!line.startsWith('data:')) continue;

      final String data = line.substring(5).trim();
      if (data.isEmpty) continue;

      // The stream is terminated by the `[DONE]` sentinel, which is not JSON.
      if (data == '[DONE]') break;

      final Object? decoded;
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        // A keepalive or an unrecognised sentinel must not discard a response
        // that has already arrived; the assembled text is validated regardless.
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
          throw errorForStreamedError(decoded['error']);
      }
    }

    return InteractionOutcome(
      text: text.toString().trim(),
      status: status,
      incompleteReason: incompleteReason,
    );
  }

  /// Turns a finished interaction into decoded JSON, or explains why not.
  ///
  /// [truncationHint] names the setting the caller would raise, since the
  /// remedy differs: a long correction needs more output tokens, a batch of
  /// line crops needs fewer images per request.
  Object? decode(
    InteractionOutcome outcome, {
    required String truncationHint,
    required String refusalMessage,
  }) {
    final String reason = outcome.incompleteReason?.toLowerCase() ?? '';

    if (reason.contains('token') || reason.contains('length')) {
      throw CorrectionException(truncationHint);
    }
    if (reason.contains('safety') ||
        reason.contains('block') ||
        reason.contains('refus') ||
        reason.contains('prohibited')) {
      throw CorrectionException(refusalMessage);
    }
    if (outcome.status == 'failed') {
      throw const CorrectionException(
        'The API stopped before it finished. Please try again.',
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

  CorrectionException errorForStatus(
    int statusCode,
    String body,
    Map<String, String> headers,
    String model,
  ) {
    final String detail = messageFromErrorBody(body);
    final Duration? retryAfter = retryAfterFrom(detail, headers);

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
          'The request was too large to send in one piece. Try marking a '
          'shorter paper.',
        );
      case 429:
        // A per-minute limit clears by itself: wait and retry the same model,
        // rather than burning through the chain because several requests
        // arrived at once. A daily allowance does not come back today, so the
        // caller moves to the next model. When the API does not say which it
        // is, retry briefly, then move on.
        final QuotaWindow window = quotaWindow(body);
        return CorrectionException(
          rateLimitMessage(detail, retryAfter, model, window: window),
          transient: true,
          retryAfter: retryAfter,
          quotaExhausted: window != QuotaWindow.perMinute,
        );
      case 503:
        return const CorrectionException(
          'The API is temporarily overloaded. Please try again in a moment.',
          transient: true,
        );
      case 504:
        return const CorrectionException(
          'The API took too long. Try a shorter paper, or try again in a '
          'moment.',
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
          'The $model model is busy right now. Please try again in a moment.',
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

  /// Which quota a 429 hit, from the `quotaId` of each violation Gemini
  /// reports (`GenerateRequestsPerMinutePerProjectPerModel-FreeTier`, …).
  static QuotaWindow quotaWindow(String body) {
    final Iterable<String> ids = RegExp(r'"quotaId"\s*:\s*"([^"]+)"')
        .allMatches(body)
        .map((RegExpMatch match) => match.group(1)!);
    if (ids.any((String id) => id.contains('PerDay'))) return QuotaWindow.perDay;
    if (ids.any((String id) => id.contains('PerMinute'))) return QuotaWindow.perMinute;
    return QuotaWindow.unknown;
  }

  /// Explains a rate limit in terms the teacher can act on: which model ran out
  /// of quota, and how long until it is worth trying again.
  String rateLimitMessage(
    String detail,
    Duration? retryAfter,
    String model, {
    QuotaWindow window = QuotaWindow.unknown,
  }) {
    final bool freeTier = detail.toLowerCase().contains('free_tier') ||
        detail.toLowerCase().contains('free tier');
    final StringBuffer message = StringBuffer(switch (window) {
      QuotaWindow.perMinute =>
        'Too many requests reached $model at once (its per-minute limit).',
      QuotaWindow.perDay => 'The daily ${freeTier ? 'free-tier ' : ''}quota for '
          '$model has run out.',
      QuotaWindow.unknown => freeTier
          ? 'The free-tier quota for $model has run out.'
          : 'The API rate limit for $model was reached.',
    });

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
  Duration? retryAfterFrom(String detail, Map<String, String> headers) {
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

  CorrectionException errorForStreamedError(Object? error) {
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
      'The API stopped before it finished. Please try again.',
    );
  }

  String messageFromErrorBody(String body) {
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
