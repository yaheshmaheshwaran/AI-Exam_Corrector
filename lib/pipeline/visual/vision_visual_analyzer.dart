import 'dart:io';
import 'dart:typed_data';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/services/ai/model_client.dart';

/// Diagram, graph, table and equation analysis by a vision model.
///
/// Each kind has its own instructions and its own response shape, because
/// what matters differs: a diagram's labels and relationships, a graph's axes
/// and trend, a table's cells, an equation's notation. All four share one
/// principle — describe what is visibly there, say how sure you are, and never
/// fill in what a correct answer would have contained.
class VisionVisualAnalyzer
    implements DiagramAnalyzer, GraphAnalyzer, TableAnalyzer, EquationRecognizer {
  VisionVisualAnalyzer(this._client, this._configProvider);

  final ModelClient _client;
  final AppConfig Function() _configProvider;

  AppConfig get _config => _configProvider();

  bool get isAvailable => _client.isAvailable;

  String get fingerprint => 'vision-visual:v1:${_config.effectiveDiagramModel}';

  static const int _maxPerRequest = 8;

  static const String _principles = '''
You examine cropped images from a student's handwritten exam answer. You describe; you do not mark.

Principles:
- Report only what is visibly present. Never add a component, label, value or step that a correct answer would contain but this one does not show.
- Transcribe labels, values and notation exactly as written, including mistakes. Write [illegible] for anything you cannot read.
- When the question the student was answering is given, note in relevance how the visual relates to it — but do not judge whether it earns marks.
- confidence is how sure you are of your description, from 0 to 1. Lower it for faint, cramped or ambiguous drawings.
- Return one item for every image, using the index printed before it.
''';

  @override
  Future<Map<String, VisualEvidence>> analyzeDiagrams(
    List<VisualTask> tasks, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) =>
      _analyze(
        tasks,
        kind: RegionType.diagram,
        instructions: '''
$_principles
For each diagram give: a description of what it depicts; every label written on it (labels); the parts or structures drawn (components); and the relationships shown — arrows, connections, flows, sequences — as short statements (relationships).
''',
        itemSchema: <String, Object?>{
          'description': _string,
          'labels': _strings,
          'components': _strings,
          'relationships': _strings,
          'relevance': _string,
          'confidence': _number,
        },
        decode: (String regionId, JsonMap item) => DiagramEvidence(
          regionId: regionId,
          description: readRawString(item['description']) ?? '',
          confidence: readConfidence(item['confidence'], orElse: 0.5),
          relevance: readRawString(item['relevance']) ?? '',
          labels: readStringList(item['labels']),
          components: readStringList(item['components']),
          relationships: readStringList(item['relationships']),
        ),
        onProgress: onProgress,
        cancel: cancel,
      );

  @override
  Future<Map<String, VisualEvidence>> analyzeGraphs(
    List<VisualTask> tasks, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) =>
      _analyze(
        tasks,
        kind: RegionType.graph,
        instructions: '''
$_principles
For each graph give: a description; the x-axis and y-axis as labelled, with units and scale if shown (x_axis, y_axis); every plotted element — points, lines, curves, bars, legend entries (plotted_elements); approximate values you can read off it, as "x → y" statements (approximate_values); the overall trend in one sentence (trend); and any other labels.
''',
        itemSchema: <String, Object?>{
          'description': _string,
          'x_axis': _string,
          'y_axis': _string,
          'plotted_elements': _strings,
          'approximate_values': _strings,
          'trend': _string,
          'labels': _strings,
          'relevance': _string,
          'confidence': _number,
        },
        decode: (String regionId, JsonMap item) => GraphEvidence(
          regionId: regionId,
          description: readRawString(item['description']) ?? '',
          confidence: readConfidence(item['confidence'], orElse: 0.5),
          relevance: readRawString(item['relevance']) ?? '',
          xAxis: readRawString(item['x_axis']) ?? '',
          yAxis: readRawString(item['y_axis']) ?? '',
          plottedElements: readStringList(item['plotted_elements']),
          approximateValues: readStringList(item['approximate_values']),
          trend: readRawString(item['trend']) ?? '',
          labels: readStringList(item['labels']),
        ),
        onProgress: onProgress,
        cancel: cancel,
      );

  @override
  Future<Map<String, VisualEvidence>> analyzeTables(
    List<VisualTask> tasks, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) =>
      _analyze(
        tasks,
        kind: RegionType.table,
        instructions: '''
$_principles
For each table give: a description; its cells row by row, the header row first if there is one, using "" for an empty cell (rows); and the text of any cell the student crossed out (crossed_out_cells).
''',
        itemSchema: <String, Object?>{
          'description': _string,
          'rows': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{'type': 'string'},
            },
          },
          'crossed_out_cells': _strings,
          'relevance': _string,
          'confidence': _number,
        },
        decode: (String regionId, JsonMap item) => TableEvidence(
          regionId: regionId,
          description: readRawString(item['description']) ?? '',
          confidence: readConfidence(item['confidence'], orElse: 0.5),
          relevance: readRawString(item['relevance']) ?? '',
          rows: <List<String>>[
            for (final Object? row in readList(item['rows']))
              <String>[
                for (final Object? cell in readList(row)) readRawString(cell) ?? '',
              ],
          ],
          crossedOutCells: readStringList(item['crossed_out_cells']),
        ),
        onProgress: onProgress,
        cancel: cancel,
      );

  @override
  Future<Map<String, VisualEvidence>> recognizeEquations(
    List<VisualTask> tasks, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) =>
      _analyze(
        tasks,
        kind: RegionType.equation,
        instructions: '''
$_principles
Each image is a handwritten equation or line of working. Give it as LaTeX exactly as written (latex) — keep the student's own steps and errors; do not simplify, solve or correct — and in plain characters (plain_text). Describe anything the notation cannot capture, such as a crossed-out term or an arrow between steps (description).
''',
        itemSchema: <String, Object?>{
          'latex': _string,
          'plain_text': _string,
          'description': _string,
          'confidence': _number,
        },
        decode: (String regionId, JsonMap item) => EquationEvidence(
          regionId: regionId,
          description: readRawString(item['description']) ?? '',
          confidence: readConfidence(item['confidence'], orElse: 0.5),
          latex: readRawString(item['latex']) ?? '',
          plainText: readRawString(item['plain_text']) ?? '',
        ),
        onProgress: onProgress,
        cancel: cancel,
      );

  static const Map<String, Object?> _string = <String, Object?>{'type': 'string'};
  static const Map<String, Object?> _number = <String, Object?>{'type': 'number'};
  static const Map<String, Object?> _strings = <String, Object?>{
    'type': 'array',
    'items': <String, Object?>{'type': 'string'},
  };

  Future<Map<String, VisualEvidence>> _analyze(
    List<VisualTask> tasks, {
    required RegionType kind,
    required String instructions,
    required Map<String, Object?> itemSchema,
    required VisualEvidence Function(String regionId, JsonMap item) decode,
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final Map<String, VisualEvidence> results = <String, VisualEvidence>{};
    final int perRequest = _config.maxImagesPerRequest.clamp(1, _maxPerRequest);
    final int batches = (tasks.length / perRequest).ceil();

    final Map<String, Object?> schema = <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'items': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'index': <String, Object?>{'type': 'integer'},
              ...itemSchema,
            },
            'required': <String>['index', ...itemSchema.keys],
            'additionalProperties': false,
          },
        },
      },
      'required': <String>['items'],
      'additionalProperties': false,
    };

    for (int batch = 0; batch < batches; batch++) {
      cancel?.throwIfCancelled();
      final List<VisualTask> slice = tasks.sublist(
        batch * perRequest,
        (batch * perRequest + perRequest).clamp(0, tasks.length),
      );
      onProgress?.call(
        'Analysing ${kind.displayName.toLowerCase()}s (${batch + 1} of $batches)…',
        batch / batches,
      );

      final List<ContentPart> parts = <ContentPart>[
        TextPart('Analyse each of these ${slice.length} image(s).'),
      ];
      for (int index = 0; index < slice.length; index++) {
        final Uint8List? bytes = await _read(slice[index].imagePath);
        if (bytes == null) continue;
        final String? context = slice[index].questionContext;
        parts.add(
          TextPart(
            'Index $index (page ${slice[index].region.pageNumber})'
            '${context == null ? '' : ' — found under the question: "$context"'}:',
          ),
        );
        parts.add(ImagePart(bytes, mimeType: _mime(slice[index].imagePath)));
      }

      final ModelResponse response = await _client.requestJson(
        ModelRequest(
          purpose: '${kind.displayName.toLowerCase()} analysis',
          systemInstruction: instructions,
          parts: parts,
          schema: schema,
          maxTokens: 12000,
          effort: 'low',
          truncationHint:
              'The ${kind.displayName.toLowerCase()} analysis exceeded its '
              'output limit.',
          refusalMessage: 'The AI declined to analyse these images.',
        ),
        models: _config.chainFor(_config.effectiveDiagramModel),
        cancel: cancel,
      );

      final JsonMap? payload = readMap(response.payload);
      for (final JsonMap item in readObjects(payload?['items'], (JsonMap m) => m)) {
        final int? index = readInt(item['index']);
        if (index == null || index < 0 || index >= slice.length) continue;
        final String regionId = slice[index].region.regionId;
        results[regionId] = decode(regionId, item);
      }
    }
    return results;
  }

  static String _mime(String path) =>
      path.toLowerCase().endsWith('.jpg') || path.toLowerCase().endsWith('.jpeg')
          ? 'image/jpeg'
          : 'image/png';

  Future<Uint8List?> _read(String path) async {
    try {
      return await File(path).readAsBytes();
    } on IOException {
      return null;
    }
  }
}
