import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/llm_client.dart';
import 'package:exam_corrector/ai/model_request.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/provider_health.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';

const Map<String, String> _keys = <String, String>{
  Providers.geminiKeyName: 'g-key',
  Providers.nvidiaKeyName: 'n-key',
  Providers.serverAddressName: 'http://gpu.local:8000/v1/',
  Providers.serverKeyName: 'secret',
};

AiSettings _settings({Map<String, String> values = _keys, int retries = 0}) =>
    AiSettings.fromMap(values, fallback: <String, String>{AiSettings.retriesName: '$retries'});

/// [settings] with one provider replaced, for timeouts a test can wait out.
AiSettings _with(AiSettings settings, ModelProvider replacement) => settings.copyWith(
      providers: Providers(<String, ModelProvider>{
        for (final ModelProvider p in settings.providers.all) p.id: p.id == replacement.id ? replacement : p,
      }),
    );

ModelProvider _fast(ModelProvider p, {Duration? header, Duration? idle, Duration? total}) => ModelProvider(
      id: p.id,
      label: p.label,
      baseUrl: p.baseUrl,
      apiKey: p.apiKey,
      keyName: p.keyName,
      addressName: p.addressName,
      selfHosted: p.selfHosted,
      needsKey: p.needsKey,
      jsonSchema: p.jsonSchema,
      sendsEffort: p.sendsEffort,
      dailyAllowance: p.dailyAllowance,
      maxAnswerTokens: p.maxAnswerTokens,
      headerTimeout: header ?? p.headerTimeout,
      idleTimeout: idle ?? p.idleTimeout,
      totalTimeout: total ?? p.totalTimeout,
    );

const Map<String, Object?> _schema = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{
    'marks': <String, Object?>{'type': 'number'},
  },
  'required': <String>['marks'],
};

ModelRequest _request({int maxTokens = 8000, String effort = 'high'}) => ModelRequest(
      purpose: 'marking',
      systemInstruction: 'You mark exams.',
      parts: <ContentPart>[const TextPart('QUESTION 1'), ImagePart(Uint8List.fromList(<int>[1, 2, 3]))],
      schema: _schema,
      maxTokens: maxTokens,
      effort: effort,
      truncationHint: 'Too long.',
    );

/// An OpenAI-style event stream: [text] in two content deltas, after a
/// reasoning delta the client must ignore.
Stream<List<int>> _sse(String text, {String finish = 'stop'}) {
  Map<String, Object?> chunk(Map<String, Object?> delta, [String? reason]) => <String, Object?>{
        'choices': <Object?>[
          <String, Object?>{'index': 0, 'delta': delta, 'finish_reason': reason},
        ],
      };
  final List<Map<String, Object?>> events = <Map<String, Object?>>[
    chunk(<String, Object?>{'reasoning_content': 'thinking about it'}),
    chunk(<String, Object?>{'content': text.substring(0, text.length ~/ 2)}),
    chunk(<String, Object?>{'content': text.substring(text.length ~/ 2)}),
    chunk(<String, Object?>{}, finish),
  ];
  final String body = events.map((Map<String, Object?> e) => 'data: ${jsonEncode(e)}\n\n').join();
  return Stream<List<int>>.value(utf8.encode('${body}data: [DONE]\n\n'));
}

http.StreamedResponse _ok(String text, {String finish = 'stop'}) =>
    http.StreamedResponse(_sse(text, finish: finish), 200);

http.StreamedResponse _status(int status, String body, {Map<String, String> headers = const <String, String>{}}) =>
    http.StreamedResponse(Stream<List<int>>.value(utf8.encode(body)), status, headers: headers);

LlmClient _client(
  Future<http.StreamedResponse> Function(http.BaseRequest request, Map<String, dynamic> body) handler, {
  AiSettings? settings,
  UsageMonitor? usage,
  ProviderHealth? health,
}) {
  final AiSettings resolved = settings ?? _settings();
  return LlmClient(
    () => resolved,
    retryDelays: const <Duration>[],
    maxRetryWait: Duration.zero,
    usage: usage,
    health: health,
    client: MockClient.streaming((http.BaseRequest request, http.ByteStream body) async {
      final String text = await body.bytesToString();
      return handler(request, text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>);
    }),
  );
}

void main() {
  group('the request', () {
    test('Gemini: one chat-completions request with images, schema, effort and no prefix', () async {
      late http.BaseRequest raw;
      late Map<String, dynamic> sent;
      final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
        raw = request;
        sent = body;
        return _ok('{"marks": 2}');
      });

      final ModelResponse response = await client.requestJson(_request(), models: <String>['gemini/gemini-3.8-flash']);

      expect(response.payload, <String, Object?>{'marks': 2});
      expect(response.model, 'gemini/gemini-3.8-flash');
      expect(raw.url.toString(), '${Providers.defaultGeminiUrl}/chat/completions');
      expect(raw.headers['authorization'], 'Bearer g-key');
      expect(sent['model'], 'gemini-3.8-flash');
      expect(sent['temperature'], 0);
      expect(sent['reasoning_effort'], 'high');
      expect((sent['response_format'] as Map<String, dynamic>)['type'], 'json_schema');
      final List<dynamic> messages = sent['messages'] as List<dynamic>;
      expect((messages.first as Map<String, dynamic>)['content'], contains('"required":["marks"]'));
      final List<dynamic> content = (messages.last as Map<String, dynamic>)['content'] as List<dynamic>;
      expect(content.first, <String, Object?>{'type': 'text', 'text': 'QUESTION 1'});
      expect(((content.last as Map<String, dynamic>)['image_url'] as Map<String, dynamic>)['url'],
          'data:image/png;base64,AQID');
    });

    test('NVIDIA: the model keeps its own slash, gets a JSON object, and no effort', () async {
      late http.BaseRequest raw;
      late Map<String, dynamic> sent;
      final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
        raw = request;
        sent = body;
        return _ok('{"marks": 1}');
      });

      await client.requestJson(_request(), models: <String>['nvidia/moonshotai/kimi-k3']);

      expect(raw.url.toString(), '${Providers.defaultNvidiaUrl}/chat/completions');
      expect(raw.headers['authorization'], 'Bearer n-key');
      expect(sent['model'], 'moonshotai/kimi-k3');
      expect(sent['response_format'], <String, Object?>{'type': 'json_object'});
      expect(sent.containsKey('reasoning_effort'), isFalse);
    });

    test('a model name splits at its first slash only', () {
      expect(parseModelName('nvidia/moonshotai/kimi-k3'), (provider: 'nvidia', model: 'moonshotai/kimi-k3'));
      expect(parseModelName('gemini-3.6-flash'), isNull);
      expect(parseModelName('server/'), isNull);
    });

    test('answers are sized to what each server allows, and a cap wins', () {
      final Providers providers = _settings().providers;
      ModelProvider p(String id) => providers.byId(id)!;
      expect(LlmClient.requestBody(p('gemini'), 'gemini/x', _request(maxTokens: 32000))['max_tokens'], 32000);
      expect(LlmClient.requestBody(p('server'), 'server/x', _request(maxTokens: 32000))['max_tokens'], 8192);
      final ModelRequest capped = ModelRequest(
        purpose: 'reading',
        systemInstruction: '',
        parts: const <ContentPart>[TextPart('x')],
        schema: _schema,
        maxTokens: 4000,
        answerCap: 500,
        enforceSchema: false,
      );
      final Map<String, Object?> body = LlmClient.requestBody(p('server'), 'server/x', capped);
      expect(body['max_tokens'], 500);
      expect(body.containsKey('response_format'), isFalse);
      expect(body['messages'] as List<dynamic>, hasLength(1));
    });
  });

  group('reading the answer', () {
    test('thinking, a code fence, or a word before the JSON are all read', () {
      expect(LlmClient.decodeJson('<think>hmm</think>\n```json\n{"marks": 1}\n```'), <String, Object?>{'marks': 1});
      expect(LlmClient.decodeJson('Here is the result: {"marks": 3} — done.'), <String, Object?>{'marks': 3});
      expect(LlmClient.decodeJson('```json\n[{"a": 1}]\n```'), <Object?>[<String, Object?>{'a': 1}]);
      expect(() => LlmClient.decodeJson('no json here'), throwsFormatException);
    });

    test('asks once more when the answer is not JSON', () async {
      int calls = 0;
      final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
        calls++;
        return _ok(calls == 1 ? 'The student gets two marks.' : '{"marks": 2}');
      });

      final ModelResponse response = await client.requestJson(_request(), models: <String>['gemini/gemini-3.8-flash']);

      expect(calls, 2);
      expect(response.payload, <String, Object?>{'marks': 2});
    });

    test('an answer cut off at the output limit is reported as truncated', () async {
      final LlmClient client =
          _client((http.BaseRequest request, Map<String, dynamic> body) async => _ok('{"marks"', finish: 'length'));

      await expectLater(
        client.requestJson(_request(), models: <String>['gemini/gemini-3.8-flash']),
        throwsA(isA<CorrectionException>().having((CorrectionException e) => e.truncated, 'truncated', isTrue)),
      );
    });
  });

  group('moving down the list', () {
    test('Ollama not running: the next model answers', () async {
      final List<String> asked = <String>[];
      final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
        asked.add(body['model'] as String);
        if (request.url.host == 'localhost') throw const SocketException('Connection refused');
        return _ok('{"marks": 0}');
      });

      final ModelResponse response = await client.requestJson(
        _request(),
        models: <String>['ollama/qwen3-vl:8b', 'server/Qwen/Qwen3-VL-8B-Instruct'],
      );

      expect(asked, <String>['qwen3-vl:8b', 'Qwen/Qwen3-VL-8B-Instruct']);
      expect(response.model, 'server/Qwen/Qwen3-VL-8B-Instruct');
    });

    test('a provider without its key is skipped, and named when nothing answers', () async {
      final AiSettings noNvidia = _settings(values: const <String, String>{Providers.geminiKeyName: 'g-key'});
      final LlmClient answering = _client(
        (http.BaseRequest request, Map<String, dynamic> body) async => _ok('{"marks": 1}'),
        settings: noNvidia,
      );
      final ModelResponse response = await answering.requestJson(
        _request(),
        models: <String>['nvidia/moonshotai/kimi-k3', 'gemini/gemini-3.8-flash'],
      );
      expect(response.model, 'gemini/gemini-3.8-flash');

      final LlmClient failing = _client(
        (http.BaseRequest request, Map<String, dynamic> body) async => _status(503, '{"error":{"message":"overloaded"}}'),
        settings: noNvidia,
      );
      await expectLater(
        failing.requestJson(_request(), models: <String>['nvidia/moonshotai/kimi-k3', 'gemini/gemini-3.8-flash']),
        throwsA(isA<CorrectionException>().having(
          (CorrectionException e) => e.message,
          'message',
          allOf(contains(Providers.nvidiaKeyName), contains('busy')),
        )),
      );
    });

    test('a server that never starts answering is left for the next model', () async {
      final AiSettings settings = _with(
        _settings(),
        _fast(_settings().providers.byId('nvidia')!, header: const Duration(milliseconds: 50)),
      );
      final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
        if (request.url.host == 'integrate.api.nvidia.com') return Completer<http.StreamedResponse>().future;
        return _ok('{"marks": 4}');
      }, settings: settings);

      final ModelResponse response = await client.requestJson(
        _request(),
        models: <String>['nvidia/moonshotai/kimi-k3', 'gemini/gemini-3.8-flash'],
      );

      expect(response.model, 'gemini/gemini-3.8-flash');
    });

    test('a hosted provider that hung is left alone for a while, then asked again', () async {
      DateTime now = DateTime(2026, 10, 6, 12);
      final AiSettings settings = _with(
        _settings(),
        _fast(_settings().providers.byId('nvidia')!, header: const Duration(milliseconds: 30)),
      );
      final List<String> hosts = <String>[];
      final LlmClient client = LlmClient(
        () => settings,
        retryDelays: const <Duration>[],
        clock: () => now,
        client: MockClient.streaming((http.BaseRequest request, http.ByteStream body) async {
          await body.drain<void>();
          hosts.add(request.url.host);
          if (request.url.host == 'integrate.api.nvidia.com') return Completer<http.StreamedResponse>().future;
          return _ok('{"marks": 1}');
        }),
      );
      const List<String> chain = <String>['nvidia/moonshotai/kimi-k3', 'gemini/gemini-3.8-flash'];

      await client.requestJson(_request(), models: chain);
      expect(client.isResting('nvidia/z-ai/glm-5.3'), isTrue, reason: 'the whole provider rests');

      hosts.clear();
      await client.requestJson(_request(), models: chain);
      expect(hosts, <String>['generativelanguage.googleapis.com']);

      now = now.add(LlmClient.hungRest + const Duration(seconds: 1));
      hosts.clear();
      await client.requestJson(_request(), models: chain);
      expect(hosts.first, 'integrate.api.nvidia.com');
    });

    test('an answer that stalls mid-way is left once its time is up', () async {
      final AiSettings settings = _with(
        _settings(),
        _fast(_settings().providers.byId('nvidia')!, total: const Duration(milliseconds: 80)),
      );
      final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
        if (request.url.host == 'integrate.api.nvidia.com') {
          // Starts answering, then keeps the connection open without a word.
          final StreamController<List<int>> stalled = StreamController<List<int>>();
          stalled.add(utf8.encode('data: {"choices":[{"delta":{"reasoning_content":"…"}}]}\n\n'));
          addTearDown(stalled.close);
          return http.StreamedResponse(stalled.stream, 200);
        }
        return _ok('{"marks": 5}');
      }, settings: settings);

      final List<String> progress = <String>[];
      final ModelResponse response = await client.requestJson(
        _request(),
        models: <String>['nvidia/moonshotai/kimi-k3', 'gemini/gemini-3.8-flash'],
        onProgress: progress.add,
      );

      expect(response.model, 'gemini/gemini-3.8-flash');
      expect(progress.single, contains('took longer than'));
    });
  });

  group('allowances', () {
    String violation(String quotaId) => jsonEncode(<Object?>[
          <String, Object?>{
            'error': <String, Object?>{
              'code': 429,
              'message': 'Quota exceeded for metric generate_content_free_tier_requests, limit: 20. '
                  'Please retry in 12.5s.',
              'details': <Object?>[
                <String, Object?>{
                  'violations': <Object?>[
                    <String, Object?>{'quotaId': quotaId, 'quotaValue': '20'},
                  ],
                },
              ],
            },
          },
        ]);

    test("Gemini's daily allowance moves on and is remembered until the reset", () async {
      final DateTime now = DateTime.utc(2026, 10, 6, 10);
      final UsageMonitor usage = UsageMonitor(clock: () => now, dailyAllowance: (String m) => m.startsWith('gemini/'));
      final List<String> asked = <String>[];
      final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
        asked.add(body['model'] as String);
        if (body['model'] == 'gemini-3.8-flash') {
          return _status(429, violation('GenerateRequestsPerDayPerProjectPerModel-FreeTier'));
        }
        return _ok('{"marks": 1}');
      }, usage: usage, settings: _settings(retries: 2));

      final ModelResponse response = await client.requestJson(
        _request(),
        models: <String>['gemini/gemini-3.8-flash', 'nvidia/moonshotai/kimi-k3'],
      );

      expect(response.model, 'nvidia/moonshotai/kimi-k3');
      expect(asked, <String>['gemini-3.8-flash', 'moonshotai/kimi-k3']);
      expect(usage.exhaustedUntil('gemini/gemini-3.8-flash'), UsageMonitor.nextQuotaReset(now));
      expect(usage.today['gemini/gemini-3.8-flash']!.limit, 20);
    });

    test('a per-minute limit waits and retries the same model', () async {
      int calls = 0;
      final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
        calls++;
        if (calls == 1) return _status(429, violation('GenerateRequestsPerMinutePerProjectPerModel-FreeTier'));
        return _ok('{"marks": 2}');
      }, settings: _settings(retries: 2));

      final ModelResponse response = await client.requestJson(
        _request(),
        models: <String>['gemini/gemini-3.8-flash', 'nvidia/moonshotai/kimi-k3'],
      );

      expect(calls, 2);
      expect(response.model, 'gemini/gemini-3.8-flash');
    });

    test('a per-minute limit is waited out patiently, more often than an error is retried', () async {
      int calls = 0;
      final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
        calls++;
        if (calls <= 4) return _status(429, violation('GenerateRequestsPerMinutePerProjectPerModel-FreeTier'));
        return _ok('{"marks": 2}');
      }, settings: _settings(retries: 1));

      final ModelResponse response = await client.requestJson(_request(), models: <String>['gemini/gemini-3.8-flash']);

      expect(calls, 5);
      expect(response.payload, <String, Object?>{'marks': 2});
    });

    test('the error and its wait are read from either error shape', () {
      final ModelProvider gemini = _settings().providers.byId('gemini')!;
      final CorrectionException error = LlmClient.errorForStatus(
          429, violation('GenerateRequestsPerDayPerProjectPerModel-FreeTier'), const <String, String>{}, gemini, 'g');
      expect(error.dailyQuota, isTrue);
      expect(error.retryAfter, const Duration(seconds: 13));
      expect(LlmClient.messageFromErrorBody('{"error":{"message":"bad"}}'), 'bad');
      expect(LlmClient.messageFromErrorBody('<html>'), 'an error page');
    });

    test('a server on our own hardware is busy, never out of allowance', () {
      final Providers providers = _settings().providers;
      expect(
        LlmClient.errorForStatus(429, '', const <String, String>{}, providers.byId('ollama')!, 'ollama/x')
            .quotaExhausted,
        isFalse,
      );
      expect(
        LlmClient.errorForStatus(429, '', const <String, String>{}, providers.byId('nvidia')!, 'nvidia/x')
            .quotaExhausted,
        isTrue,
      );
    });
  });

  group('our own servers', () {
    test('a stopped Kaggle tunnel is marked down and skipped next time', () async {
      final ProviderHealth health = ProviderHealth();
      final List<String> hosts = <String>[];
      final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
        hosts.add(request.url.host);
        if (request.url.host == 'gpu.local') return _status(530, '<html>origin down</html>');
        return _ok('{"marks": 1}');
      }, health: health);
      const List<String> chain = <String>['server/Qwen/Qwen3-VL-8B-Instruct', 'gemini/gemini-3.1-flash-lite'];

      await client.requestJson(_request(), models: chain);
      expect(health.isDown('server'), isTrue);
      expect(health.statusOf('server').reason, contains('tunnel'));

      hosts.clear();
      await client.requestJson(_request(), models: chain);
      expect(hosts, <String>['generativelanguage.googleapis.com']);
    });

    test('a model Ollama has not pulled says how to pull it', () async {
      final LlmClient client = _client(
        (http.BaseRequest request, Map<String, dynamic> body) async =>
            _status(404, '{"error":{"message":"model not found"}}'),
      );
      await expectLater(
        client.requestJson(_request(), models: <String>['ollama/qwen3-vl:8b']),
        throwsA(isA<CorrectionException>()
            .having((CorrectionException e) => e.modelUnavailable, 'modelUnavailable', isTrue)
            .having((CorrectionException e) => e.message, 'message', contains('ollama pull qwen3-vl:8b'))),
      );
    });
  });

  test('every attempt is counted against its model', () async {
    final UsageMonitor usage = UsageMonitor();
    int calls = 0;
    final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
      calls++;
      return calls == 1 ? _status(503, 'busy') : _ok('{"marks": 1}');
    }, usage: usage, settings: _settings(retries: 1));

    await client.requestJson(_request(), models: <String>['gemini/gemini-3.8-flash']);

    expect(usage.today['gemini/gemini-3.8-flash']!.requests, 2);
    expect(usage.recent.single.status, CallStatus.succeeded);
  });

  test('a role sends to its own models', () async {
    final List<String> asked = <String>[];
    final AiSettings settings = _settings().copyWith(
      roles: ModelRoles.defaults.withChain(ModelRole.reader, <String>['gemini/gemini-3.5-flash-lite']),
    );
    final LlmClient client = _client((http.BaseRequest request, Map<String, dynamic> body) async {
      asked.add(body['model'] as String);
      return _ok('{"marks": 1}');
    }, settings: settings);

    await client.requestRole(ModelRole.reader, _request());

    expect(asked, <String>['gemini-3.5-flash-lite']);
  });

  group('Test connection', () {
    LlmClient answering(int status, Object body) => LlmClient(
          _settings,
          client: MockClient((http.Request request) async => http.Response(jsonEncode(body), status)),
        );

    test("finds Gemini's model under its listed name", () async {
      final ({bool ok, String message}) result = await answering(200, <String, Object?>{
        'data': <Object?>[
          <String, Object?>{'id': 'models/gemini-3.1-flash-lite'},
        ],
      }).check('gemini/gemini-3.1-flash-lite');
      expect(result.ok, isTrue);
    });

    test('says how to pull a model Ollama does not have', () async {
      final ({bool ok, String message}) result = await answering(200, <String, Object?>{
        'data': <Object?>[
          <String, Object?>{'id': 'llama3:latest'},
        ],
      }).check('ollama/qwen3-vl:8b-instruct');
      expect(result.ok, isFalse);
      expect(result.message, contains('ollama pull qwen3-vl:8b-instruct'));
    });

    test('asks for the key a provider needs', () async {
      final ({bool ok, String message}) result = await LlmClient(
        () => _settings(values: const <String, String>{}),
      ).check('nvidia/moonshotai/kimi-k3');
      expect(result.ok, isFalse);
      expect(result.message, contains(Providers.nvidiaKeyName));
    });
  });
}
