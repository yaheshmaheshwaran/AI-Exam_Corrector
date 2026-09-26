import 'dart:io';
import 'dart:typed_data';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/services/ai/model_client.dart';

/// [RegionDetector] backed by a vision model.
///
/// The model sees the whole page, so it can tell a diagram from a paragraph,
/// printed question text from the student's writing, and a crossed-out line
/// from a kept one — the distinctions local analysis cannot make. It also
/// reads the writing as it goes; that transcription is kept as one reading of
/// each region, beside whatever the local recogniser makes of it.
class VisionRegionDetector implements RegionDetector {
  VisionRegionDetector(this._client, this._configProvider);

  final ModelClient _client;
  final AppConfig Function() _configProvider;

  AppConfig get _config => _configProvider();

  static const String promptVersion = 'vision-layout:v2';

  @override
  String get fingerprint =>
      '$promptVersion:${_config.effectiveVisionModel}:${_config.pagesPerVisionRequest}';

  bool get isAvailable => _client.isAvailable;

  static const List<String> _types = <String>[
    'printed_text',
    'question_number',
    'handwritten_answer',
    'diagram',
    'graph',
    'table',
    'equation',
    'label',
    'crossed_out',
    'margin_note',
    'header',
    'footer',
    'unknown',
  ];

  static const String systemPrompt = '''
You analyse scanned pages of a student's exam answer booklet. For each page image, divide the page into semantic regions and read what is written in them. You are describing the page, not marking it.

Region types:
- printed_text: text printed on the booklet — question wording, instructions, printed headings.
- question_number: a question label standing on its own, printed or handwritten ("4", "Q4", "2(b)", "(ii)").
- handwritten_answer: the student's handwritten prose or working.
- diagram: a drawing, labelled figure or illustration.
- graph: a plotted graph or chart with axes.
- table: a table drawn or completed by the student.
- equation: a mathematical or chemical equation, or a line of calculation, set apart from prose.
- label: a label belonging to a diagram, graph or table. Set parent_index to that region's index.
- crossed_out: writing the student has struck through.
- margin_note: a note in the margin.
- header / footer: running page headers or footers, page numbers.
- unknown: anything else that is written or drawn.

Rules:
- Account for everything written or drawn on the page. Leave out only empty space and ruled lines.
- Start a new region at every question label. Never let one region run from the end of one answer into the next question.
- A numbered or lettered list inside an answer — the student's own points 1, 2, 3 or i, ii, iii — is part of that answer, not a question label. Keep it in the answer's region and leave label "". Only a question label starts a new region.
- Keep each diagram, graph and table as one region. Its labels are separate "label" regions whose parent_index is the diagram's index in this page's list.
- box_2d is [ymin, xmin, ymax, xmax], scaled 0 to 1000 relative to the image.
- reading_order is the order a teacher would read the page's regions, from 0.
- label: when a region is, or begins with, a question label, give the label exactly as written ("Q4", "2 (b)"). Otherwise "".
- text: transcribe the region verbatim. Never correct spelling, grammar, arithmetic, notation or terminology, and never complete or improve an answer. Write [illegible] for any word you cannot read rather than guessing. Use "" for diagrams and graphs, which are analysed separately. For a crossed-out region, transcribe the struck text if it is still legible.
- uncertain_words: every word in text you are not sure of, with your confidence from 0 to 1.
- confidence: how sure you are of the region's type and extent, from 0 to 1.
- is_blank: true when nothing at all is written on the page.
''';

  static final Map<String, Object?> schema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'pages': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'page_index': <String, Object?>{'type': 'integer'},
            'is_blank': <String, Object?>{'type': 'boolean'},
            'regions': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'type': <String, Object?>{'type': 'string', 'enum': _types},
                  'box_2d': <String, Object?>{
                    'type': 'array',
                    'items': <String, Object?>{'type': 'integer'},
                  },
                  'reading_order': <String, Object?>{'type': 'integer'},
                  'label': <String, Object?>{'type': 'string'},
                  'text': <String, Object?>{'type': 'string'},
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
                  'confidence': <String, Object?>{'type': 'number'},
                  'parent_index': <String, Object?>{
                    'type': 'integer',
                    'description': 'Index of the parent region, or -1.',
                  },
                },
                'required': <String>[
                  'type',
                  'box_2d',
                  'reading_order',
                  'label',
                  'text',
                  'uncertain_words',
                  'confidence',
                  'parent_index',
                ],
                'additionalProperties': false,
              },
            },
          },
          'required': <String>['page_index', 'is_blank', 'regions'],
          'additionalProperties': false,
        },
      },
    },
    'required': <String>['pages'],
    'additionalProperties': false,
  };

  @override
  Future<RegionDetection> detect(
    ExamDocument document,
    List<ExamPage> pages, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final List<ExamPage> withImages =
        pages.where((ExamPage page) => page.hasImage).toList();
    final int batchSize = _config.pagesPerVisionRequest;
    final int batches = (withImages.length / batchSize).ceil();

    final Map<int, ExamPage> detected = <int, ExamPage>{};
    final Map<String, HandwritingReading> readings =
        <String, HandwritingReading>{};
    final List<String> warnings = <String>[];

    for (int batch = 0; batch < batches; batch++) {
      cancel?.throwIfCancelled();
      final List<ExamPage> slice = withImages.sublist(
        batch * batchSize,
        (batch * batchSize + batchSize).clamp(0, withImages.length),
      );
      onProgress?.call(
        'Analysing page${slice.length == 1 ? '' : 's'} '
        '${slice.map((ExamPage p) => p.pageNumber).join(', ')} with the vision '
        'model…',
        batches == 0 ? 1 : batch / batches,
      );

      final List<ContentPart> parts = <ContentPart>[
        TextPart(
          'Analyse these ${slice.length} page image(s). Return one entry per '
          'page, using the page_index printed before each image.',
        ),
      ];
      for (int index = 0; index < slice.length; index++) {
        final Uint8List? bytes = await _read(_imageFor(slice[index]));
        if (bytes == null) continue;
        parts.add(
          TextPart('page_index $index (page ${slice[index].pageNumber} of the '
              'booklet):'),
        );
        parts.add(ImagePart(bytes, mimeType: _mimeFor(_imageFor(slice[index]))));
      }

      final ModelResponse response = await _client.requestJson(
        ModelRequest(
          purpose: 'page analysis',
          systemInstruction: systemPrompt,
          parts: parts,
          schema: schema,
          maxTokens: 16000 * slice.length,
          effort: 'low',
          truncationHint: 'A page analysis was cut short by the output limit. '
              'Lower EXAM_CORRECTOR_PAGES_PER_REQUEST.',
          refusalMessage: 'The vision model declined to analyse these pages.',
        ),
        models: _config.chainFor(_config.effectiveVisionModel),
        onProgress: (String message) => onProgress?.call(message, batch / batches),
        cancel: cancel,
      );

      final JsonMap? payload = readMap(response.payload);
      for (final JsonMap entry
          in readObjects(payload?['pages'], (JsonMap m) => m)) {
        final int? index = readInt(entry['page_index']);
        if (index == null || index < 0 || index >= slice.length) continue;
        final ExamPage page = slice[index];
        final ({List<PageRegion> regions, Map<String, HandwritingReading> readings})
            parsed = parsePage(page, entry, engine: response.model);
        readings.addAll(parsed.readings);
        detected[page.pageNumber] = page.copyWith(
          regions: parsed.regions,
          detector: fingerprint,
          isBlank: (readBool(entry['is_blank']) ?? false) && parsed.regions.isEmpty,
        );
      }

      for (final ExamPage page in slice) {
        if (!detected.containsKey(page.pageNumber)) {
          warnings.add(
            'Page ${page.pageNumber}: the vision model returned no analysis.',
          );
        }
      }
    }

    onProgress?.call('Page analysis finished.', 1);
    return RegionDetection(
      pages: <ExamPage>[
        for (final ExamPage page in pages)
          detected[page.pageNumber] ?? page.copyWith(regions: const <PageRegion>[]),
      ],
      readings: readings,
      warnings: warnings,
    );
  }

  /// Turns one page of the model's answer into regions and readings.
  static ({List<PageRegion> regions, Map<String, HandwritingReading> readings})
      parsePage(ExamPage page, JsonMap entry, {String engine = ''}) {
    final List<JsonMap> raw = readObjects(entry['regions'], (JsonMap m) => m);
    final List<PageRegion> regions = <PageRegion>[];
    final Map<String, HandwritingReading> readings =
        <String, HandwritingReading>{};

    String idAt(int index) => '${page.pageId}:v$index';

    for (int index = 0; index < raw.length; index++) {
      final JsonMap item = raw[index];
      final NormalizedBox? box = NormalizedBox.fromBox2d(item['box_2d']);
      if (box == null) continue;

      final RegionType type = RegionType.fromWire(item['type']);
      final String text = readRawString(item['text'])?.trim() ?? '';
      final int? parent = readInt(item['parent_index']);
      final String regionId = idAt(index);

      regions.add(
        PageRegion(
          regionId: regionId,
          pageId: page.pageId,
          pageNumber: page.pageNumber,
          type: type,
          box: box,
          confidence: readConfidence(item['confidence'], orElse: 0.5),
          readingOrder: readInt(item['reading_order']) ?? index,
          origin: RegionOrigin.vision,
          parentRegionId: parent != null && parent >= 0 && parent < raw.length
              ? idAt(parent)
              : null,
          detectedLabel: readString(item['label']),
          detectedText: text.isEmpty ? null : text,
        ),
      );

      if (text.isNotEmpty && (type.isTextual || type == RegionType.equation)) {
        readings[regionId] = readingFrom(text, item['uncertain_words'], engine);
      }
    }

    // Reading order as the model gave it, renumbered from zero without gaps.
    regions.sort((PageRegion a, PageRegion b) =>
        a.readingOrder.compareTo(b.readingOrder));
    return (
      regions: <PageRegion>[
        for (int i = 0; i < regions.length; i++)
          regions[i].copyWith(readingOrder: i),
      ],
      readings: readings,
    );
  }

  /// The model's transcription as a reading, with its doubts located.
  static HandwritingReading readingFrom(
    String text,
    Object? uncertainWords,
    String engine, {
    bool? crossedOut,
  }) {
    final List<UncertainSpan> spans = <UncertainSpan>[];
    int searchFrom = 0;
    for (final JsonMap word in readObjects(uncertainWords, (JsonMap m) => m)) {
      final String? value = readString(word['text']);
      if (value == null) continue;
      int start = text.indexOf(value, searchFrom);
      if (start < 0) start = text.indexOf(value);
      spans.add(
        UncertainSpan(
          text: value,
          confidence: readConfidence(word['confidence'], orElse: 0.5),
          start: start < 0 ? null : start,
          end: start < 0 ? null : start + value.length,
        ),
      );
      if (start >= 0) searchFrom = start + value.length;
    }

    const String illegible = '[illegible]';
    int index = text.indexOf(illegible);
    while (index >= 0) {
      spans.add(
        UncertainSpan(
          text: illegible,
          confidence: 0,
          start: index,
          end: index + illegible.length,
        ),
      );
      index = text.indexOf(illegible, index + illegible.length);
    }

    final bool whollyIllegible =
        text.replaceAll(illegible, '').trim().isEmpty;
    final double lowest = spans.isEmpty
        ? 0.95
        : spans
            .map((UncertainSpan s) => s.confidence)
            .reduce((double a, double b) => a < b ? a : b);

    return HandwritingReading(
      source: ReadingSource.vision,
      text: text,
      // A vision model's self-reported confidence is poorly calibrated, so it
      // is not used directly: a clean reading scores high, and a reading with
      // doubts scores its least certain word, floored so one doubtful word
      // does not read as an unreadable region.
      confidence: whollyIllegible
          ? 0
          : spans.isEmpty
              ? 0.95
              : lowest.clamp(0.35, 0.9),
      engine: engine,
      uncertainSpans: spans,
      illegible: whollyIllegible,
      crossedOut: crossedOut,
    );
  }

  String _imageFor(ExamPage page) =>
      (page.previewImagePath?.isNotEmpty ?? false)
          ? page.previewImagePath!
          : page.imagePath!;

  static String _mimeFor(String path) {
    final String lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/png';
  }

  Future<Uint8List?> _read(String path) async {
    try {
      return await File(path).readAsBytes();
    } on IOException {
      return null;
    }
  }
}
