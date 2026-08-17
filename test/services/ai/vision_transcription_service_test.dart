import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';
import 'package:exam_corrector/services/ai/gemini_client.dart';
import 'package:exam_corrector/services/ai/vision_transcription_service.dart';

/// A 1x1 PNG, so the service has a real file to read and encode.
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

late Directory _crops;

String cropFile(String name) {
  final File file = File('${_crops.path}/$name');
  file.writeAsBytesSync(base64Decode(_pngBase64));
  return file.path;
}

TextLine line(
  String text, {
  required double confidence,
  required String cropPath,
}) {
  return TextLine(
    text: text,
    ocrText: text,
    confidence: confidence,
    box: const LineBox(x: 0, y: 0, width: 100, height: 20),
    cropPath: cropPath,
  );
}

DocumentTranscript transcriptOf(List<TextLine> lines) {
  return DocumentTranscript(
    pages: <PageTranscript>[
      PageTranscript(
        index: 0,
        imagePath: '/pages/page_000.png',
        width: 1240,
        height: 1754,
        lines: lines,
      ),
    ],
    engine: 'trocr',
    detector: 'db_resnet50',
    dpi: 300,
    workdir: '/tmp/t',
  );
}

const AppConfig baseConfig = AppConfig(
  apiKey: 'test-key',
  model: 'gemini-3.6-flash',
  effort: 'high',
  maxTokens: 32000,
  ocrConfidenceThreshold: 0.92,
);

/// Streams a structured response back as the API would.
http.Client respondingWith(
  List<Map<String, Object?>> lines, {
  void Function(String body)? onRequest,
}) {
  return MockClient.streaming((http.BaseRequest request, _) async {
    onRequest?.call(
      request is http.Request ? request.body : '',
    );

    final String payload = jsonEncode(<String, Object?>{'lines': lines});
    final String event = jsonEncode(<String, Object?>{
      'event_type': 'step.delta',
      'delta': <String, Object?>{'type': 'text', 'text': payload},
    });

    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[
        utf8.encode('data: $event\n\n'),
        utf8.encode('data: [DONE]\n\n'),
      ]),
      200,
    );
  });
}

VisionTranscriptionService serviceWith(
  http.Client client, {
  AppConfig config = baseConfig,
}) {
  return VisionTranscriptionService(
    () => config,
    client: GeminiClient(client: client, retryDelays: const <Duration>[]),
  );
}

void main() {
  setUp(() {
    _crops = Directory.systemTemp.createTempSync('vision_test_');
  });

  tearDown(() {
    if (_crops.existsSync()) _crops.deleteSync(recursive: true);
  });

  test('sends only the lines below the threshold', () async {
    String? body;
    final http.Client client = respondingWith(
      <Map<String, Object?>>[
        <String, Object?>{'index': 0, 'text': 'rechecked'},
      ],
      onRequest: (String value) => body = value,
    );

    final DocumentTranscript transcript = transcriptOf(<TextLine>[
      line('confident', confidence: 0.99, cropPath: cropFile('a.png')),
      line('unsure', confidence: 0.40, cropPath: cropFile('b.png')),
    ]);

    final CrossCheckOutcome outcome =
        await serviceWith(client).crossCheck(transcript);

    expect(outcome.rechecked, 1);

    // One image part for the one uncertain line — the confident line's crop
    // must not be sent, since every image costs tokens against a small quota.
    final List<dynamic> input =
        (jsonDecode(body!) as Map<String, dynamic>)['input'] as List<dynamic>;
    final Iterable<dynamic> images = input
        .cast<Map<String, dynamic>>()
        .where((Map<String, dynamic> part) => part['type'] == 'image');

    expect(images, hasLength(1));
  });

  test('sends the crops as inline images in the shape the API accepts',
      () async {
    String? body;
    final http.Client client = respondingWith(
      <Map<String, Object?>>[
        <String, Object?>{'index': 0, 'text': 'rechecked'},
      ],
      onRequest: (String value) => body = value,
    );

    await serviceWith(client).crossCheck(
      transcriptOf(<TextLine>[
        line('unsure', confidence: 0.4, cropPath: cropFile('a.png')),
      ]),
    );

    final Map<String, dynamic> decoded =
        jsonDecode(body!) as Map<String, dynamic>;
    final List<dynamic> input = decoded['input'] as List<dynamic>;
    final Map<String, dynamic> image = input
        .cast<Map<String, dynamic>>()
        .firstWhere((Map<String, dynamic> part) => part['type'] == 'image');

    expect(image['mime_type'], 'image/png');
    expect(image['data'], _pngBase64);
  });

  test('promotes a line both recognisers read the same way', () async {
    final http.Client client = respondingWith(<Map<String, Object?>>[
      <String, Object?>{'index': 0, 'text': 'glucose + oxygen'},
    ]);

    final CrossCheckOutcome outcome = await serviceWith(client).crossCheck(
      transcriptOf(<TextLine>[
        line('glucose + oxygen', confidence: 0.4, cropPath: cropFile('a.png')),
      ]),
    );

    final TextLine result = outcome.transcript.pages[0].lines[0];

    expect(result.confidence, VisionTranscriptionService.agreementConfidence);
    expect(result.isUncertain(0.92), isFalse);
  });

  test('ignores a difference that is only spacing or punctuation', () async {
    final http.Client client = respondingWith(<Map<String, Object?>>[
      <String, Object?>{'index': 0, 'text': 'glucose  +  oxygen.'},
    ]);

    final CrossCheckOutcome outcome = await serviceWith(client).crossCheck(
      transcriptOf(<TextLine>[
        line('glucose + oxygen', confidence: 0.4, cropPath: cropFile('a.png')),
      ]),
    );

    expect(
      outcome.transcript.pages[0].lines[0].confidence,
      VisionTranscriptionService.agreementConfidence,
    );
  });

  test('takes the second reading but keeps a disagreement flagged', () async {
    // The exact case this exists for: TrOCR read "t" where the page said "+".
    final http.Client client = respondingWith(<Map<String, Object?>>[
      <String, Object?>{'index': 0, 'text': 'glucose + oxygen'},
    ]);

    final CrossCheckOutcome outcome = await serviceWith(client).crossCheck(
      transcriptOf(<TextLine>[
        line('glucose t oxygen', confidence: 0.4, cropPath: cropFile('a.png')),
      ]),
    );

    final TextLine result = outcome.transcript.pages[0].lines[0];

    expect(result.text, 'glucose + oxygen');
    expect(result.source, OcrSource.vision);
    expect(result.confidence, VisionTranscriptionService.disagreementConfidence);
    // Still below the threshold, so the teacher is asked to look.
    expect(result.isUncertain(0.92), isTrue);
    expect(outcome.changed, 1);
  });

  test('keeps the original reading when the vision model returns nothing',
      () async {
    final http.Client client = respondingWith(<Map<String, Object?>>[
      <String, Object?>{'index': 0, 'text': ''},
    ]);

    final CrossCheckOutcome outcome = await serviceWith(client).crossCheck(
      transcriptOf(<TextLine>[
        line('illegible', confidence: 0.3, cropPath: cropFile('a.png')),
      ]),
    );

    expect(outcome.transcript.pages[0].lines[0].text, 'illegible');
  });

  test('does nothing when the cross-check is turned off', () async {
    final http.Client client = respondingWith(<Map<String, Object?>>[]);

    final CrossCheckOutcome outcome = await serviceWith(
      client,
      config: baseConfig.copyWith(visionCrossCheck: false),
    ).crossCheck(
      transcriptOf(<TextLine>[
        line('unsure', confidence: 0.3, cropPath: cropFile('a.png')),
      ]),
    );

    expect(outcome.rechecked, 0);
    expect(outcome.changed, 0);
  });

  test('warns rather than fails when there is no API key', () async {
    final http.Client client = respondingWith(<Map<String, Object?>>[]);

    final CrossCheckOutcome outcome = await serviceWith(
      client,
      config: baseConfig.copyWith(apiKey: () => null),
    ).crossCheck(
      transcriptOf(<TextLine>[
        line('unsure', confidence: 0.3, cropPath: cropFile('a.png')),
      ]),
    );

    expect(outcome.warnings.single, contains('no API key'));
    expect(outcome.transcript.pages[0].lines[0].text, 'unsure');
  });

  test('a spent quota warns and leaves the transcript usable', () async {
    // Marking must never be blocked by an optional second opinion.
    final http.Client client =
        MockClient.streaming((http.BaseRequest request, _) async {
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(<List<int>>[
          utf8.encode('{"error":{"message":"quota exceeded for free_tier"}}'),
        ]),
        429,
      );
    });

    final CrossCheckOutcome outcome = await serviceWith(client).crossCheck(
      transcriptOf(<TextLine>[
        line('unsure', confidence: 0.3, cropPath: cropFile('a.png')),
      ]),
    );

    expect(outcome.warnings.single, contains('could not be double-checked'));
    expect(outcome.transcript.pages[0].lines[0].text, 'unsure');
  });

  test('skips a line whose crop is missing from disk', () async {
    final http.Client client = respondingWith(<Map<String, Object?>>[]);

    final CrossCheckOutcome outcome = await serviceWith(client).crossCheck(
      transcriptOf(<TextLine>[
        line('unsure', confidence: 0.3, cropPath: '/nowhere/gone.png'),
      ]),
    );

    expect(outcome.transcript.pages[0].lines[0].text, 'unsure');
  });
}
