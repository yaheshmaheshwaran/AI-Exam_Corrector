import 'dart:async';
import 'dart:io';

import 'package:exam_corrector/ai/model_request.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/marking/script/pages.dart';

/// What the reader made of a set of pages.
class PageReadout {
  const PageReadout({
    required this.pages,
    required this.handwriting,
    required this.visuals,
    required this.models,
    this.warnings = const <String>[],
  });

  /// The pages, each with its regions.
  final List<ExamPage> pages;
  final Map<String, HandwritingEvidence> handwriting;
  final Map<String, VisualEvidence> visuals;

  /// Which model read each page, by page number.
  final Map<int, String> models;
  final List<String> warnings;

  EvidenceSet get evidence => EvidenceSet(handwriting: handwriting, visuals: visuals);

  JsonMap toJson() => <String, Object?>{
        'pages': <JsonMap>[for (final ExamPage page in pages) page.toJson()],
        'handwriting': <JsonMap>[for (final HandwritingEvidence e in handwriting.values) e.toJson()],
        'visuals': <JsonMap>[for (final VisualEvidence v in visuals.values) v.toJson()],
        'models': <String, Object?>{for (final MapEntry<int, String> e in models.entries) '${e.key}': e.value},
        'warnings': warnings,
      };

  static PageReadout? fromJson(JsonMap json) {
    final List<ExamPage> pages = readObjects(json['pages'], ExamPage.fromJson);
    if (pages.isEmpty) return null;
    return PageReadout(
      pages: pages,
      handwriting: <String, HandwritingEvidence>{
        for (final HandwritingEvidence e in readObjects(json['handwriting'], HandwritingEvidence.fromJson)) e.regionId: e,
      },
      visuals: <String, VisualEvidence>{
        for (final VisualEvidence v in readObjects(json['visuals'], VisualEvidence.fromJson)) v.regionId: v,
      },
      models: <int, String>{
        for (final MapEntry<String, Object?> e in (readMap(json['models']) ?? const <String, Object?>{}).entries)
          if (int.tryParse(e.key) case final int page) page: readString(e.value) ?? '',
      },
      warnings: readStringList(json['warnings']),
    );
  }
}

/// Stage 3: reads whole pages — handwriting, diagrams, equations, tables —
/// in one pass, and says where each part is on the page.
///
/// Several pages go in each request and several requests run at once, so a
/// 15-page script is read in a few requests. What comes back is mapped into
/// the same regions and evidence the rest of the pipeline, and the screens,
/// already understand.
class PageReader {
  PageReader(
    this._client, {
    required this.models,
    this.pagesPerRequest = 3,
    this.parallel = 3,
    this.uncertainBelow = 0.9,
    this.selfHostedModel,
  });

  final ModelClient _client;

  /// The reader models, first choice first.
  final List<String> models;
  final int pagesPerRequest;

  /// Requests sent at once. Kept below a free tier's per-minute limit.
  final int parallel;

  /// Regions read with less confidence than this get a crop, so the marker
  /// and the teacher can look at the ink itself.
  final double uncertainBelow;

  /// Whether a model runs on our own hardware, where Qwen-class models give
  /// boxes x first. Null treats every model as Gemini-style.
  final bool Function(String model)? selfHostedModel;

  static const String promptVersion = 'page-reader:v4';

  String get fingerprint => '$promptVersion:${models.join(',')}:$pagesPerRequest';

  /// Reads [pages]; crops go into [cropFolder].
  Future<PageReadout> read(
    List<ExamPage> pages, {
    required Directory cropFolder,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) async {
    final List<List<ExamPage>> batches = <List<ExamPage>>[
      for (int start = 0; start < pages.length; start += pagesPerRequest)
        pages.sublist(start, (start + pagesPerRequest).clamp(0, pages.length)),
    ];
    final Map<int, PageResult> results = <int, PageResult>{};
    final List<String> warnings = <String>[];
    int done = 0;

    Future<void> readBatch(List<ExamPage> batch) async {
      final Map<int, PageResult> read = await _readSplitting(batch, cancel: cancel, warnings: warnings);
      results.addAll(read);
      done += batch.length;
      onProgress?.call('Read $done of ${pages.length} pages');
    }

    // A small pool: [parallel] requests in flight, the next starting as one
    // finishes.
    final Iterator<List<ExamPage>> queue = batches.iterator;
    Future<void> worker() async {
      while (true) {
        cancel?.throwIfCancelled();
        if (!queue.moveNext()) return;
        await readBatch(queue.current);
      }
    }

    await Future.wait(<Future<void>>[for (int i = 0; i < parallel.clamp(1, batches.length); i++) worker()]);

    final List<ExamPage> readPages = <ExamPage>[];
    final Map<String, HandwritingEvidence> handwriting = <String, HandwritingEvidence>{};
    final Map<String, VisualEvidence> visuals = <String, VisualEvidence>{};
    final Map<int, String> used = <int, String>{};
    for (final ExamPage page in pages) {
      final PageResult? result = results[page.pageNumber];
      if (result == null) {
        warnings.add('Page ${page.pageNumber} could not be read.');
        readPages.add(page);
        continue;
      }
      final List<PageRegion> regions = await _withCrops(page, result, cropFolder);
      readPages.add(page.copyWith(regions: regions, isBlank: result.blank, detector: result.model));
      handwriting.addAll(result.handwriting);
      visuals.addAll(result.visuals);
      used[page.pageNumber] = result.model;
    }
    return PageReadout(pages: readPages, handwriting: handwriting, visuals: visuals, models: used, warnings: warnings);
  }

  /// One batch, split into single pages when the answer was cut off or a
  /// page was left out.
  Future<Map<int, PageResult>> _readSplitting(
    List<ExamPage> batch, {
    required List<String> warnings,
    CancellationToken? cancel,
  }) async {
    try {
      final Map<int, PageResult> read = await _readOnce(batch, cancel: cancel);
      final List<ExamPage> missing = <ExamPage>[
        for (final ExamPage page in batch)
          if (!read.containsKey(page.pageNumber)) page,
      ];
      if (missing.isEmpty || batch.length == 1) return read;
      for (final ExamPage page in missing) {
        read.addAll(await _readSplitting(<ExamPage>[page], cancel: cancel, warnings: warnings));
      }
      return read;
    } on CorrectionException catch (error) {
      if (!error.truncated || batch.length == 1) rethrow;
      final Map<int, PageResult> read = <int, PageResult>{};
      for (final ExamPage page in batch) {
        read.addAll(await _readSplitting(<ExamPage>[page], cancel: cancel, warnings: warnings));
      }
      return read;
    }
  }

  Future<Map<int, PageResult>> _readOnce(List<ExamPage> batch, {CancellationToken? cancel}) async {
    final bool xFirst = selfHostedModel?.call(models.first) ?? false;
    final List<ContentPart> parts = <ContentPart>[];
    for (int index = 0; index < batch.length; index++) {
      final ExamPage page = batch[index];
      final String? path = page.previewImagePath ?? page.imagePath;
      if (path == null) throw PipelineException('Page ${page.pageNumber} has no image.', stage: 'reading');
      parts
        ..add(TextPart('Page index $index:'))
        ..add(ImagePart(await File(path).readAsBytes(), mimeType: 'image/jpeg'));
    }
    final ModelResponse response = await _client.requestJson(
      ModelRequest(
        purpose: 'page reading',
        systemInstruction: promptFor(xFirst: xFirst),
        parts: parts,
        schema: schema,
        maxTokens: 12000 * batch.length,
        effort: 'low',
        truncationHint: 'The pages had more writing than fits in one answer.',
      ),
      models: models,
      cancel: cancel,
    );
    final bool modelXFirst = selfHostedModel?.call(response.model) ?? false;
    final List<JsonMap> answered = <JsonMap>[
      for (final Object? item in readList(readMap(response.payload)?['pages']))
        if (readMap(item) case final JsonMap json) json,
    ];
    // Pages are matched by the index they were introduced with; when the
    // model numbered them its own way (from 1, or by the booklet's page
    // number) but answered every page, they are matched in order.
    final Set<int> indices = <int>{
      for (final JsonMap json in answered)
        if (readInt(json['page_index']) case final int index when index >= 0 && index < batch.length) index,
    };
    final bool byPosition = indices.length != answered.length && answered.length == batch.length;
    final Map<int, PageResult> results = <int, PageResult>{};
    for (int position = 0; position < answered.length; position++) {
      final JsonMap json = answered[position];
      final int? index = byPosition ? position : readInt(json['page_index']);
      if (index == null || index < 0 || index >= batch.length) continue;
      final ExamPage page = batch[index];
      results[page.pageNumber] = parsePage(json, page, model: response.model, xFirst: modelXFirst);
    }
    return results;
  }

  /// Crops for what the marker or the teacher should see as ink: every
  /// drawing, and writing read with little confidence.
  Future<List<PageRegion>> _withCrops(ExamPage page, PageResult result, Directory folder) async {
    final String? image = page.imagePath;
    if (image == null) return result.regions;
    final PageCropper cropper = PageCropper(image);
    final List<PageRegion> regions = <PageRegion>[];
    for (final PageRegion region in result.regions) {
      final bool wanted =
          region.type.isVisual || (result.handwriting[region.regionId]?.confidence ?? 1) < uncertainBelow;
      if (!wanted) {
        regions.add(region);
        continue;
      }
      final String? crop = await cropper.crop(region.box, _cropFile(folder, region.regionId));
      regions.add(region.copyWith(cropPath: () => crop));
    }
    return regions;
  }

  static String _cropFile(Directory folder, String regionId) =>
      '${folder.path}${Platform.pathSeparator}${regionId.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_')}.jpg';

  // --------------------------------------------------------------------------
  // What the model is asked, and what its answer is turned into
  // --------------------------------------------------------------------------

  static const List<String> types = <String>[
    'question_number',
    'handwritten_answer',
    'diagram',
    'graph',
    'table',
    'equation',
    'crossed_out',
    'margin_note',
    'printed_text',
    'header',
    'footer',
  ];

  static const List<String> strikeKinds = <String>['none', 'student_line', 'scribble', 'examiner_mark', 'unsure'];

  static const String _boxRuleYFirst = '- box_2d is [ymin, xmin, ymax, xmax], scaled 0 to 1000 relative to the image.';
  static const String _boxRuleXFirst =
      '- box_2d is [xmin, ymin, xmax, ymax] — left, top, right, bottom — scaled 0 to 1000 relative to the image.';

  static String promptFor({required bool xFirst}) =>
      xFirst ? systemPrompt.replaceFirst(_boxRuleYFirst, _boxRuleXFirst) : systemPrompt;

  static const String systemPrompt = '''
You read scanned pages of a student's handwritten exam answer booklet and turn each page into structured text. You describe what the student wrote. You never mark it, judge it or improve it.

Each page image is introduced by its page index (0, 1, 2, …). Return one entry per page with that page_index — not the page number printed on the booklet — and its regions in the order a teacher would read them.

Region types:
- question_number: a question label standing on its own line ("4", "Q4", "2(b)", "iii)").
- handwritten_answer: the student's handwritten prose, points or working.
- diagram: a drawing, flowchart, block diagram, circuit or labelled figure.
- graph: a plotted graph or chart with axes.
- table: a table drawn or filled in by the student.
- equation: a formula, equation or line of calculation set apart from prose.
- crossed_out: writing the STUDENT struck through (see the crossing-out rule).
- margin_note: a note the student wrote in the margin.
- printed_text: text PRINTED on the booklet in type — printed question wording, instructions, the booklet's own headings. Anything written by hand is never printed_text: a heading the student wrote ("WORKFLOW:", "CONCLUSION:", "Advantages") is part of the answer, so it is handwritten_answer.
- header / footer: printed running headers, page numbers, booklet branding and watermarks.

Rules:
- EXAMINER MARKS ARE NOT THE STUDENT'S WORK. The script may already have been marked, usually in red or maroon, sometimes in another pen: ticks, crosses, long diagonal slashes or curves drawn across answers, underlines, scores and marks ("3", "2½", "4/5", "8", circled numbers, numbers in the margin or at the end of an answer) and comments. Never transcribe any of them, never put them in any region, never describe them as part of a drawing, and never report a score or a mark anywhere.
- Crossing-out rule: when the student has struck through their own writing (a neat line through words, or scribbling over them), make that writing its own crossed_out region, with strike_kind student_line or scribble, and transcribe the struck words if they are legible. An examiner's slash or tick across writing does not cross it out: keep that writing in its normal region with strike_kind none. Examiners tick with a diagonal or curved stroke through one or two words, often running past them and repeated down the page; students cross out with a horizontal line through the word or by scribbling over it. Never put a word in a crossed_out region if you also transcribed it in another region. If you cannot tell whose stroke it is, keep the writing in its normal region with strike_kind unsure. Every other region has strike_kind none.
- Start a new region at every question label the student wrote. Never let one region run from the end of one answer into the next question. Give the label exactly as written in label; otherwise label is "".
- A numbered or lettered list inside an answer — the student's own points 1, 2, 3 or i, ii, iii, or a), b) under one question — is part of that answer, not a question label, unless it clearly starts the next question of the paper.
- lines: transcribe every written line of a textual region verbatim, one string per line on the page. Never correct spelling, grammar, arithmetic, notation or terminology, and never complete an answer. Keep the student's own numbering, symbols and abbreviations. Write [illegible] for a word you cannot read rather than guessing.
- Answer grids: when the booklet prints a box or brackets for the student to fill in — a multiple-choice option "[ b ]", a blank "Answer: ____", a table cell — transcribe what the student wrote in it together with the printed words around it, e.g. "[b] Answer: A dedicated application." The letter the student wrote in the brackets is their chosen option and must never be left out.
- uncertain_words: every word in lines you are not sure you read correctly, spelled exactly as in lines.
- illegible: true when most of the region cannot be read.
- Keep each diagram, graph, table and equation as one region. Text written inside or beside a drawing belongs to the drawing, not to a separate region. Its box_2d must enclose all of it: every box, arrow, branch and label — when unsure, make the box larger rather than smaller.
- Diagrams: fill diagram. diagram_kind is flowchart, block, circuit, figure or other. For a flowchart or block diagram: list every box as a node (a short id n1, n2, …, its text verbatim, its shape: process, decision, terminal, io, block or other); trace every connector from end to end and record it as an edge between the two nodes it joins, with any text on it as label; for each edge look at both ends for an arrowhead — arrow is forward when the head is at "to", backward when at "from", both, or none for a plain line. Never infer a direction from what a correct diagram would show. For a figure, list components, labels, and relationships (what each pointer or arrow connects). description: one or two sentences on what the drawing shows. Report only what is drawn; never add a part a correct answer would have.
- Graphs: fill graph — x_axis and y_axis as labelled, plotted_elements, approximate_values as "x → y", trend in one sentence.
- Tables: fill table — rows of cell text, header row first, "" for an empty cell.
- Equations: fill equation — plain_text exactly as written, and latex.
$_boxRuleYFirst
- confidence: how sure you are of the region's type and extent, from 0 to 1.
- is_blank: true when the student wrote nothing on the page.
''';

  static const Map<String, Object?> _string = <String, Object?>{'type': 'string'};
  static const Map<String, Object?> _strings = <String, Object?>{'type': 'array', 'items': _string};

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
                  'type': <String, Object?>{'type': 'string', 'enum': types},
                  'box_2d': <String, Object?>{
                    'type': 'array',
                    'items': <String, Object?>{'type': 'integer'},
                  },
                  'label': _string,
                  'lines': _strings,
                  'uncertain_words': _strings,
                  'illegible': <String, Object?>{'type': 'boolean'},
                  'strike_kind': <String, Object?>{'type': 'string', 'enum': strikeKinds},
                  'confidence': <String, Object?>{'type': 'number'},
                  'diagram': <String, Object?>{
                    'type': 'object',
                    'properties': <String, Object?>{
                      'diagram_kind': _string,
                      'description': _string,
                      'nodes': <String, Object?>{
                        'type': 'array',
                        'items': <String, Object?>{
                          'type': 'object',
                          'properties': <String, Object?>{'id': _string, 'text': _string, 'shape': _string},
                          'required': <String>['id', 'text'],
                        },
                      },
                      'edges': <String, Object?>{
                        'type': 'array',
                        'items': <String, Object?>{
                          'type': 'object',
                          'properties': <String, Object?>{
                            'from': _string,
                            'to': _string,
                            'label': _string,
                            'arrow': <String, Object?>{
                              'type': 'string',
                              'enum': <String>['forward', 'backward', 'both', 'none'],
                            },
                          },
                          'required': <String>['from', 'to'],
                        },
                      },
                      'components': _strings,
                      'labels': _strings,
                      'relationships': _strings,
                    },
                  },
                  'graph': <String, Object?>{
                    'type': 'object',
                    'properties': <String, Object?>{
                      'description': _string,
                      'x_axis': _string,
                      'y_axis': _string,
                      'plotted_elements': _strings,
                      'approximate_values': _strings,
                      'trend': _string,
                    },
                  },
                  'table': <String, Object?>{
                    'type': 'object',
                    'properties': <String, Object?>{
                      'description': _string,
                      'rows': <String, Object?>{'type': 'array', 'items': _strings},
                    },
                  },
                  'equation': <String, Object?>{
                    'type': 'object',
                    'properties': <String, Object?>{'plain_text': _string, 'latex': _string},
                  },
                },
                'required': <String>['type', 'box_2d', 'lines'],
              },
            },
          },
          'required': <String>['page_index', 'regions'],
        },
      },
    },
    'required': <String>['pages'],
  };

  /// The reading's confidence, from how much of it the model was unsure of:
  /// a model's own score says little, but a word it flagged is a word to
  /// check.
  static double readingConfidence({required int words, required int uncertain, required int illegibleMarks, bool illegible = false}) {
    if (illegible) return 0.2;
    if (words == 0) return illegibleMarks > 0 ? 0.3 : 0.9;
    final double share = (uncertain + 2 * illegibleMarks) / words;
    return (0.97 - 0.8 * share - 0.05 * illegibleMarks).clamp(0.2, 0.97);
  }

  /// One page of the model's answer as regions and evidence.
  static PageResult parsePage(JsonMap json, ExamPage page, {required String model, bool xFirst = false}) {
    final List<PageRegion> regions = <PageRegion>[];
    final Map<String, HandwritingEvidence> handwriting = <String, HandwritingEvidence>{};
    final Map<String, VisualEvidence> visuals = <String, VisualEvidence>{};
    final List<Object?> items = readList(json['regions']);

    for (final Object? item in items) {
      final JsonMap? region = readMap(item);
      if (region == null) continue;
      final NormalizedBox? box = xFirst ? NormalizedBox.fromXyxy(region['box_2d']) : NormalizedBox.fromBox2d(region['box_2d']);
      if (box == null) continue;
      final String id = '${page.pageId}:v2-${regions.length}';
      final String strike = readString(region['strike_kind']) ?? 'none';
      RegionType type = RegionType.fromWire(region['type']);
      // An examiner's stroke never crosses the student's writing out.
      if (type == RegionType.crossedOut && (strike == 'examiner_mark' || strike == 'none')) {
        type = RegionType.handwrittenAnswer;
      }
      final bool studentStruck = type == RegionType.crossedOut;
      final bool? crossedOut = studentStruck || strike == 'unsure' ? true : (strike == 'none' ? false : null);

      final List<String> lines = <String>[
        for (final Object? line in readList(region['lines']))
          if (readRawString(line) case final String text) clean(text),
      ]..removeWhere((String line) => line.trim().isEmpty);
      final String text = lines.join('\n');
      final String? label = readString(region['label']);
      final double confidence = readDouble(region['confidence'])?.clamp(0.0, 1.0) ?? 0.8;

      regions.add(PageRegion(
        regionId: id,
        pageId: page.pageId,
        pageNumber: page.pageNumber,
        type: type,
        box: box,
        confidence: confidence,
        readingOrder: regions.length,
        origin: RegionOrigin.vision,
        detectedLabel: (label == null || label.isEmpty) ? null : label,
        detectedText: text.isEmpty ? null : text,
      ));

      if (type.isVisual) {
        visuals[id] = _visual(id, type, region, confidence, text);
      } else {
        final List<String> uncertain = readStringList(region['uncertain_words']);
        final bool illegible = readBool(region['illegible']) ?? false;
        final int words = text.split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).length;
        final int marks = '[illegible]'.allMatches(text).length;
        handwriting[id] = HandwritingEvidence(
          regionId: id,
          readings: <HandwritingReading>[
            HandwritingReading(
              source: ReadingSource.vision,
              text: text,
              confidence: readingConfidence(words: words, uncertain: uncertain.length, illegibleMarks: marks, illegible: illegible),
              engine: model,
              uncertainSpans: spansOf(text, uncertain),
              illegible: illegible,
              crossedOut: crossedOut,
            ),
          ],
        );
      }
    }
    _dropRepeatedStrikes(regions, handwriting);
    return PageResult(
      regions: regions,
      handwriting: handwriting,
      visuals: visuals,
      blank: (readBool(json['is_blank']) ?? false) && regions.every((PageRegion r) => !r.type.isAnswerContent),
      model: model,
    );
  }

  /// Removes a crossed-out region whose words the model also kept in the
  /// student's answer on the same page. Writing cannot be both kept and
  /// struck; it is an examiner's tick across the words the model took for a
  /// crossing-out, and saying it was struck would cost the student marks.
  static void _dropRepeatedStrikes(List<PageRegion> regions, Map<String, HandwritingEvidence> handwriting) {
    String words(String text) => text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    final String kept = <String>[
      for (final PageRegion region in regions)
        if (region.type != RegionType.crossedOut) words(handwriting[region.regionId]?.rawText ?? ''),
    ].join(' ');
    final Set<String> repeated = <String>{
      for (final PageRegion region in regions)
        if (region.type == RegionType.crossedOut)
          if (words(handwriting[region.regionId]?.rawText ?? '') case final String struck
              when struck.isNotEmpty && ' $kept '.contains(' $struck '))
            region.regionId,
    };
    if (repeated.isEmpty) return;
    regions.removeWhere((PageRegion region) => repeated.contains(region.regionId));
    repeated.forEach(handwriting.remove);
    for (int index = 0; index < regions.length; index++) {
      regions[index] = regions[index].copyWith(readingOrder: index);
    }
  }

  /// [line] without control characters (a model now and then wraps a letter
  /// in them) or runs of spaces.
  static String clean(String line) =>
      line.replaceAll(RegExp(r'[\x00-\x08\x0B-\x1F\x7F]'), '').replaceAll(RegExp(r'[ \t]+'), ' ').trim();

  /// Where each uncertain word sits in [text], in order, so the screens can
  /// mark it.
  static List<UncertainSpan> spansOf(String text, List<String> words) {
    final List<UncertainSpan> spans = <UncertainSpan>[];
    int from = 0;
    for (final String word in words) {
      final String needle = word.trim();
      if (needle.isEmpty) continue;
      int at = text.indexOf(needle, from);
      if (at < 0) at = text.indexOf(needle);
      if (at < 0) {
        spans.add(UncertainSpan(text: needle, confidence: 0.5));
        continue;
      }
      spans.add(UncertainSpan(text: needle, confidence: 0.5, start: at, end: at + needle.length));
      from = at + needle.length;
    }
    return spans;
  }

  static VisualEvidence _visual(String id, RegionType type, JsonMap region, double confidence, String text) {
    switch (type) {
      case RegionType.graph:
        final JsonMap graph = readMap(region['graph']) ?? const <String, Object?>{};
        return GraphEvidence(
          regionId: id,
          description: readRawString(graph['description']) ?? text,
          confidence: confidence,
          xAxis: readRawString(graph['x_axis']) ?? '',
          yAxis: readRawString(graph['y_axis']) ?? '',
          plottedElements: readStringList(graph['plotted_elements']),
          approximateValues: readStringList(graph['approximate_values']),
          trend: readRawString(graph['trend']) ?? '',
        );
      case RegionType.table:
        final JsonMap table = readMap(region['table']) ?? const <String, Object?>{};
        return TableEvidence(
          regionId: id,
          description: readRawString(table['description']) ?? '',
          confidence: confidence,
          rows: <List<String>>[
            for (final Object? row in readList(table['rows']))
              <String>[for (final Object? cell in readList(row)) readRawString(cell) ?? ''],
          ],
        );
      case RegionType.equation:
        final JsonMap equation = readMap(region['equation']) ?? const <String, Object?>{};
        final String plain = readRawString(equation['plain_text']) ?? text;
        return EquationEvidence(
          regionId: id,
          description: plain,
          confidence: confidence,
          latex: readRawString(equation['latex']) ?? '',
          plainText: plain,
        );
      default:
        final JsonMap diagram = readMap(region['diagram']) ?? const <String, Object?>{};
        return DiagramEvidence(
          regionId: id,
          description: readRawString(diagram['description']) ?? text,
          confidence: confidence,
          diagramKind: readRawString(diagram['diagram_kind']) ?? '',
          nodes: readObjects(diagram['nodes'], DiagramNode.fromJson),
          edges: readObjects(diagram['edges'], DiagramEdge.fromJson),
          components: readStringList(diagram['components']),
          labels: readStringList(diagram['labels']),
          relationships: readStringList(diagram['relationships']),
        );
    }
  }
}

/// Whether [model] runs on our own hardware, by its provider.
bool Function(String model) selfHostedIn(Providers providers) =>
    (String model) => providers.of(model)?.selfHosted ?? false;

/// One page as read: its regions and their evidence.
class PageResult {
  const PageResult({
    required this.regions,
    required this.handwriting,
    required this.visuals,
    required this.blank,
    required this.model,
  });

  final List<PageRegion> regions;
  final Map<String, HandwritingEvidence> handwriting;
  final Map<String, VisualEvidence> visuals;
  final bool blank;
  final String model;
}
