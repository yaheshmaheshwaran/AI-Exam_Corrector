import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/services/ai/gemini_correction_service.dart';

const AppConfig _config = AppConfig(
  apiKey: 'test-key',
  model: 'gemini-3.7-flash',
  effort: 'high',
  maxTokens: 32000,
);

const String _paper = 'Question 1. The mitochondrion makes ATP.';
const String _markScheme = 'Question 1 (2 marks): names ATP (1), site (1).';

const Map<String, dynamic> _validPayload = <String, dynamic>{
  'questions': <Object>[
    <String, dynamic>{
      'question_number': '1',
      'maximum_marks': 2,
      'awarded_marks': 1,
      'student_answer': 'The mitochondrion makes ATP.',
      'evaluation': 'Names ATP but omits the site.',
      'marking_points': <Object>[
        <String, dynamic>{
          'criterion': 'Names ATP',
          'satisfied': true,
          'marks': 1,
        },
        <String, dynamic>{
          'criterion': 'Identifies the site',
          'satisfied': false,
          'marks': 0,
        },
      ],
    },
  ],
  'total_marks': 1,
  'maximum_total_marks': 2,
  'percentage': 50,
};

/// Builds a server-sent event stream carrying [text] as the model's answer.
///
/// Includes a thought summary, which the service must ignore.
Stream<List<int>> _sseFor(
  String text, {
  String status = 'completed',
  Map<String, Object?>? incompleteDetails,
}) {
  final List<String> events = <String>[
    jsonEncode(<String, Object?>{
      'event_type': 'interaction.created',
      'interaction': <String, Object?>{
        'id': 'v1_test',
        'model': 'gemini-3.7-flash',
        'status': 'in_progress',
      },
    }),
    jsonEncode(<String, Object?>{
      'event_type': 'step.start',
      'index': 0,
      'step': <String, Object?>{'type': 'model_output'},
    }),
    jsonEncode(<String, Object?>{
      'event_type': 'step.delta',
      'index': 0,
      'delta': <String, Object?>{
        'type': 'thought_summary',
        'content': <String, Object?>{
          'type': 'text',
          'text': 'reasoning that must not reach the parser',
        },
      },
    }),
    // Split across two deltas so reassembly is exercised.
    jsonEncode(<String, Object?>{
      'event_type': 'step.delta',
      'index': 0,
      'delta': <String, Object?>{
        'type': 'text',
        'text': text.substring(0, text.length ~/ 2),
      },
    }),
    jsonEncode(<String, Object?>{
      'event_type': 'step.delta',
      'index': 0,
      'delta': <String, Object?>{
        'type': 'text',
        'text': text.substring(text.length ~/ 2),
      },
    }),
    jsonEncode(<String, Object?>{'event_type': 'step.stop', 'index': 0}),
    jsonEncode(<String, Object?>{
      'event_type': 'interaction.completed',
      'interaction': <String, Object?>{
        'id': 'v1_test',
        'status': status,
        'incomplete_details': ?incompleteDetails,
        'usage': <String, Object?>{'total_tokens': 19},
      },
    }),
  ];

  final String body =
      events.map((String event) => 'data: $event\n\n').join();
  // The real stream signs off with this sentinel, which is not JSON and must
  // not be fed to the parser.
  return Stream<List<int>>.value(utf8.encode('${body}data: [DONE]\n\n'));
}

GeminiCorrectionService _serviceReturning(
  Stream<List<int>> stream, {
  int statusCode = 200,
  void Function(http.BaseRequest request, String body)? onRequest,
}) {
  final MockClient client = MockClient.streaming(
    (http.BaseRequest request, http.ByteStream bodyStream) async {
      onRequest?.call(request, await bodyStream.bytesToString());
      return http.StreamedResponse(stream, statusCode);
    },
  );
  // No waiting in tests: retry timing is covered explicitly below.
  return GeminiCorrectionService(
    () => _config,
    client: client,
    retryDelays: const <Duration>[],
  );
}

Future<CorrectionResult> _correct(GeminiCorrectionService service) {
  return service.correct(paperText: _paper, markSchemeText: _markScheme);
}

void main() {
  group('request', () {
    test('sends the mark scheme, paper, schema and thinking level', () async {
      Map<String, dynamic>? sent;
      Map<String, String>? headers;
      Uri? url;

      final GeminiCorrectionService service = _serviceReturning(
        _sseFor(jsonEncode(_validPayload)),
        onRequest: (http.BaseRequest request, String body) {
          headers = request.headers;
          url = request.url;
          sent = jsonDecode(body) as Map<String, dynamic>;
        },
      );

      await _correct(service);

      expect(headers!['x-goog-api-key'], 'test-key');
      expect(url!.queryParameters['alt'], 'sse');
      expect(sent!['model'], 'gemini-3.7-flash');
      expect(sent!['stream'], isTrue);
      expect(sent!['store'], isFalse);

      final Map<String, dynamic> generationConfig =
          sent!['generation_config'] as Map<String, dynamic>;
      expect(generationConfig['max_output_tokens'], 32000);
      expect(generationConfig['thinking_level'], 'high');

      final Map<String, dynamic> responseFormat =
          sent!['response_format'] as Map<String, dynamic>;
      expect(responseFormat['mime_type'], 'application/json');
      expect(responseFormat, contains('schema'));

      expect(sent!['input'], contains(_markScheme));
      expect(sent!['input'], contains(_paper));
      expect(sent!['system_instruction'], contains('single authority'));
    });

    test('refuses to call the API without a mark scheme', () async {
      final GeminiCorrectionService service =
          _serviceReturning(_sseFor(jsonEncode(_validPayload)));

      expect(
        () => service.correct(paperText: _paper, markSchemeText: '   '),
        throwsA(isA<CorrectionException>()),
      );
    });

    test('reports missing credentials before sending anything', () async {
      final GeminiCorrectionService service = GeminiCorrectionService(
        () => const AppConfig(
          apiKey: null,
          model: 'gemini-3.7-flash',
          effort: 'high',
          maxTokens: 32000,
        ),
        client: MockClient.streaming(
          (http.BaseRequest request, http.ByteStream body) async =>
              fail('no request should be sent'),
        ),
      );

      await expectLater(
        _correct(service),
        throwsA(
          isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            contains('GEMINI_API_KEY'),
          ),
        ),
      );
    });
  });

  group('streamed response', () {
    test('reassembles text deltas and validates the result', () async {
      final GeminiCorrectionService service =
          _serviceReturning(_sseFor(jsonEncode(_validPayload)));

      final CorrectionResult result = await _correct(service);

      expect(result.questions, hasLength(1));
      expect(result.questions.single.awardedMarks, 1);
      expect(result.totalMarks, 1);
      expect(result.maximumTotalMarks, 2);
      expect(result.percentage, 50);
    });

    test('reports a blocked correction in the teacher\'s terms', () async {
      final GeminiCorrectionService service = _serviceReturning(
        _sseFor(
          jsonEncode(_validPayload),
          status: 'failed',
          incompleteDetails: <String, Object?>{'reason': 'safety'},
        ),
      );

      await expectLater(
        _correct(service),
        throwsA(
          isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            contains('declined'),
          ),
        ),
      );
    });

    test('reports a truncated correction', () async {
      final GeminiCorrectionService service = _serviceReturning(
        _sseFor(
          jsonEncode(_validPayload),
          status: 'incomplete',
          incompleteDetails: <String, Object?>{'reason': 'max_output_tokens'},
        ),
      );

      await expectLater(
        _correct(service),
        throwsA(
          isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            contains('EXAM_CORRECTOR_MAX_TOKENS'),
          ),
        ),
      );
    });

    test('rejects a response that is not JSON', () async {
      final GeminiCorrectionService service =
          _serviceReturning(_sseFor('I marked the paper for you!'));

      await expectLater(
        _correct(service),
        throwsA(
          isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            contains('not valid JSON'),
          ),
        ),
      );
    });

    test('rejects an empty response', () async {
      final GeminiCorrectionService service = _serviceReturning(
        Stream<List<int>>.value(utf8.encode(
          'data: {"event_type":"interaction.completed",'
          '"interaction":{"status":"completed"}}\n\n',
        )),
      );

      await expectLater(
        _correct(service),
        throwsA(
          isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            contains('empty response'),
          ),
        ),
      );
    });

    test('surfaces a mid-stream error event', () async {
      final GeminiCorrectionService service = _serviceReturning(
        Stream<List<int>>.value(utf8.encode(
          'data: {"event_type":"error","error":{"code":"unavailable",'
          '"message":"The service is overloaded"}}\n\n',
        )),
      );

      await expectLater(
        _correct(service),
        throwsA(
          isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            contains('overloaded'),
          ),
        ),
      );
    });

    test('rejects a structurally invalid correction', () async {
      final GeminiCorrectionService service = _serviceReturning(
        _sseFor(jsonEncode(<String, dynamic>{'questions': <Object>[]})),
      );

      await expectLater(
        _correct(service),
        throwsA(
          isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            contains('failed validation'),
          ),
        ),
      );
    });
  });

  group('transient failures', () {
    // The provider reports a busy model as a 500 whose body says "high
    // demand". That clears on its own, so the teacher should never see it.
    Stream<List<int>> busyBody() => Stream<List<int>>.value(utf8.encode(
          '{"error":{"message":"gemini-3.7-flash is currently experiencing '
          'high demand, spikes in demand are usually temporary. Please try '
          'again later.","code":"api_error"}}',
        ));

    test('retries a busy model and succeeds on a later attempt', () async {
      int attempts = 0;

      final GeminiCorrectionService service = GeminiCorrectionService(
        () => _config,
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
        client: MockClient.streaming(
          (http.BaseRequest request, http.ByteStream body) async {
            attempts++;
            if (attempts < 3) {
              return http.StreamedResponse(busyBody(), 500);
            }
            return http.StreamedResponse(
              _sseFor(jsonEncode(_validPayload)),
              200,
            );
          },
        ),
      );

      final CorrectionResult result = await _correct(service);

      expect(attempts, 3);
      expect(result.totalMarks, 1);
    });

    test('gives up after the retries and names the busy model', () async {
      int attempts = 0;

      final GeminiCorrectionService service = GeminiCorrectionService(
        () => _config,
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
        client: MockClient.streaming(
          (http.BaseRequest request, http.ByteStream body) async {
            attempts++;
            return http.StreamedResponse(busyBody(), 500);
          },
        ),
      );

      await expectLater(
        _correct(service),
        throwsA(
          isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            allOf(contains('gemini-3.7-flash'), contains('busy')),
          ),
        ),
      );
      expect(attempts, 3);
    });

    // The API states the wait in the error text; ignoring it guarantees the
    // retry is refused again, which is exactly what the teacher was seeing.
    test('waits as long as the API asked before retrying', () async {
      int attempts = 0;
      final List<Duration> waits = <Duration>[];
      final Stopwatch stopwatch = Stopwatch()..start();

      final GeminiCorrectionService service = GeminiCorrectionService(
        () => _config,
        retryDelays: const <Duration>[Duration(seconds: 3)],
        client: MockClient.streaming(
          (http.BaseRequest request, http.ByteStream body) async {
            attempts++;
            waits.add(stopwatch.elapsed);
            if (attempts == 1) {
              return http.StreamedResponse(
                Stream<List<int>>.value(utf8.encode(jsonEncode(<String, Object?>{
                  'error': <String, Object?>{
                    'message': 'You exceeded your current quota. Quota '
                        'exceeded for metric: '
                        'generate_content_free_tier_requests, limit: 20, '
                        'model: gemini-3.7-flash\nPlease retry in 4.2s.',
                    'code': 'too_many_requests',
                  },
                }))),
                429,
              );
            }
            return http.StreamedResponse(
              _sseFor(jsonEncode(_validPayload)),
              200,
            );
          },
        ),
      );

      final List<String> progress = <String>[];
      final CorrectionResult result = await service.correct(
        paperText: _paper,
        markSchemeText: _markScheme,
        onProgress: progress.add,
      );

      expect(attempts, 2);
      expect(result.totalMarks, 1);
      // 4.2s rounded up plus a second of headroom, not the 3s schedule.
      expect(waits.last.inMilliseconds, greaterThanOrEqualTo(5000));
      expect(
        progress.any((String message) => message.contains('rate limited')),
        isTrue,
        reason: 'the wait must be visible in the status bar: $progress',
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('explains an exhausted free-tier quota in the teacher\'s terms',
        () async {
      final GeminiCorrectionService service = GeminiCorrectionService(
        () => _config,
        retryDelays: const <Duration>[],
        client: MockClient.streaming(
          (http.BaseRequest request, http.ByteStream body) async =>
              http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode(jsonEncode(<String, Object?>{
              'error': <String, Object?>{
                'message': 'Quota exceeded for metric: '
                    'generate_content_free_tier_requests, limit: 20, model: '
                    'gemini-3.7-flash\nPlease retry in 34.7s.',
              },
            }))),
            429,
          ),
        ),
      );

      await expectLater(
        _correct(service),
        throwsA(
          isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            allOf(
              contains('free-tier quota'),
              contains('gemini-3.7-flash'),
              contains('35 seconds'),
              contains('Settings'),
            ),
          ),
        ),
      );
    });

    test('does not retry a rejected key', () async {
      int attempts = 0;

      final GeminiCorrectionService service = GeminiCorrectionService(
        () => _config,
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
        client: MockClient.streaming(
          (http.BaseRequest request, http.ByteStream body) async {
            attempts++;
            return http.StreamedResponse(
              Stream<List<int>>.value(utf8.encode(
                '{"error":{"message":"API key not valid"}}',
              )),
              401,
            );
          },
        ),
      );

      await expectLater(_correct(service), throwsA(isA<CorrectionException>()));
      expect(attempts, 1);
    });
  });

  group('model fallback chain', () {
    // The free tier allows about 20 requests a day per model, counted per
    // model, so an exhausted model is a reason to move on rather than to give
    // up on the paper.
    const AppConfig chained = AppConfig(
      apiKey: 'test-key',
      model: 'gemini-3.6-flash',
      effort: 'high',
      maxTokens: 32000,
      fallbackModels: <String>['gemini-3.5-flash', 'gemini-3.5-flash-lite'],
    );

    Stream<List<int>> quotaBody(String model) =>
        Stream<List<int>>.value(utf8.encode(jsonEncode(<String, Object?>{
          'error': <String, Object?>{
            'message': 'You exceeded your current quota. Quota exceeded for '
                'metric: generate_content_free_tier_requests, limit: 20, '
                'model: $model\nPlease retry in 34.7s.',
            'code': 'too_many_requests',
          },
        })));

    /// Answers 429 for every model in [exhausted], and marks otherwise.
    GeminiCorrectionService serviceWhere(
      Set<String> exhausted,
      List<String> modelsTried,
    ) {
      return GeminiCorrectionService(
        () => chained,
        // No retries here: this group is about moving between models, and the
        // per-model retry timing is covered above.
        retryDelays: const <Duration>[],
        client: MockClient.streaming(
          (http.BaseRequest request, http.ByteStream bodyStream) async {
            final Map<String, dynamic> body =
                jsonDecode(await bodyStream.bytesToString())
                    as Map<String, dynamic>;
            final String model = body['model'] as String;
            modelsTried.add(model);

            if (exhausted.contains(model)) {
              return http.StreamedResponse(quotaBody(model), 429);
            }
            return http.StreamedResponse(
              _sseFor(jsonEncode(_validPayload)),
              200,
            );
          },
        ),
      );
    }

    test('moves to the next model when the first has no quota left', () async {
      final List<String> modelsTried = <String>[];
      final List<String> progress = <String>[];

      final CorrectionResult result = await serviceWhere(
        <String>{'gemini-3.6-flash'},
        modelsTried,
      ).correct(
        paperText: _paper,
        markSchemeText: _markScheme,
        onProgress: progress.add,
      );

      expect(result.totalMarks, 1);
      // The marks are attributed to the model that actually produced them.
      expect(result.model, 'gemini-3.5-flash');
      expect(modelsTried.toSet(), <String>{
        'gemini-3.6-flash',
        'gemini-3.5-flash',
      });
      expect(
        progress.any((String message) =>
            message.contains('gemini-3.6-flash') &&
            message.contains('gemini-3.5-flash')),
        isTrue,
        reason: 'the switch must be visible in the status bar: $progress',
      );
    });

    test('walks past several exhausted models', () async {
      final List<String> modelsTried = <String>[];

      final CorrectionResult result = await serviceWhere(
        <String>{'gemini-3.6-flash', 'gemini-3.5-flash'},
        modelsTried,
      ).correct(paperText: _paper, markSchemeText: _markScheme);

      expect(result.model, 'gemini-3.5-flash-lite');
    });

    test('names every model when the whole chain is exhausted', () async {
      final List<String> modelsTried = <String>[];

      await expectLater(
        serviceWhere(
          <String>{
            'gemini-3.6-flash',
            'gemini-3.5-flash',
            'gemini-3.5-flash-lite',
          },
          modelsTried,
        ).correct(paperText: _paper, markSchemeText: _markScheme),
        throwsA(
          isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            allOf(
              contains('gemini-3.6-flash'),
              contains('gemini-3.5-flash'),
              contains('gemini-3.5-flash-lite'),
              contains('midnight'),
            ),
          ),
        ),
      );
      expect(modelsTried, hasLength(3));
    });

    test('switches immediately instead of waiting out a spent allowance',
        () async {
      final List<String> modelsTried = <String>[];
      final Stopwatch stopwatch = Stopwatch()..start();

      // Retries are enabled and the API asks for a 30s wait; with another
      // model available the correction must not take it.
      final GeminiCorrectionService service = GeminiCorrectionService(
        () => chained,
        retryDelays: const <Duration>[Duration(seconds: 30)],
        client: MockClient.streaming(
          (http.BaseRequest request, http.ByteStream bodyStream) async {
            final Map<String, dynamic> body =
                jsonDecode(await bodyStream.bytesToString())
                    as Map<String, dynamic>;
            final String model = body['model'] as String;
            modelsTried.add(model);

            if (model == 'gemini-3.6-flash') {
              return http.StreamedResponse(quotaBody(model), 429);
            }
            return http.StreamedResponse(
              _sseFor(jsonEncode(_validPayload)),
              200,
            );
          },
        ),
      );

      final CorrectionResult result = await service.correct(
        paperText: _paper,
        markSchemeText: _markScheme,
      );

      expect(result.model, 'gemini-3.5-flash');
      expect(modelsTried, <String>['gemini-3.6-flash', 'gemini-3.5-flash']);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    }, timeout: const Timeout(Duration(seconds: 45)));

    test('does not try another model when the key is rejected', () async {
      final List<String> modelsTried = <String>[];

      final GeminiCorrectionService service = GeminiCorrectionService(
        () => chained,
        retryDelays: const <Duration>[],
        client: MockClient.streaming(
          (http.BaseRequest request, http.ByteStream bodyStream) async {
            final Map<String, dynamic> body =
                jsonDecode(await bodyStream.bytesToString())
                    as Map<String, dynamic>;
            modelsTried.add(body['model'] as String);
            return http.StreamedResponse(
              Stream<List<int>>.value(utf8.encode(
                '{"error":{"message":"API key not valid"}}',
              )),
              401,
            );
          },
        ),
      );

      await expectLater(
        service.correct(paperText: _paper, markSchemeText: _markScheme),
        throwsA(isA<CorrectionException>()),
      );
      // A rejected key fails identically everywhere; trying the rest would
      // only waste the teacher's time.
      expect(modelsTried, <String>['gemini-3.6-flash']);
    });
  });

  group('HTTP failures', () {
    Future<void> expectMessage(
      int status,
      Matcher matcher, {
      String message = 'boom',
    }) async {
      final GeminiCorrectionService service = _serviceReturning(
        Stream<List<int>>.value(utf8.encode(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 'invalid_argument',
              'message': message,
            },
          }),
        )),
        statusCode: status,
      );

      await expectLater(
        _correct(service),
        throwsA(isA<CorrectionException>()
            .having((CorrectionException e) => e.message, 'message', matcher)),
      );
    }

    test('400 about the key explains the rejected key', () => expectMessage(
          400,
          contains('API key was rejected'),
          message: 'API key not valid. Please pass a valid API key.',
        ));

    test('401 explains the rejected key',
        () => expectMessage(401, contains('API key was rejected')));

    test('403 names the model',
        () => expectMessage(403, contains('gemini-3.7-flash')));

    test('429 asks the teacher to wait',
        () => expectMessage(429, contains('rate limit')));

    test('500 reports a temporary problem',
        () => expectMessage(500, contains('temporary problem')));

    test('503 reports an overloaded API',
        () => expectMessage(503, contains('overloaded')));

    test('400 passes the API message through',
        () => expectMessage(400, contains('boom')));

    test('a dropped connection reads as a lost connection', () async {
      final GeminiCorrectionService service = GeminiCorrectionService(
        () => _config,
        retryDelays: const <Duration>[],
        client: MockClient.streaming(
          (http.BaseRequest request, http.ByteStream body) async =>
              throw http.ClientException('connection closed'),
        ),
      );

      await expectLater(
        _correct(service),
        throwsA(
          isA<CorrectionException>().having(
            (CorrectionException e) => e.message,
            'message',
            contains('connection'),
          ),
        ),
      );
    });
  });
}
