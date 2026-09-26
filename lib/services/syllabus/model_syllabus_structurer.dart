import 'dart:typed_data';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/services/ai/model_client.dart';
import 'package:exam_corrector/services/syllabus/syllabus_parser.dart';

/// Reads a syllabus's units with a model, for a layout the parser does not
/// know. One text-only request per syllabus, made once when it is added.
class ModelSyllabusStructurer {
  ModelSyllabusStructurer(this._client, this._configProvider);

  final ModelClient _client;
  final AppConfig Function() _configProvider;

  bool get isAvailable => _client.isAvailable;

  /// Longer syllabi are cut here; units come early, books and references
  /// late, so little that matters is lost.
  static const int maxCharacters = 40000;

  static const String systemPrompt = '''
You read a university course syllabus and return its structure. You copy what it says; you never add topics of your own.

- course_title, course_code (e.g. "CCS356"), regulation (e.g. "R2021"): as printed, or "".
- units: every unit or module in order. number as printed ("I", "3", "Module 2"); title as printed; topics: the topics listed under it, one per entry, in the syllabus's own words; hours: the hours or periods printed for it, or -1.
- outcomes: the course outcomes, each as "CO1: …", or [].
- textbooks: the text books, or the references if there are no text books, or [].
- Some slides or pages may be attached as images — pictures of the syllabus, often tables. Read them as part of the syllabus, together with the text.
''';

  static final Map<String, Object?> schema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'course_title': <String, Object?>{'type': 'string'},
      'course_code': <String, Object?>{'type': 'string'},
      'regulation': <String, Object?>{'type': 'string'},
      'units': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'number': <String, Object?>{'type': 'string'},
            'title': <String, Object?>{'type': 'string'},
            'topics': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{'type': 'string'},
            },
            'hours': <String, Object?>{'type': 'number'},
          },
          'required': <String>['number', 'title', 'topics', 'hours'],
          'additionalProperties': false,
        },
      },
      'outcomes': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{'type': 'string'},
      },
      'textbooks': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{'type': 'string'},
      },
    },
    'required': <String>['course_title', 'course_code', 'regulation', 'units', 'outcomes', 'textbooks'],
    'additionalProperties': false,
  };

  /// Pictures sent with one request, at most.
  static const int maxImages = 10;

  /// [images] are slides or pages that are pictures of the syllabus; with
  /// them the vision model reads the request.
  Future<ParsedSyllabus> structure(
    String text, {
    List<({int slide, Uint8List bytes, String mimeType})> images =
        const <({int slide, Uint8List bytes, String mimeType})>[],
    CancellationToken? cancel,
    void Function(String message)? onProgress,
  }) async {
    final String trimmed =
        text.length > maxCharacters ? text.substring(0, maxCharacters) : text;
    final List<({int slide, Uint8List bytes, String mimeType})> sent = images.take(maxImages).toList();
    final AppConfig config = _configProvider();
    final ModelResponse response = await _client.requestJson(
      ModelRequest(
        purpose: 'syllabus reading',
        systemInstruction: systemPrompt,
        parts: <ContentPart>[
          TextPart('SYLLABUS:\n$trimmed'),
          for (final ({int slide, Uint8List bytes, String mimeType}) image in sent) ...<ContentPart>[
            TextPart('Slide ${image.slide}, a picture:'),
            ImagePart(image.bytes, mimeType: image.mimeType),
          ],
        ],
        schema: schema,
        maxTokens: 8000,
        effort: 'low',
        truncationHint: 'The syllabus was too long to read in one request.',
        refusalMessage: 'The AI declined to read this syllabus.',
      ),
      models: sent.isEmpty ? config.modelChain : config.chainFor(config.effectiveVisionModel),
      onProgress: onProgress,
      cancel: cancel,
    );
    return fromPayload(readMap(response.payload) ?? const <String, Object?>{});
  }

  /// Pure; tested directly.
  static ParsedSyllabus fromPayload(JsonMap payload) => ParsedSyllabus(
        courseTitle: readRawString(payload['course_title'])?.trim() ?? '',
        courseCode: readRawString(payload['course_code'])?.trim() ?? '',
        regulation: readRawString(payload['regulation'])?.trim() ?? '',
        units: <SyllabusUnit>[
          for (final JsonMap unit in readObjects(payload['units'], (JsonMap m) => m))
            if (readString(unit['number']) case final String number)
              SyllabusUnit(
                number: number,
                title: readRawString(unit['title'])?.trim() ?? '',
                topics: readStringList(unit['topics'])
                    .map((String t) => t.trim())
                    .where((String t) => t.isNotEmpty)
                    .toList(),
                hours: switch (readDouble(unit['hours'])) {
                  final double h when h > 0 => h.round(),
                  _ => null,
                },
              ),
        ],
        outcomes: readStringList(payload['outcomes']),
        textbooks: readStringList(payload['textbooks']),
      );
}
