import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/model_request.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/provider_health.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';

/// Which allowance a 429 used up.
enum QuotaWindow { perMinute, perDay, unknown }

/// The one client for every model: Gemini, NVIDIA, a GPU server, Ollama.
///
/// They all speak the OpenAI chat-completions API, so one request shape
/// serves them — a system message, a user message of text and base64 images,
/// and a JSON Schema for the answer. Which server a model goes to is decided
/// by its name's prefix (`gemini/…`, `nvidia/…`, `server/…`, `ollama/…`).
///
/// A failure another model could survive — a spent allowance, a server not
/// running or hanging, a missing key — moves down the list of models; a
/// failure no model would survive stops.
class LlmClient implements ModelClient {
  LlmClient(
    this._settings, {
    http.Client? client,
    this.usage,
    this.health,
    List<Duration> retryDelays = defaultRetryDelays,
    this.maxRetryWait = const Duration(seconds: 75),
    DateTime Function()? clock,
  })  : _injectedClient = client,
        _retryDelays = retryDelays,
        _now = clock ?? DateTime.now;

  static const List<Duration> defaultRetryDelays = <Duration>[Duration(seconds: 3), Duration(seconds: 9)];

  final AiSettings Function() _settings;
  final http.Client? _injectedClient;
  final List<Duration> _retryDelays;
  final UsageMonitor? usage;

  /// Which of our own servers are unreachable, so a dead one is skipped while
  /// another model can answer.
  final ProviderHealth? health;

  /// The longest a rate limit is waited out before trying the same model.
  final Duration maxRetryWait;

  /// Retries for a per-minute limit — one the provider said when to retry.
  /// It clears by itself, so it is waited out more patiently than an error:
  /// several requests in flight at once can meet it a few times in a row.
  static const int rateLimitRetries = 6;

  /// How long a hosted provider that hung is left alone. Its free endpoints
  /// can accept a request and answer nothing for minutes; asking again on the
  /// next request would wait as long again.
  static const Duration hungRest = Duration(minutes: 10);

  final DateTime Function() _now;
  final Map<String, DateTime> _restingUntil = <String, DateTime>{};

  /// Whether the provider of [model] hung recently and is being left alone.
  bool isResting(String model) {
    final ModelProvider? provider = _settings().providers.of(model);
    final DateTime? until = provider == null ? null : _restingUntil[provider.id];
    return until != null && _now().isBefore(until);
  }

  @override
  bool get isAvailable => _settings().hasModelAccess;

  /// Sends [request] to the models that do [role], first choice first.
  Future<ModelResponse> requestRole(
    ModelRole role,
    ModelRequest request, {
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) =>
      requestJson(request, models: _settings().roles.chain(role), onProgress: onProgress, cancel: cancel);

  @override
  Future<ModelResponse> requestJson(
    ModelRequest request, {
    required List<String> models,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) async {
    final AiSettings settings = _settings();
    final List<String> configured =
        models.map((String model) => model.trim()).where((String model) => model.isNotEmpty).toList();
    if (configured.isEmpty) throw const CorrectionException('No model is configured.');

    final UsageMonitor? usage = this.usage;
    final List<String> withQuota = <String>[
      for (final String model in configured)
        if (usage == null || !usage.isExhausted(model)) model,
    ];
    if (withQuota.isEmpty) {
      throw CorrectionException(
        'Every model for the ${request.purpose} (${configured.join(', ')}) is out of its allowance for now.',
        quotaExhausted: true,
      );
    }
    // A server known to be down is not asked while another model can answer;
    // if every one is down, all are tried anyway — one may be back.
    final List<String> reachable = <String>[
      for (final String model in withQuota)
        if (!_knownDown(settings, model) && !isResting(model)) model,
    ];
    final List<String> chain = reachable.isEmpty ? withQuota : reachable;

    final ModelCall? call = usage?.started(chain.first, request.purpose);
    // A skipped server is named too: when nothing answers, the teacher needs
    // to know it is down as much as why the rest failed.
    final List<String> reasons = <String>[
      for (final String model in withQuota)
        if (!chain.contains(model)) _downReason(settings, model),
    ];
    try {
      for (int index = 0; index < chain.length; index++) {
        cancel?.throwIfCancelled();
        final String model = chain[index];
        if (call != null && index > 0) usage!.switchedModel(call, model);
        final bool last = index == chain.length - 1;

        try {
          final ModelProvider provider = _providerOrThrow(settings, model);
          final Object? payload = await _requestWithRetries(
            settings,
            provider,
            model,
            request,
            call: call,
            canSwitchModel: !last,
            onProgress: onProgress,
            cancel: cancel,
          );
          if (call != null) usage!.succeeded(call);
          if (provider.selfHosted) health?.markUp(provider.id);
          return ModelResponse(payload: payload, model: model);
        } on CorrectionException catch (error) {
          if (!error.quotaExhausted && !error.transient && !error.modelUnavailable) rethrow;
          final ModelProvider? failed = settings.providers.of(model);
          if (failed != null && _serverGone(failed, error)) health?.markDown(failed.id, _short(error.message));
          if (failed != null && !failed.selfHosted && _hung(error)) _restingUntil[failed.id] = _now().add(hungRest);
          reasons.add('${failed?.label ?? model} ($model): ${_short(error.message)}.');
          if (last) {
            if (reasons.length == 1) rethrow;
            // Every reason, not only the last: the first model's failure is
            // usually the one the teacher needs to fix.
            throw CorrectionException(
              'No model could do the ${request.purpose}. ${reasons.join(' ')}',
              quotaExhausted: error.quotaExhausted,
              modelUnavailable: error.modelUnavailable,
              unreachable: error.unreachable,
            );
          }
          if (call != null) usage!.modelFailed(call, model, error);
          onProgress?.call('$model could not be used (${_short(error.message)}) — continuing the '
              '${request.purpose} with ${chain[index + 1]}…');
        }
      }
    } on AppException catch (error) {
      if (call != null) usage!.failed(call, error);
      rethrow;
    }
    throw const CorrectionException('No model could serve the request.');
  }

  /// Whether [error] means [provider] should be skipped for a while: it is
  /// unreachable, or one of our servers still failing after its retries (vLLM
  /// stopped behind a live tunnel answers 502 to everything). Ollama is never
  /// skipped for this — it is the last resort, and a busy one recovers.
  static bool _serverGone(ModelProvider provider, CorrectionException error) =>
      provider.selfHosted &&
      (error.unreachable || (error.transient && !error.quotaExhausted && provider.id != Providers.ollama));

  /// A hosted provider that accepted the request and never answered.
  static bool _hung(CorrectionException error) =>
      error.modelUnavailable && (error.message.contains('did not start answering') || error.message.contains('took longer than'));

  String _downReason(AiSettings settings, String model) {
    final ModelProvider? provider = settings.providers.of(model);
    if (isResting(model)) return '${provider?.label ?? model}: did not answer a few minutes ago (skipped for now).';
    final String reason = provider == null ? '' : health?.statusOf(provider.id).reason ?? '';
    return '${provider?.label ?? model}: ${reason.isEmpty ? 'not reachable' : _short(reason)} (skipped).';
  }

  bool _knownDown(AiSettings settings, String model) {
    final ModelProvider? provider = settings.providers.of(model);
    return provider != null && provider.selfHosted && (health?.isDown(provider.id) ?? false);
  }

  /// [message] without a trailing full stop, for joining reasons together.
  static String _short(String message) {
    final String m = message.trim();
    return m.endsWith('.') ? m.substring(0, m.length - 1) : m;
  }

  static ModelProvider _providerOrThrow(AiSettings settings, String model) {
    final ModelProvider? provider = settings.providers.of(model);
    if (provider == null) {
      throw CorrectionException(
        '"$model" does not say where it runs. Start its name with '
        '${settings.providers.all.map((ModelProvider p) => '${p.id}/').join(', ')}',
        modelUnavailable: true,
      );
    }
    if (!provider.isConfigured) {
      throw CorrectionException(
        provider.needsKey && (provider.apiKey?.isEmpty ?? true)
            ? '$model needs a ${provider.label} key (${provider.keyName}). Add it in Settings'
            : '$model needs the address of the ${provider.label} (${provider.addressName}). Add it in Settings',
        modelUnavailable: true,
      );
    }
    return provider;
  }

  /// One model's answer, retrying what passes on its own, and once more when
  /// the answer is not the JSON asked for — models slip now and then, and a
  /// second attempt nearly always holds.
  Future<Object?> _requestWithRetries(
    AiSettings settings,
    ModelProvider provider,
    String model,
    ModelRequest request, {
    required ModelCall? call,
    required bool canSwitchModel,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) async {
    bool retriedMalformed = false;
    int failures = 0;
    int rateLimits = 0;
    for (int attempt = 0;; attempt++) {
      cancel?.throwIfCancelled();
      if (attempt > 0) onProgress?.call('Retrying the ${request.purpose}…');
      if (call != null) usage!.attempted(call);
      final String text;
      try {
        text = await _send(provider, model, request, cancel: cancel);
      } on CorrectionException catch (error) {
        if (!error.transient) rethrow;
        if (error.quotaExhausted && canSwitchModel) rethrow;
        final bool rateLimited = error.retryAfter != null && !error.quotaExhausted;
        if (rateLimited ? ++rateLimits > rateLimitRetries : ++failures > settings.retries) rethrow;
        final Duration wait = waitFor(error, rateLimited ? rateLimits - 1 : failures - 1);
        if (call != null) usage!.waiting(call, wait, error);
        onProgress?.call('$model is busy or rate limited — waiting ${wait.inSeconds}s and trying again…');
        await Future<void>.delayed(wait);
        continue;
      }

      try {
        return decodeJson(text);
      } on FormatException catch (error) {
        if (retriedMalformed) throw CorrectionException('The AI response was not valid JSON: ${error.message}');
        retriedMalformed = true;
        onProgress?.call('$model answered in the wrong shape — asking again…');
      }
    }
  }

  /// The provider's own retry delay when it gave one, otherwise the schedule.
  /// A second of headroom is added so the retry clears the window rather than
  /// landing exactly on its edge.
  Duration waitFor(CorrectionException error, int attempt) {
    final Duration scheduled =
        _retryDelays.isEmpty ? Duration.zero : _retryDelays[attempt.clamp(0, _retryDelays.length - 1)];
    final Duration? requested = error.retryAfter;
    if (requested == null) return scheduled;
    final Duration wait = requested + const Duration(seconds: 1);
    if (wait > maxRetryWait) return maxRetryWait;
    if (wait < scheduled) return scheduled;
    return wait;
  }

  /// Sends one request and returns the answer text, within the provider's
  /// time limit for a whole answer.
  Future<String> _send(ModelProvider provider, String model, ModelRequest request, {CancellationToken? cancel}) async {
    final http.Client client = _injectedClient ?? http.Client();
    final void Function()? unregister = cancel?.onCancel(() {
      if (_injectedClient == null) client.close();
    });
    try {
      return await _sendOnce(client, provider, model, request, cancel: cancel).timeout(provider.totalTimeout);
    } on TimeoutException {
      // The whole answer took too long: a server that hangs is left for the
      // next model rather than retried — it would most likely hang again.
      throw CorrectionException(
        '${provider.label} took longer than ${_minutes(provider.totalTimeout)} to answer',
        modelUnavailable: true,
        unreachable: provider.selfHosted,
      );
    } finally {
      unregister?.call();
      if (_injectedClient == null) client.close();
    }
  }

  static String _minutes(Duration duration) =>
      duration.inMinutes >= 1 ? '${duration.inMinutes} min' : '${duration.inSeconds} s';

  Future<String> _sendOnce(
    http.Client client,
    ModelProvider provider,
    String model,
    ModelRequest request, {
    CancellationToken? cancel,
  }) async {
    try {
      final http.Request post = http.Request('POST', Uri.parse('${provider.baseUrl}/chat/completions'));
      post.headers.addAll(<String, String>{
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        if (provider.apiKey?.isNotEmpty ?? false) 'authorization': 'Bearer ${provider.apiKey}',
      });
      post.body = jsonEncode(requestBody(provider, model, request));

      final http.StreamedResponse response;
      try {
        response = await client.send(post).timeout(provider.headerTimeout);
      } on TimeoutException {
        throw CorrectionException(
          '${provider.label} did not start answering within ${_minutes(provider.headerTimeout)}',
          modelUnavailable: true,
          unreachable: provider.selfHosted,
        );
      }
      if (response.statusCode != 200) {
        throw errorForStatus(
            response.statusCode, await response.stream.bytesToString(), response.headers, provider, model);
      }

      final ({String text, String? finishReason}) answer =
          await readStream(response.stream, idleTimeout: provider.idleTimeout, cancel: cancel);
      switch (answer.finishReason) {
        case 'length':
        case 'max_tokens':
          throw CorrectionException(request.truncationHint, truncated: true);
        case 'content_filter':
        case 'safety':
          throw CorrectionException(request.refusalMessage);
      }
      if (answer.text.trim().isEmpty) {
        throw const CorrectionException('The AI returned an empty response.', transient: true);
      }
      return answer.text;
    } on CorrectionException {
      rethrow;
    } on CancelledException {
      rethrow;
    } on TimeoutException {
      throw CorrectionException(
        '$model stopped responding mid-answer. '
        '${provider.selfHosted ? 'The model server may be overloaded.' : 'Check your internet connection.'}',
        transient: true,
      );
    } on SocketException {
      // A server that is not running is a reason to try the next model, not
      // to wait: it will not start by itself.
      throw CorrectionException(
        provider.id == Providers.ollama
            ? 'Ollama is not running on this computer. Open the Ollama app, or run "ollama serve"'
            : 'Could not reach ${provider.label} at ${provider.baseUrl}',
        modelUnavailable: true,
        unreachable: true,
      );
    } on http.ClientException {
      if (cancel?.isCancelled ?? false) throw const CancelledException();
      throw CorrectionException('The connection to ${provider.label} was lost before it finished.', transient: true);
    }
  }

  /// The chat-completions request for [request].
  ///
  /// The schema is also written into the instruction: every server enforces
  /// `response_format` a little differently, and a model that has read the
  /// schema follows it even where the server does not.
  static Map<String, Object?> requestBody(ModelProvider provider, String model, ModelRequest request) {
    final String system = instruction(request);
    final int? cap = request.answerCap;
    final int maxTokens = request.maxTokens.clamp(1, provider.maxAnswerTokens);
    return <String, Object?>{
      'model': provider.modelId(model),
      'stream': true,
      // Marking and reading should give the same answer twice.
      'temperature': 0,
      'max_tokens': cap == null ? maxTokens : cap.clamp(1, maxTokens),
      if (provider.sendsEffort) 'reasoning_effort': request.effort,
      'messages': <Object?>[
        if (system.isNotEmpty) <String, Object?>{'role': 'system', 'content': system},
        <String, Object?>{
          'role': 'user',
          'content': <Object?>[
            for (final ContentPart part in request.parts)
              switch (part) {
                TextPart(:final String text) => <String, Object?>{'type': 'text', 'text': text},
                ImagePart(:final bytes, :final String mimeType) => <String, Object?>{
                    'type': 'image_url',
                    'image_url': <String, Object?>{'url': 'data:$mimeType;base64,${base64Encode(bytes)}'},
                  },
              },
          ],
        },
      ],
      if (request.enforceSchema)
        'response_format': provider.jsonSchema
            ? <String, Object?>{
                'type': 'json_schema',
                'json_schema': <String, Object?>{'name': 'answer', 'schema': request.schema},
              }
            : <String, Object?>{'type': 'json_object'},
    };
  }

  /// The system message: the instruction, and — when the answer is held to
  /// the schema — the schema itself.
  static String instruction(ModelRequest request) {
    if (!request.enforceSchema) return request.systemInstruction;
    return '${request.systemInstruction}\n\n'
        'Answer with one JSON object and nothing else — no prose, no code fence. '
        'It must satisfy this JSON Schema:\n${jsonEncode(request.schema)}';
  }

  /// Reads the server-sent event stream, keeping only the answer: reasoning
  /// arrives on its own field and never reaches the parser, though it does
  /// keep the stream from counting as silent.
  static Future<({String text, String? finishReason})> readStream(
    Stream<List<int>> body, {
    required Duration idleTimeout,
    CancellationToken? cancel,
  }) async {
    final StringBuffer text = StringBuffer();
    String? finishReason;
    final Stream<String> lines = body.timeout(idleTimeout).transform(utf8.decoder).transform(const LineSplitter());

    await for (final String line in lines) {
      cancel?.throwIfCancelled();
      if (!line.startsWith('data:')) continue;
      final String data = line.substring(5).trim();
      if (data.isEmpty) continue;
      if (data == '[DONE]') break;

      final Object? decoded;
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;
      if (decoded['error'] case final Object error) {
        throw CorrectionException('The model server returned an error: ${_messageOf(error)}', transient: true);
      }
      final Object? choices = decoded['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map<String, dynamic>) continue;
      final Map<String, dynamic> choice = choices.first as Map<String, dynamic>;
      final Object? delta = choice['delta'];
      if (delta is Map<String, dynamic> && delta['content'] is String) text.write(delta['content'] as String);
      if (choice['finish_reason'] case final String reason) finishReason = reason;
    }
    return (text: text.toString(), finishReason: finishReason);
  }

  /// The JSON in [text]. Reasoning models may put `<think>…</think>` before
  /// the answer, some wrap it in a code fence despite being asked not to, and
  /// one asked only for "a JSON object" may say a word before it.
  static Object? decodeJson(String text) {
    String answer = text.trim();
    final int thought = answer.lastIndexOf('</think>');
    if (thought >= 0) answer = answer.substring(thought + '</think>'.length).trim();
    final RegExpMatch? fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(answer);
    if (fence != null) answer = fence.group(1)!;
    try {
      return jsonDecode(answer);
    } on FormatException {
      final int object = answer.indexOf('{');
      final int list = answer.indexOf('[');
      final int start = object < 0 ? list : (list < 0 ? object : (object < list ? object : list));
      final int end = answer.lastIndexOf(start >= 0 && answer[start] == '{' ? '}' : ']');
      if (start < 0 || end <= start) rethrow;
      return jsonDecode(answer.substring(start, end + 1));
    }
  }

  static CorrectionException errorForStatus(
    int status,
    String body,
    Map<String, String> headers,
    ModelProvider provider,
    String model,
  ) {
    final String detail = messageFromErrorBody(body);
    final String lower = detail.toLowerCase();

    // An unusable key is reported as 400 INVALID_ARGUMENT as often as 401.
    if (status == 401 || status == 403 || (status == 400 && lower.contains('api key'))) {
      return CorrectionException(
        '${provider.label} rejected the key for $model. Check ${provider.keyName ?? 'it'} in Settings',
        modelUnavailable: true,
      );
    }
    switch (status) {
      case 404:
        return CorrectionException(
          provider.id == Providers.ollama
              ? '$model is not installed. Run "ollama pull ${provider.modelId(model)}" first'
              : '${provider.label} does not serve $model',
          modelUnavailable: true,
        );
      case 413:
        return const CorrectionException(
          'The request was too large to send at once. Fewer pages or questions per request will fit.',
          truncated: true,
        );
      case 402:
      case 429:
        final Duration? retryAfter = retryAfterFrom(detail, headers);
        // Our own servers have no allowance: a 429 there means busy.
        if (provider.selfHosted) {
          return CorrectionException('${provider.label} is busy.', transient: true, retryAfter: retryAfter);
        }
        // A per-minute limit clears by itself: wait and retry the same model.
        // A daily allowance does not come back today, so the next model is
        // asked. When the provider does not say which, retry briefly, then
        // move on.
        final QuotaWindow window = quotaWindow(body);
        return CorrectionException(
          rateLimitMessage(provider, model, retryAfter, window: window, freeTier: lower.contains('free')),
          transient: true,
          retryAfter: retryAfter,
          quotaExhausted: window != QuotaWindow.perMinute,
          dailyQuota: window == QuotaWindow.perDay,
          quotaLimit: window == QuotaWindow.perMinute ? null : quotaLimitFrom(body),
        );
      case 400:
        if (lower.contains('context') || lower.contains('too long') || lower.contains('token limit')) {
          return const CorrectionException(
            'The request is longer than the model can read at once. Fewer pages or questions per request will fit.',
            truncated: true,
          );
        }
        return CorrectionException('${provider.label} refused the request: $detail');
    }
    if (status >= 520 && status <= 530) {
      // Cloudflare answering for an origin that is gone: the Kaggle notebook
      // or its tunnel has stopped. It will not come back by retrying.
      return CorrectionException(
        '${provider.label} is not reachable: ${ProviderHealth.describeStatus(status, body)}',
        modelUnavailable: true,
        unreachable: true,
      );
    }
    if (status >= 500) {
      final bool busy = status == 503 ||
          lower.contains('high demand') ||
          lower.contains('overloaded') ||
          lower.contains('try again later');
      return CorrectionException(
        busy
            ? '$model is busy right now.'
            : '${provider.label} had a problem (${ProviderHealth.describeStatus(status, body)}). Trying again may work.',
        transient: true,
      );
    }
    return CorrectionException('${provider.label} returned an error: $detail');
  }

  /// Explains a rate limit in terms the teacher can act on.
  static String rateLimitMessage(
    ModelProvider provider,
    String model,
    Duration? retryAfter, {
    QuotaWindow window = QuotaWindow.unknown,
    bool freeTier = false,
  }) {
    final StringBuffer message = StringBuffer(switch (window) {
      QuotaWindow.perMinute => 'Too many requests reached $model at once (its per-minute limit).',
      QuotaWindow.perDay => 'The daily ${freeTier ? 'free ' : ''}allowance for $model has run out.',
      QuotaWindow.unknown => 'The ${provider.label} allowance for $model has run out or is rate limited.',
    });
    message.write(retryAfter != null
        ? ' Try again in about ${retryAfter.inSeconds} seconds.'
        : ' Please wait a moment and try again.');
    return message.toString();
  }

  /// The allowance a 429 names — "limit: 20" in the error text, or a
  /// `quotaValue` in its details.
  static int? quotaLimitFrom(String body) {
    final RegExpMatch? match =
        RegExp(r'limit:\s*(\d+)').firstMatch(body) ?? RegExp(r'"quotaValue"\s*:\s*"?(\d+)').firstMatch(body);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Which quota a 429 hit, from the `quotaId` of each violation Google
  /// reports (`GenerateRequestsPerDayPerProjectPerModel-FreeTier`, …).
  static QuotaWindow quotaWindow(String body) {
    final Iterable<String> ids =
        RegExp(r'"quotaId"\s*:\s*"([^"]+)"').allMatches(body).map((RegExpMatch match) => match.group(1)!);
    if (ids.any((String id) => id.contains('PerDay'))) return QuotaWindow.perDay;
    if (ids.any((String id) => id.contains('PerMinute'))) return QuotaWindow.perMinute;
    return QuotaWindow.unknown;
  }

  /// The wait a provider asked for: a `retry-after` header, or "retry in
  /// 34.7s" in the error text.
  static Duration? retryAfterFrom(String detail, Map<String, String> headers) {
    final int? header = int.tryParse(headers['retry-after']?.trim() ?? '');
    if (header != null && header > 0) return Duration(seconds: header);
    final RegExpMatch? match = RegExp(r'retry in ([0-9]+(?:\.[0-9]+)?)s', caseSensitive: false).firstMatch(detail);
    final double? seconds = match == null ? null : double.tryParse(match.group(1)!);
    return seconds != null && seconds > 0 ? Duration(seconds: seconds.ceil()) : null;
  }

  /// The message in an error body: `{"error": {"message": …}}`, the same in
  /// a list (Google's OpenAI-compatible endpoint), or the raw text.
  static String messageFromErrorBody(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      final Object? first = decoded is List && decoded.isNotEmpty ? decoded.first : decoded;
      if (first is Map<String, dynamic> && first['error'] != null) return _messageOf(first['error']);
    } on FormatException {
      // The raw body, below.
    }
    if (body.trimLeft().startsWith('<')) return 'an error page';
    return body.isEmpty ? 'no details were given' : body;
  }

  static String _messageOf(Object? error) =>
      error is Map<String, dynamic> && error['message'] is String ? error['message'] as String : '$error';

  /// Whether [model] can be reached and is served, in the teacher's words —
  /// for Settings' Test connection.
  Future<({bool ok, String message})> check(String model) async {
    final AiSettings settings = _settings();
    final ModelProvider provider;
    try {
      provider = _providerOrThrow(settings, model);
    } on CorrectionException catch (error) {
      return (ok: false, message: '${_short(error.message)}.');
    }
    final String id = provider.modelId(model);
    final http.Client client = _injectedClient ?? http.Client();
    try {
      final http.Response response = await client.get(
        Uri.parse('${provider.baseUrl}/models'),
        headers: <String, String>{
          if (provider.apiKey?.isNotEmpty ?? false) 'authorization': 'Bearer ${provider.apiKey}',
        },
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode == 401 || response.statusCode == 403) {
        return (ok: false, message: '${provider.label} rejected the key.');
      }
      if (response.statusCode != 200) {
        return (
          ok: false,
          message: '${provider.label} answered with an error '
              '(${ProviderHealth.describeStatus(response.statusCode, response.body)}).',
        );
      }
      final Object? data = (jsonDecode(response.body) as Map<String, dynamic>)['data'];
      final List<String> served = <String>[
        if (data is List)
          for (final Object? entry in data)
            if (entry is Map<String, dynamic> && entry['id'] is String)
              (entry['id'] as String).replaceFirst('models/', ''),
      ];
      if (served.isNotEmpty && !served.contains(id) && !served.contains('$id:latest')) {
        return (
          ok: false,
          message: provider.id == Providers.ollama
              ? 'Ollama is running, but $id is not installed. In a terminal, run: ollama pull $id'
              : '${provider.label} is reachable but does not serve $id.',
        );
      }
      return (ok: true, message: 'Ready: ${provider.label} serves $id.');
    } on SocketException {
      return (
        ok: false,
        message: provider.id == Providers.ollama
            ? 'Ollama is not running on this computer. Open the Ollama app, or run "ollama serve".'
            : 'Could not reach ${provider.label} at ${provider.baseUrl}.',
      );
    } on TimeoutException {
      return (ok: false, message: '${provider.label} did not answer in time.');
    } on http.ClientException {
      return (ok: false, message: 'Could not reach ${provider.label} at ${provider.baseUrl}.');
    } on FormatException {
      return (ok: false, message: '${provider.label} answered with something unexpected.');
    } finally {
      if (_injectedClient == null) client.close();
    }
  }
}
