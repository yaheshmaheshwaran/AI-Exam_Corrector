import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/ai/gemini_client.dart';
import 'package:exam_corrector/services/ai/gemini_model_client.dart';
import 'package:exam_corrector/services/ai/model_client.dart';
import 'package:exam_corrector/services/ai/model_usage.dart';

const AppConfig _config = AppConfig(
  apiKey: 'test-key',
  model: 'gemini-3.7-flash',
  effort: 'high',
  maxTokens: 32000,
  retryCount: 0,
);

const Map<String, Object?> _payload = <String, Object?>{'questions': <Object?>[]};

const Map<String, Object?> _schema = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{
    'questions': <String, Object?>{'type': 'array'},
  },
  'required': <String>['questions'],
};

ModelRequest _request({List<ContentPart>? parts}) => ModelRequest(
      purpose: 'marking',
      systemInstruction: 'You mark exams.',
      parts: parts ?? const <ContentPart>[TextPart('QUESTION 1 …')],
      schema: _schema,
      maxTokens: 32000,
      effort: 'high',
      truncationHint: 'Raise EXAM_CORRECTOR_MAX_TOKENS.',
      refusalMessage: 'The AI declined to mark this paper.',
    );

/// A server-sent event stream carrying [text] as the model's answer — split
/// across two deltas, preceded by a thought summary the client must ignore,
/// and ended by the non-JSON `[DONE]` sentinel.
Stream<List<int>> _sseFor(
  String text, {
  String status = 'completed',
  Map<String, Object?>? incompleteDetails,
}) {
  final List<String> events = <String>[
    jsonEncode(<String, Object?>{
      'event_type': 'interaction.created',
      'interaction': <String, Object?>{'id': 'v1_test', 'status': 'in_progress'},
    }),
    jsonEncode(<String, Object?>{
      'event_type': 'step.delta',
      'index': 0,
      'delta': <String, Object?>{
        'type': 'thought_summary',
        'content': <String, Object?>{'type': 'text', 'text': 'reasoning'},
      },
    }),
    jsonEncode(<String, Object?>{
      'event_type': 'step.delta',
      'index': 0,
      'delta': <String, Object?>{'type': 'text', 'text': text.substring(0, text.length ~/ 2)},
    }),
    jsonEncode(<String, Object?>{
      'event_type': 'step.delta',
      'index': 0,
      'delta': <String, Object?>{'type': 'text', 'text': text.substring(text.length ~/ 2)},
    }),
    jsonEncode(<String, Object?>{
      'event_type': 'interaction.completed',
      'interaction': <String, Object?>{
        'id': 'v1_test',
        'status': status,
        'incomplete_details': ?incompleteDetails,
      },
    }),
  ];
  final String body = events.map((String e) => 'data: $e\n\n').join();
  return Stream<List<int>>.value(utf8.encode('${body}data: [DONE]\n\n'));
}

Stream<List<int>> _error(String message, {String code = 'invalid_argument'}) =>
    Stream<List<int>>.value(utf8.encode(jsonEncode(<String, Object?>{
      'error': <String, Object?>{'code': code, 'message': message},
    })));

GeminiModelClient _client(
  Future<http.StreamedResponse> Function(http.BaseRequest request, String body) handler, {
  AppConfig config = _config,
  List<Duration> retryDelays = const <Duration>[],
  ModelUsageMonitor? usage,
}) {
  return GeminiModelClient(
    () => config,
    usage: usage,
    client: GeminiClient(
      client: MockClient.streaming(
        (http.BaseRequest request, http.ByteStream body) async =>
            handler(request, await body.bytesToString()),
      ),
      retryDelays: retryDelays,
    ),
  );
}

Future<ModelResponse> _send(GeminiModelClient client, {AppConfig config = _config}) =>
    client.requestJson(_request(), models: config.modelChain);

void main() {
  group('request', () {
    test('sends the instruction, the schema, the effort, and stays stateless', () async {
      late Map<String, dynamic> sent;
      late http.BaseRequest raw;
      final GeminiModelClient client = _client((http.BaseRequest request, String body) async {
        raw = request;
        sent = jsonDecode(body) as Map<String, dynamic>;
        return http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
      });

      final ModelResponse response = await _send(client);

      expect(response.payload, _payload);
      expect(response.model, 'gemini-3.7-flash');
      expect(raw.headers['x-goog-api-key'], 'test-key');
      expect(raw.url.toString(), endsWith('interactions?alt=sse'));
      expect(sent['model'], 'gemini-3.7-flash');
      expect(sent['store'], isFalse);
      expect(sent['system_instruction'], 'You mark exams.');
      expect(sent['input'], 'QUESTION 1 …');
      expect(sent['generation_config'], <String, Object?>{
        'max_output_tokens': 32000,
        'thinking_level': 'high',
      });
      expect((sent['response_format'] as Map<String, dynamic>)['schema'], _schema);
    });

    test('sends images as typed parts beside the text', () async {
      late Map<String, dynamic> sent;
      final GeminiModelClient client = _client((http.BaseRequest request, String body) async {
        sent = jsonDecode(body) as Map<String, dynamic>;
        return http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
      });

      await client.requestJson(
        _request(parts: <ContentPart>[
          const TextPart('Image of [R1]:'),
          ImagePart(Uint8List.fromList(<int>[1, 2, 3]), mimeType: 'image/jpeg'),
        ]),
        models: _config.modelChain,
      );

      expect(sent['input'], <Object?>[
        <String, Object?>{'type': 'text', 'text': 'Image of [R1]:'},
        <String, Object?>{'type': 'image', 'mime_type': 'image/jpeg', 'data': 'AQID'},
      ]);
    });

    test('uses the configured endpoint', () async {
      late http.BaseRequest raw;
      final AppConfig proxied = _config.copyWith(apiEndpoint: 'https://proxy.example/v1/interactions');
      final GeminiModelClient client = _client((http.BaseRequest request, String body) async {
        raw = request;
        return http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
      }, config: proxied);

      await _send(client, config: proxied);

      expect(raw.url.host, 'proxy.example');
    });

    test('reports missing credentials before sending anything', () async {
      int calls = 0;
      const AppConfig keyless = AppConfig(apiKey: null, model: 'm', effort: 'high', maxTokens: 1);
      final GeminiModelClient client = _client((http.BaseRequest r, String b) async {
        calls++;
        return http.StreamedResponse(_sseFor('{}'), 200);
      }, config: keyless);

      expect(client.isAvailable, isFalse);
      await expectLater(
        _send(client, config: keyless),
        throwsA(isA<CorrectionException>().having(
          (CorrectionException e) => e.message,
          'message',
          contains('No API key'),
        )),
      );
      expect(calls, 0);
    });
  });

  group('streamed response', () {
    Future<void> expectFailure(Stream<List<int>> stream, Matcher message) async {
      final GeminiModelClient client = _client(
        (http.BaseRequest r, String b) async => http.StreamedResponse(stream, 200),
      );
      await expectLater(
        _send(client),
        throwsA(isA<CorrectionException>()
            .having((CorrectionException e) => e.message, 'message', message)),
      );
    }

    test('reports a blocked request in the teacher\'s terms', () => expectFailure(
          _sseFor('{}', status: 'incomplete', incompleteDetails: <String, Object?>{'reason': 'safety'}),
          contains('declined'),
        ));

    test('reports a truncated response with the setting to raise', () => expectFailure(
          _sseFor('{"questions": [', status: 'incomplete', incompleteDetails: <String, Object?>{'reason': 'max_tokens'}),
          contains('EXAM_CORRECTOR_MAX_TOKENS'),
        ));

    test('rejects a response that is not JSON', () => expectFailure(
          _sseFor('this is prose, not JSON'),
          contains('not valid JSON'),
        ));

    test('rejects an empty response', () => expectFailure(
          Stream<List<int>>.value(utf8.encode('data: [DONE]\n\n')),
          contains('empty'),
        ));

    test('surfaces a mid-stream error event', () => expectFailure(
          Stream<List<int>>.value(utf8.encode(
            'data: ${jsonEncode(<String, Object?>{'event_type': 'error', 'error': <String, Object?>{'code': 'internal', 'message': 'kaboom'}})}\n\n',
          )),
          contains('kaboom'),
        ));
  });

  group('transient failures', () {
    Stream<List<int>> busy() => _error(
          'gemini-3.7-flash is currently experiencing high demand. Please try again later.',
          code: 'api_error',
        );

    test('retries a busy model and succeeds on a later attempt', () async {
      int attempts = 0;
      final GeminiModelClient client = _client(
        (http.BaseRequest r, String b) async {
          attempts++;
          return attempts < 3
              ? http.StreamedResponse(busy(), 500)
              : http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
        },
        config: _config.copyWith(retryCount: 2),
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

      await _send(client);
      expect(attempts, 3);
    });

    test('gives up after the retries and names the busy model', () async {
      int attempts = 0;
      final GeminiModelClient client = _client(
        (http.BaseRequest r, String b) async {
          attempts++;
          return http.StreamedResponse(busy(), 500);
        },
        config: _config.copyWith(retryCount: 2),
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

      await expectLater(
        _send(client),
        throwsA(isA<CorrectionException>().having(
          (CorrectionException e) => e.message,
          'message',
          allOf(contains('gemini-3.7-flash'), contains('busy')),
        )),
      );
      expect(attempts, 3);
    });

    test('waits as long as the API asked before retrying', () async {
      int attempts = 0;
      final Stopwatch stopwatch = Stopwatch()..start();
      final List<Duration> at = <Duration>[];
      final List<String> progress = <String>[];
      final GeminiModelClient client = _client(
        (http.BaseRequest r, String b) async {
          attempts++;
          at.add(stopwatch.elapsed);
          return attempts == 1
              ? http.StreamedResponse(
                  _error('Quota exceeded for metric: generate_content_free_tier_requests, '
                      'limit: 20\nPlease retry in 2.2s.'),
                  429,
                )
              : http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
        },
        config: _config.copyWith(retryCount: 1),
        retryDelays: const <Duration>[Duration(seconds: 1)],
      );

      await client.requestJson(_request(), models: _config.modelChain, onProgress: progress.add);

      expect(attempts, 2);
      // 2.2s rounded up plus a second of headroom, not the 1s schedule.
      expect(at.last.inMilliseconds, greaterThanOrEqualTo(4000));
      expect(progress.any((String m) => m.contains('rate limited')), isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('explains an exhausted free-tier quota in the teacher\'s terms', () async {
      final GeminiModelClient client = _client(
        (http.BaseRequest r, String b) async => http.StreamedResponse(
          _error('Quota exceeded for metric: generate_content_free_tier_requests, '
              'limit: 20, model: gemini-3.7-flash\nPlease retry in 34.7s.'),
          429,
        ),
      );

      await expectLater(
        _send(client),
        throwsA(isA<CorrectionException>().having(
          (CorrectionException e) => e.message,
          'message',
          allOf(contains('free-tier quota'), contains('gemini-3.7-flash'), contains('35 seconds')),
        )),
      );
    });

    test('does not retry a rejected key', () async {
      int attempts = 0;
      final GeminiModelClient client = _client(
        (http.BaseRequest r, String b) async {
          attempts++;
          return http.StreamedResponse(_error('API key not valid'), 401);
        },
        config: _config.copyWith(retryCount: 2),
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

      await expectLater(_send(client), throwsA(isA<CorrectionException>()));
      expect(attempts, 1);
    });
  });

  group('model fallback chain', () {
    final AppConfig chained = _config.copyWith(
      model: 'gemini-3.6-flash',
      fallbackModels: <String>['gemini-3.5-flash', 'gemini-3.5-flash-lite'],
    );

    GeminiModelClient where(Set<String> exhausted, List<String> tried, {int status = 429}) =>
        _client(
          (http.BaseRequest r, String body) async {
            final String model = (jsonDecode(body) as Map<String, dynamic>)['model'] as String;
            tried.add(model);
            if (exhausted.contains(model)) {
              return http.StreamedResponse(
                _error('Quota exceeded for metric: generate_content_free_tier_requests, '
                    'limit: 20, model: $model\nPlease retry in 34.7s.'),
                status,
              );
            }
            return http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
          },
          config: chained,
        );

    test('moves to the next model when the first has no quota left', () async {
      final List<String> tried = <String>[];
      final List<String> progress = <String>[];

      final ModelResponse response = await where(<String>{'gemini-3.6-flash'}, tried)
          .requestJson(_request(), models: chained.modelChain, onProgress: progress.add);

      expect(response.model, 'gemini-3.5-flash');
      expect(tried, <String>['gemini-3.6-flash', 'gemini-3.5-flash']);
      expect(
        progress.any((String m) => m.contains('gemini-3.6-flash') && m.contains('gemini-3.5-flash')),
        isTrue,
      );
    });

    test('walks past several exhausted models', () async {
      final List<String> tried = <String>[];
      final ModelResponse response = await where(
        <String>{'gemini-3.6-flash', 'gemini-3.5-flash'},
        tried,
      ).requestJson(_request(), models: chained.modelChain);
      expect(response.model, 'gemini-3.5-flash-lite');
    });

    test('names every model when the whole chain is exhausted', () async {
      final List<String> tried = <String>[];
      await expectLater(
        where(chained.modelChain.toSet(), tried).requestJson(_request(), models: chained.modelChain),
        throwsA(isA<CorrectionException>().having(
          (CorrectionException e) => e.message,
          'message',
          allOf(contains('gemini-3.6-flash'), contains('gemini-3.5-flash-lite'), contains('midnight')),
        )),
      );
      expect(tried, hasLength(3));
    });

    test('switches immediately instead of waiting out a spent allowance', () async {
      final List<String> tried = <String>[];
      final Stopwatch stopwatch = Stopwatch()..start();
      final GeminiModelClient client = _client(
        (http.BaseRequest r, String body) async {
          final String model = (jsonDecode(body) as Map<String, dynamic>)['model'] as String;
          tried.add(model);
          return model == 'gemini-3.6-flash'
              ? http.StreamedResponse(_error('Please retry in 30s.'), 429)
              : http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
        },
        config: chained.copyWith(retryCount: 2),
        retryDelays: const <Duration>[Duration(seconds: 30), Duration(seconds: 30)],
      );

      final ModelResponse response =
          await client.requestJson(_request(), models: chained.modelChain);

      expect(response.model, 'gemini-3.5-flash');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('does not try another model when the key is rejected', () async {
      final List<String> tried = <String>[];
      await expectLater(
        where(chained.modelChain.toSet(), tried, status: 401)
            .requestJson(_request(), models: chained.modelChain),
        throwsA(isA<CorrectionException>()),
      );
      expect(tried, <String>['gemini-3.6-flash']);
    });
  });

  group('which quota ran out', () {
    Stream<List<int>> quota(String quotaId) =>
        Stream<List<int>>.value(utf8.encode(jsonEncode(<String, Object?>{
          'error': <String, Object?>{
            'code': 429,
            'message': 'Quota exceeded. Please retry in 0.2s.',
            'details': <Object?>[
              <String, Object?>{
                '@type': 'type.googleapis.com/google.rpc.QuotaFailure',
                'violations': <Object?>[
                  <String, Object?>{'quotaId': quotaId},
                ],
              },
            ],
          },
        })));

    final AppConfig chained = _config.copyWith(
      model: 'gemini-3.6-flash',
      fallbackModels: <String>['gemini-3.5-flash'],
      retryCount: 2,
    );

    test('a per-minute limit waits and retries the same model', () async {
      final List<String> tried = <String>[];
      final GeminiModelClient client = _client(
        (http.BaseRequest r, String body) async {
          tried.add((jsonDecode(body) as Map<String, dynamic>)['model'] as String);
          return tried.length == 1
              ? http.StreamedResponse(quota('GenerateRequestsPerMinutePerProjectPerModel-FreeTier'), 429)
              : http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
        },
        config: chained,
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

      final ModelResponse response =
          await client.requestJson(_request(), models: chained.modelChain);

      expect(tried, <String>['gemini-3.6-flash', 'gemini-3.6-flash']);
      expect(response.model, 'gemini-3.6-flash');
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a spent daily quota moves straight to the next model', () async {
      final List<String> tried = <String>[];
      final GeminiModelClient client = _client(
        (http.BaseRequest r, String body) async {
          tried.add((jsonDecode(body) as Map<String, dynamic>)['model'] as String);
          return tried.length == 1
              ? http.StreamedResponse(quota('GenerateRequestsPerDayPerProjectPerModel-FreeTier'), 429)
              : http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
        },
        config: chained,
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

      final ModelResponse response =
          await client.requestJson(_request(), models: chained.modelChain);

      expect(tried, <String>['gemini-3.6-flash', 'gemini-3.5-flash']);
      expect(response.model, 'gemini-3.5-flash');
    });

    group('counted and remembered by the usage monitor', () {
      test('every request is counted, retries included, and a wait is shown', () async {
        final ModelUsageMonitor usage = ModelUsageMonitor();
        final List<ModelCallStatus> seen = <ModelCallStatus>[];
        int sent = 0;
        final GeminiModelClient client = _client(
          (http.BaseRequest r, String body) async {
            sent++;
            if (sent == 1) {
              seen.add(usage.active!.status);
              return http.StreamedResponse(quota('GenerateRequestsPerMinutePerProjectPerModel-FreeTier'), 429);
            }
            seen.add(usage.active!.status);
            return http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
          },
          config: chained,
          retryDelays: const <Duration>[Duration.zero, Duration.zero],
          usage: usage,
        );

        await client.requestJson(_request(), models: chained.modelChain);

        expect(usage.today['gemini-3.6-flash']!.requests, 2);
        expect(usage.today['gemini-3.6-flash']!.rateLimited, 1);
        expect(usage.requestsToday, 2);
        expect(usage.active, isNull);
        final ModelCall call = usage.recent.single;
        expect(call.status, ModelCallStatus.succeeded);
        expect(call.attempts, 2);
        expect(call.purpose, 'marking');
        expect(seen, <ModelCallStatus>[ModelCallStatus.running, ModelCallStatus.running]);
      }, timeout: const Timeout(Duration(seconds: 20)));

      test('a model out of its daily quota is not asked again today', () async {
        final ModelUsageMonitor usage = ModelUsageMonitor();
        final List<String> tried = <String>[];
        final GeminiModelClient client = _client(
          (http.BaseRequest r, String body) async {
            final String model = (jsonDecode(body) as Map<String, dynamic>)['model'] as String;
            tried.add(model);
            return model == 'gemini-3.6-flash'
                ? http.StreamedResponse(quota('GenerateRequestsPerDayPerProjectPerModel-FreeTier'), 429)
                : http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
          },
          config: chained,
          retryDelays: const <Duration>[Duration.zero, Duration.zero],
          usage: usage,
        );

        await client.requestJson(_request(), models: chained.modelChain);
        expect(usage.isExhausted('gemini-3.6-flash'), isTrue);
        expect(usage.exhaustedUntil('gemini-3.6-flash'), ModelUsageMonitor.nextQuotaReset(usage.now));

        tried.clear();
        await client.requestJson(_request(), models: chained.modelChain);
        expect(tried, <String>['gemini-3.5-flash']);
      });

      test('with every model out of quota, nothing is sent and the reset time is given', () async {
        final ModelUsageMonitor usage = ModelUsageMonitor();
        final GeminiModelClient client = _client(
          (http.BaseRequest r, String body) async =>
              http.StreamedResponse(quota('GenerateRequestsPerDayPerProjectPerModel-FreeTier'), 429),
          config: chained,
          retryDelays: const <Duration>[Duration.zero, Duration.zero],
          usage: usage,
        );
        await expectLater(
          client.requestJson(_request(), models: chained.modelChain),
          throwsA(isA<CorrectionException>()),
        );
        expect(usage.recent.single.status, ModelCallStatus.failed);
        final int before = usage.requestsToday;

        await expectLater(
          client.requestJson(_request(), models: chained.modelChain),
          throwsA(isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            allOf(contains('out of quota'), contains('comes back at')),
          )),
        );
        expect(usage.requestsToday, before);
      });
    });

    test('the quota window is read from the error details', () {
      expect(GeminiClient.quotaWindow('{"quotaId": "GenerateRequestsPerMinutePerProjectPerModel"}'),
          QuotaWindow.perMinute);
      expect(GeminiClient.quotaWindow('{"quotaId": "GenerateRequestsPerDayPerProjectPerModel"}'),
          QuotaWindow.perDay);
      expect(GeminiClient.quotaWindow('{"error": {"message": "slow down"}}'), QuotaWindow.unknown);
    });
  });

  group('HTTP failures', () {
    Future<void> expectMessage(int status, Matcher matcher, {String message = 'boom'}) async {
      final GeminiModelClient client = _client(
        (http.BaseRequest r, String b) async => http.StreamedResponse(_error(message), status),
      );
      await expectLater(
        _send(client),
        throwsA(isA<CorrectionException>()
            .having((CorrectionException e) => e.message, 'message', matcher)),
      );
    }

    test('400 about the key explains the rejected key', () => expectMessage(
          400,
          contains('API key was rejected'),
          message: 'API key not valid. Please pass a valid API key.',
        ));
    test('401 explains the rejected key', () => expectMessage(401, contains('API key was rejected')));
    test('403 names the model', () => expectMessage(403, contains('gemini-3.7-flash')));
    test('429 asks the teacher to wait', () => expectMessage(429, contains('rate limit')));
    test('500 reports a temporary problem', () => expectMessage(500, contains('temporary problem')));
    test('503 reports an overloaded API', () => expectMessage(503, contains('overloaded')));
    test('400 passes the API message through', () => expectMessage(400, contains('boom')));

    test('a dropped connection reads as a lost connection', () async {
      final GeminiModelClient client = _client(
        (http.BaseRequest r, String b) async => throw http.ClientException('connection closed'),
      );
      await expectLater(
        _send(client),
        throwsA(isA<CorrectionException>()
            .having((CorrectionException e) => e.message, 'message', contains('connection'))),
      );
    });
  });

  test('a cancelled request stops without contacting the API', () async {
    int calls = 0;
    final GeminiModelClient client = _client((http.BaseRequest r, String b) async {
      calls++;
      return http.StreamedResponse(_sseFor(jsonEncode(_payload)), 200);
    });
    final CancellationToken token = CancellationToken()..cancel();

    await expectLater(
      client.requestJson(_request(), models: _config.modelChain, cancel: token),
      throwsA(isA<CancelledException>()),
    );
    expect(calls, 0);
  });

  test('a timeout is reported as the API not responding', () async {
    final GeminiModelClient client = _client(
      (http.BaseRequest r, String b) async => http.StreamedResponse(
        Stream<List<int>>.periodic(const Duration(seconds: 5), (_) => <int>[]).take(1),
        200,
      ),
      config: _config.copyWith(requestTimeout: const Duration(milliseconds: 200)),
    );

    await expectLater(
      _send(client),
      throwsA(isA<CorrectionException>()
          .having((CorrectionException e) => e.message, 'message', contains('stopped responding'))),
    );
  });
}
