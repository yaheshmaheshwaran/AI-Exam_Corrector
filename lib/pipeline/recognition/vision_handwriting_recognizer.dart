import 'dart:io';
import 'dart:typed_data';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/layout/vision_region_detector.dart';
import 'package:exam_corrector/services/ai/model_client.dart';

/// [HandwritingRecognizer] that shows region crops to a vision model.
///
/// Used as the second opinion on regions TrOCR was unsure of. TrOCR was
/// trained on one line of English prose at a time; a vision model reads whole
/// paragraphs, notation, and odd layouts. Crops are batched because quotas
/// count requests, not images.
class VisionHandwritingRecognizer implements HandwritingRecognizer {
  VisionHandwritingRecognizer(this._client, this._configProvider);

  final ModelClient _client;
  final AppConfig Function() _configProvider;

  AppConfig get _config => _configProvider();

  static const int batchSize = 10;

  bool get isAvailable => _client.isAvailable;

  @override
  String get fingerprint => 'vision-read:v2:${_config.effectiveVisionModel}';

  static const String systemPrompt = '''
You transcribe handwriting cropped from a student's exam paper. Each crop is one region: a paragraph, a line of working, a label, or a note.

Rules you must follow:
- Transcribe exactly what is written, verbatim, keeping line breaks. Never correct spelling, grammar, arithmetic, notation or terminology.
- Never complete, summarise, answer or comment on the content. You are transcribing, not marking.
- Preserve mathematical notation, units, symbols and subscripts as written.
- Write [illegible] for any word you cannot read. Do not guess.
- Set crossed_out to true only when the writing in the crop has been deliberately struck through — a line, a scribble or a cross over it — as a student cancelling work. A fraction bar, an underline or a ruled line is not a strike.
- List every word you are not sure of in uncertain_words with your confidence from 0 to 1.
- Return one entry for every crop, using the index printed before each image.
''';

  static final Map<String, Object?> schema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'readings': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'index': <String, Object?>{'type': 'integer'},
            'text': <String, Object?>{'type': 'string'},
            'crossed_out': <String, Object?>{'type': 'boolean'},
            'uncertain_words': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'text': <String, Object?>{'type': 'string'},
                  'confidence': <String, Object?>{'type': 'number'},
                },
                'required': <String>['text', 'confidence'],
                'additionalProperties': false,
              },
            },
          },
          'required': <String>['index', 'text', 'crossed_out', 'uncertain_words'],
          'additionalProperties': false,
        },
      },
    },
    'required': <String>['readings'],
    'additionalProperties': false,
  };

  @override
  Future<Map<String, HandwritingEvidence>> recognize(
    ExamDocument document,
    List<PageRegion> regions, {
    Map<String, HandwritingReading> priorReadings =
        const <String, HandwritingReading>{},
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final List<PageRegion> readable = regions
        .where((PageRegion region) => region.cropPath?.isNotEmpty ?? false)
        .toList();
    final Map<String, HandwritingEvidence> evidence =
        <String, HandwritingEvidence>{};
    final int batches = (readable.length / batchSize).ceil();

    for (int batch = 0; batch < batches; batch++) {
      cancel?.throwIfCancelled();
      final List<PageRegion> slice = readable.sublist(
        batch * batchSize,
        (batch * batchSize + batchSize).clamp(0, readable.length),
      );
      onProgress?.call(
        'Reading uncertain handwriting with the vision model '
        '(${batch + 1} of $batches)…',
        batch / batches,
      );

      final List<ContentPart> parts = <ContentPart>[
        TextPart('Transcribe each of the following ${slice.length} crops.'),
      ];
      final List<int> sent = <int>[];
      for (int index = 0; index < slice.length; index++) {
        final Uint8List? bytes = await _read(slice[index].cropPath!);
        if (bytes == null) continue;
        sent.add(index);
        parts.add(TextPart('Index $index:'));
        parts.add(ImagePart(bytes));
      }
      if (sent.isEmpty) continue;

      final ModelResponse response = await _client.requestJson(
        ModelRequest(
          purpose: 'handwriting check',
          systemInstruction: systemPrompt,
          parts: parts,
          schema: schema,
          maxTokens: 8000,
          effort: 'low',
          truncationHint: 'The handwriting check exceeded its output limit.',
          refusalMessage: 'The AI declined to transcribe these regions.',
        ),
        models: _config.chainFor(_config.effectiveVisionModel),
        cancel: cancel,
      );

      final JsonMap? payload = readMap(response.payload);
      for (final JsonMap entry
          in readObjects(payload?['readings'], (JsonMap m) => m)) {
        final int? index = readInt(entry['index']);
        if (index == null || index < 0 || index >= slice.length) continue;
        final String text = readRawString(entry['text'])?.trim() ?? '';
        final PageRegion region = slice[index];
        evidence[region.regionId] = HandwritingEvidence(
          regionId: region.regionId,
          readings: <HandwritingReading>[
            VisionRegionDetector.readingFrom(
              text,
              entry['uncertain_words'],
              response.model,
              crossedOut: readBool(entry['crossed_out']),
            ),
          ],
        );
      }
    }
    return evidence;
  }

  Future<Uint8List?> _read(String path) async {
    try {
      return await File(path).readAsBytes();
    } on IOException {
      return null;
    }
  }
}
