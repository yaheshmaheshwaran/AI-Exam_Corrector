import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/layout/hybrid_region_detector.dart';
import 'package:exam_corrector/pipeline/layout/local_region_detector.dart';
import 'package:exam_corrector/pipeline/layout/text_layer_region_detector.dart';
import 'package:exam_corrector/pipeline/layout/vision_region_detector.dart';
import 'package:exam_corrector/pipeline/questions/model_question_paper_extractor.dart';
import 'package:exam_corrector/pipeline/questions/question_paper_parser.dart';
import 'package:exam_corrector/pipeline/recognition/ensemble_handwriting_recognizer.dart';
import 'package:exam_corrector/pipeline/recognition/text_similarity.dart';
import 'package:exam_corrector/pipeline/visual/vision_visual_analyzer.dart';
import 'package:exam_corrector/pipeline/visual/visual_evidence_engine.dart';
import 'package:exam_corrector/services/ai/model_client.dart';
import 'package:exam_corrector/services/ocr/sidecar_client.dart';
import 'package:exam_corrector/services/ocr/sidecar_process_service.dart';

import 'pipeline_fakes.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('engines'));
  tearDown(() => dir.delete(recursive: true));

  Future<ExamPage> imagePage(int number) async {
    final File image = File('${dir.path}/p$number.jpg')..writeAsBytesSync(<int>[1, 2, 3]);
    return page(number, image: image.path);
  }

  group('vision page analysis', () {
    test('turns the model\'s regions into page regions and readings', () {
      final ExamPage p = page(1);
      final ({List<PageRegion> regions, Map<String, HandwritingReading> readings}) parsed =
          VisionRegionDetector.parsePage(p, <String, Object?>{
        'page_index': 0,
        'is_blank': false,
        'regions': <Object?>[
          <String, Object?>{
            'type': 'diagram', 'box_2d': <int>[400, 100, 700, 900], 'reading_order': 2,
            'label': '', 'text': '', 'uncertain_words': <Object?>[], 'confidence': 0.9, 'parent_index': -1,
          },
          <String, Object?>{
            'type': 'handwritten_answer', 'box_2d': <int>[100, 100, 300, 900], 'reading_order': 1,
            'label': 'Q4', 'text': 'The chloroplost absorbs [illegible] light',
            'uncertain_words': <Object?>[<String, Object?>{'text': 'chloroplost', 'confidence': 0.4}],
            'confidence': 0.8, 'parent_index': -1,
          },
          <String, Object?>{
            'type': 'label', 'box_2d': <int>[450, 200, 480, 300], 'reading_order': 3,
            'label': '', 'text': 'nucleus', 'uncertain_words': <Object?>[], 'confidence': 0.7, 'parent_index': 0,
          },
          <String, Object?>{
            'type': 'question_number', 'box_2d': <int>[0, 0, 0, 0], 'reading_order': 0,
            'label': '5', 'text': '5', 'uncertain_words': <Object?>[], 'confidence': 0.9, 'parent_index': -1,
          },
        ],
      }, engine: 'vision-model');

      // The empty box is refused; the rest are in reading order.
      expect(parsed.regions.map((PageRegion r) => r.type), <RegionType>[
        RegionType.handwrittenAnswer,
        RegionType.diagram,
        RegionType.label,
      ]);
      final PageRegion answer = parsed.regions.first;
      expect(answer.detectedLabel, 'Q4');
      expect(answer.origin, RegionOrigin.vision);
      expect(answer.box.y, closeTo(0.1, 1e-9));
      expect(parsed.regions[2].parentRegionId, parsed.regions[1].regionId);

      final HandwritingReading reading = parsed.readings[answer.regionId]!;
      expect(reading.text, 'The chloroplost absorbs [illegible] light', reason: 'verbatim, never corrected');
      expect(reading.uncertainSpans.map((UncertainSpan s) => s.text),
          containsAll(<String>['chloroplost', '[illegible]']));
      expect(reading.uncertainSpans.first.start, 4);
      expect(reading.confidence, lessThan(0.5));
      expect(parsed.readings.containsKey(parsed.regions[1].regionId), isFalse,
          reason: 'diagrams are analysed, not transcribed');
    });

    test('a wholly illegible region is marked so, not guessed at', () {
      final HandwritingReading reading =
          VisionRegionDetector.readingFrom('[illegible] [illegible]', const <Object?>[], 'm');
      expect(reading.illegible, isTrue);
      expect(reading.confidence, 0);
    });

    test('sends pages in batches, previews first, and uses the vision model', () async {
      final List<ExamPage> pages = <ExamPage>[for (int i = 1; i <= 3; i++) await imagePage(i)];
      final FakeModelClient client = FakeModelClient((ModelRequest r, List<String> models) {
        final int count = r.imageCount;
        return <String, Object?>{
          'pages': <Object?>[
            for (int i = 0; i < count; i++)
              <String, Object?>{'page_index': i, 'is_blank': false, 'regions': <Object?>[
                <String, Object?>{
                  'type': 'handwritten_answer', 'box_2d': <int>[100, 100, 200, 900], 'reading_order': 0,
                  'label': '', 'text': 'answer', 'uncertain_words': <Object?>[], 'confidence': 0.9, 'parent_index': -1,
                },
              ]},
          ],
        };
      });
      final AppConfig config = pipelineConfig.copyWith(
        pagesPerVisionRequest: 2,
        visionModel: () => 'vision-model',
      );

      final RegionDetection result = await VisionRegionDetector(client, () => config)
          .detect(document(pages), pages);

      expect(client.requests.map((ModelRequest r) => r.imageCount), <int>[2, 1]);
      expect(result.pages.every((ExamPage p) => p.regions.length == 1), isTrue);
      expect(result.readings, hasLength(3));
    });
  });

  group('hybrid region detection', () {
    test('sends only the pages local analysis could not explain', () async {
      final List<ExamPage> pages = <ExamPage>[await imagePage(1), await imagePage(2)];
      final _Local local = _Local(needsVision: <int>{2});
      final FakeModelClient client = FakeModelClient((ModelRequest r, List<String> m) => <String, Object?>{
            'pages': <Object?>[
              <String, Object?>{'page_index': 0, 'is_blank': false, 'regions': <Object?>[
                <String, Object?>{
                  'type': 'diagram', 'box_2d': <int>[100, 100, 800, 900], 'reading_order': 0,
                  'label': '', 'text': '', 'uncertain_words': <Object?>[], 'confidence': 0.9, 'parent_index': -1,
                },
              ]},
            ],
          });

      final RegionDetection result = await HybridRegionDetector(
        local: local,
        vision: VisionRegionDetector(client, () => pipelineConfig),
      ).detect(document(pages), pages);

      expect(client.requests.single.imageCount, 1);
      expect(result.pages[0].regions.single.origin, RegionOrigin.local);
      expect(result.pages[1].regions.single.type, RegionType.diagram);
    });

    test('without an API key, local analysis stands and the teacher is told', () async {
      final List<ExamPage> pages = <ExamPage>[await imagePage(1)];
      final RegionDetection result = await HybridRegionDetector(
        local: _Local(needsVision: <int>{1}),
        vision: VisionRegionDetector(
          FakeModelClient((ModelRequest r, List<String> m) => null, available: false),
          () => pipelineConfig,
        ),
      ).detect(document(pages), pages);

      expect(result.pages.single.regions.single.origin, RegionOrigin.local);
      expect(result.warnings.single, contains('no API key'));
    });

    test('a vision failure falls back to local analysis with a warning', () async {
      final List<ExamPage> pages = <ExamPage>[await imagePage(1)];
      final RegionDetection result = await HybridRegionDetector(
        local: _Local(needsVision: <int>{1}),
        vision: VisionRegionDetector(
          FakeModelClient((ModelRequest r, List<String> m) =>
              const CorrectionException('quota', quotaExhausted: true)),
          () => pipelineConfig,
        ),
      ).detect(document(pages), pages);

      expect(result.pages.single.regions, isNotEmpty);
      expect(result.warnings.single, contains('Local layout analysis was used instead'));
    });

    test('with no local recogniser, the vision model does every page', () async {
      final List<ExamPage> pages = <ExamPage>[await imagePage(1)];
      final RegionDetection result = await HybridRegionDetector(
        local: _Local(unavailable: true),
        vision: VisionRegionDetector(
          FakeModelClient((ModelRequest r, List<String> m) => <String, Object?>{'pages': <Object?>[]}),
          () => pipelineConfig,
        ),
      ).detect(document(pages), pages);

      expect(result.warnings.first, contains('every page was analysed by the vision model'));
    });
  });

  group('handwriting ensemble', () {
    test('the vision reading is primary, and agreement is measured', () {
      final HandwritingEvidence evidence = EnsembleHandwritingRecognizer.combine('r', const <HandwritingReading>[
        HandwritingReading(source: ReadingSource.trocr, text: 'magnification = 2000', confidence: 0.85),
        HandwritingReading(source: ReadingSource.vision, text: 'Magnification = 2000', confidence: 0.8),
      ]);
      expect(evidence.primary!.source, ReadingSource.vision);
      expect(evidence.agreement, closeTo(1, 1e-9));
      expect(evidence.confidence, 0.97, reason: 'two engines agreeing lifts confidence');
      expect(evidence.readings.first.confidence, 0.85, reason: 'readings keep their own scores');
    });

    test('a disagreement is kept, never resolved silently', () {
      final HandwritingEvidence evidence = EnsembleHandwritingRecognizer.combine('r', const <HandwritingReading>[
        HandwritingReading(source: ReadingSource.trocr, text: '= 100 / 0.05 = 200', confidence: 0.93),
        HandwritingReading(source: ReadingSource.vision, text: 'lactic acid builds up', confidence: 0.9),
      ]);
      expect(evidence.enginesDisagree, isTrue);
      expect(evidence.isUncertain(0.5), isTrue);
    });

    test('an unsure second reading is not a disagreement', () {
      // TrOCR on a lone diagram label: wrong, and it knows it.
      final HandwritingEvidence evidence = EnsembleHandwritingRecognizer.combine('r', const <HandwritingReading>[
        HandwritingReading(source: ReadingSource.trocr, text: 'nucieus', confidence: 0.6),
        HandwritingReading(source: ReadingSource.vision, text: 'nucleus', confidence: 0.95),
      ]);
      expect(evidence.agreement, isNull);
      expect(evidence.enginesDisagree, isFalse);
      expect(evidence.readings, hasLength(2), reason: 'the unsure reading is still kept');
    });

    test('a text layer is exact and final', () {
      final HandwritingEvidence evidence = EnsembleHandwritingRecognizer.combine('r', const <HandwritingReading>[
        HandwritingReading(source: ReadingSource.trocr, text: 'x', confidence: 0.99),
        HandwritingReading(source: ReadingSource.textLayer, text: 'typed', confidence: 1),
      ]);
      expect(evidence.rawText, 'typed');
    });

    test('nothing legible is a failure that keeps the region', () {
      final HandwritingEvidence evidence =
          EnsembleHandwritingRecognizer.combine('r', const <HandwritingReading>[], error: 'boom');
      expect(evidence.failed, isTrue);
      expect(evidence.error, 'boom');
    });

    test('asks the vision model only about regions TrOCR was unsure of', () async {
      final _Reader local = _Reader(<String, HandwritingReading>{
        'sure': const HandwritingReading(source: ReadingSource.trocr, text: 'clear', confidence: 0.99),
        'unsure': const HandwritingReading(source: ReadingSource.trocr, text: 'smudge', confidence: 0.5),
      });
      final _Reader vision = _Reader(<String, HandwritingReading>{
        'unsure': const HandwritingReading(source: ReadingSource.vision, text: 'smudged', confidence: 0.9),
      }, source: ReadingSource.vision);

      final Map<String, HandwritingEvidence> result = await EnsembleHandwritingRecognizer(
        local: local,
        vision: vision,
        configProvider: () => pipelineConfig,
      ).recognize(document(<ExamPage>[page(1)]), <PageRegion>[region('sure'), region('unsure')]);

      expect(vision.asked, <String>['unsure']);
      expect(result['sure']!.rawText, 'clear');
      expect(result['unsure']!.rawText, 'smudged');
      expect(result['unsure']!.readings, hasLength(2));
    });

    test('one doubtful word in a confident region still gets a second opinion', () async {
      final _Reader local = _Reader(<String, HandwritingReading>{
        'working': const HandwritingReading(
          source: ReadingSource.trocr,
          text: '50 micrometres - 0.05 mm',
          confidence: 0.93,
          uncertainSpans: <UncertainSpan>[UncertainSpan(text: '-', confidence: 0.24, start: 15, end: 16)],
        ),
      });
      final _Reader vision = _Reader(<String, HandwritingReading>{
        'working': const HandwritingReading(
          source: ReadingSource.vision,
          text: '50 micrometres = 0.05 mm',
          confidence: 0.95,
        ),
      }, source: ReadingSource.vision);

      final Map<String, HandwritingEvidence> result = await EnsembleHandwritingRecognizer(
        local: local,
        vision: vision,
        configProvider: () => pipelineConfig,
      ).recognize(document(<ExamPage>[page(1)]), <PageRegion>[region('working')]);

      expect(vision.asked, <String>['working']);
      expect(result['working']!.rawText, '50 micrometres = 0.05 mm');
      expect(result['working']!.readings.first.text, '50 micrometres - 0.05 mm');
    });

    test('a region with one poorly read line is checked, whatever its average', () async {
      final _Reader local = _Reader(<String, HandwritingReading>{
        'block': const HandwritingReading(
          source: ReadingSource.trocr,
          text: 'The mitochondrin . It makes ATP.\n2 ( a ) Write the word equation',
          confidence: 0.93,
          lines: <RecognizedLine>[
            RecognizedLine(text: 'The mitochondrin . It makes ATP.', confidence: 0.86, box: NormalizedBox.fullPage),
            RecognizedLine(text: '2 ( a ) Write the word equation', confidence: 0.98, box: NormalizedBox.fullPage),
          ],
        ),
      });
      final _Reader vision = _Reader(const <String, HandwritingReading>{}, source: ReadingSource.vision);

      await EnsembleHandwritingRecognizer(
        local: local,
        vision: vision,
        configProvider: () => pipelineConfig.copyWith(ocrConfidenceThreshold: 0.92),
      ).recognize(document(<ExamPage>[page(1)]), <PageRegion>[region('block')]);

      expect(vision.asked, <String>['block']);
    });

    test('keeps the vision layout reading and cross-checks it locally', () async {
      final _Reader local = _Reader(<String, HandwritingReading>{
        'a': const HandwritingReading(source: ReadingSource.trocr, text: 'the nucleus', confidence: 0.9),
      });
      final _Reader vision = _Reader(const <String, HandwritingReading>{}, source: ReadingSource.vision);

      final Map<String, HandwritingEvidence> result = await EnsembleHandwritingRecognizer(
        local: local,
        vision: vision,
        configProvider: () => pipelineConfig,
      ).recognize(
        document(<ExamPage>[page(1)]),
        <PageRegion>[region('a')],
        priorReadings: const <String, HandwritingReading>{
          'a': HandwritingReading(source: ReadingSource.vision, text: 'The nucleus', confidence: 0.95),
        },
      );

      expect(vision.asked, isEmpty);
      expect(result['a']!.readings.map((HandwritingReading r) => r.source),
          <ReadingSource>[ReadingSource.vision, ReadingSource.trocr]);
      expect(result['a']!.agreement, closeTo(1, 1e-9));
    });

    test('a recogniser that is unavailable leaves failed evidence, not a crash', () async {
      final Map<String, HandwritingEvidence> result = await EnsembleHandwritingRecognizer(
        local: _Reader(const <String, HandwritingReading>{}, fail: true),
        vision: null,
        configProvider: () => pipelineConfig,
      ).recognize(document(<ExamPage>[page(1)]), <PageRegion>[region('a')]);

      expect(result['a']!.failed, isTrue);
      expect(result['a']!.error, contains('not installed'));
    });

    test('similarity ignores presentation but not content', () {
      expect(textSimilarity('Magnification = x200', 'magnification=x200'), 1);
      expect(textSimilarity('2000', '200'), lessThan(0.8));
      expect(looksMathematical('= 100 / 0.05'), isTrue);
      expect(looksMathematical('The cell membrane controls entry.'), isFalse);
    });
  });

  group('visual evidence', () {
    VisualTask task(String id, RegionType type) => VisualTask(
          region: region(id, type: type),
          imagePath: '${dir.path}/$id.png',
          questionContext: 'Draw and label an animal cell.',
        );

    setUp(() {
      for (final String id in <String>['d', 'g', 't', 'e']) {
        File('${dir.path}/$id.png').writeAsBytesSync(<int>[1]);
      }
    });

    test('each kind goes to its own analysis, with the question for context', () async {
      final FakeModelClient client = FakeModelClient((ModelRequest r, List<String> m) {
        final String kind = r.purpose.split(' ').first;
        return <String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'index': 0,
              'description': '$kind described',
              'confidence': 0.8,
              if (kind == 'diagram') ...<String, Object?>{'labels': <String>['nucleus'], 'components': <String>[], 'relationships': <String>[], 'relevance': ''},
              if (kind == 'graph') ...<String, Object?>{'x_axis': 'time', 'y_axis': 'rate', 'plotted_elements': <String>[], 'approximate_values': <String>[], 'trend': 'rises', 'labels': <String>[], 'relevance': ''},
              if (kind == 'table') ...<String, Object?>{'rows': <List<String>>[<String>['a', 'b']], 'crossed_out_cells': <String>[], 'relevance': ''},
              if (kind == 'equation') ...<String, Object?>{'latex': r'\frac{1}{2}', 'plain_text': '1/2'},
            },
          ],
        };
      });
      final VisionVisualAnalyzer analyzer = VisionVisualAnalyzer(client, () => pipelineConfig);

      final ({Map<String, VisualEvidence> evidence, List<String> warnings}) result =
          await VisualEvidenceEngine(diagrams: analyzer, graphs: analyzer, tables: analyzer, equations: analyzer)
              .analyze(<VisualTask>[
        task('d', RegionType.diagram),
        task('g', RegionType.graph),
        task('t', RegionType.table),
        task('e', RegionType.equation),
      ]);

      expect(client.requests, hasLength(4));
      expect(client.requests.first.parts.whereType<TextPart>().map((TextPart p) => p.text).join(),
          contains('Draw and label an animal cell.'));
      expect((result.evidence['d']! as DiagramEvidence).labels, <String>['nucleus']);
      expect((result.evidence['g']! as GraphEvidence).trend, 'rises');
      expect((result.evidence['t']! as TableEvidence).rows.single, <String>['a', 'b']);
      expect((result.evidence['e']! as EquationEvidence).latex, r'\frac{1}{2}');
      expect(result.warnings, isEmpty);
    });

    test('runs kinds side by side, but never more than two at once', () async {
      final _Counting counting = _Counting();
      await VisualEvidenceEngine(
        diagrams: counting,
        graphs: counting,
        tables: counting,
        equations: counting,
      ).analyze(<VisualTask>[
        task('d', RegionType.diagram),
        task('g', RegionType.graph),
        task('t', RegionType.table),
        task('e', RegionType.equation),
      ]);
      expect(counting.calls, 4);
      expect(counting.peak, 2);
    });

    test('a failed analysis keeps the image and says why', () async {
      final VisionVisualAnalyzer analyzer = VisionVisualAnalyzer(
        FakeModelClient((ModelRequest r, List<String> m) => const CorrectionException('quota')),
        () => pipelineConfig,
      );

      final ({Map<String, VisualEvidence> evidence, List<String> warnings}) result =
          await VisualEvidenceEngine(diagrams: analyzer).analyze(<VisualTask>[
        task('d', RegionType.diagram),
        task('g', RegionType.graph),
      ]);

      expect(result.evidence['d']!.status, AnalysisStatus.failed);
      expect(result.evidence['d']!.error, 'quota');
      expect(result.evidence['g']!.status, AnalysisStatus.skipped);
      expect(result.warnings.first, contains('images are kept'));
    });
  });

  group('question paper extraction', () {
    test('builds the hierarchy from the model\'s flat list', () {
      final QuestionPaper paper = ModelQuestionPaperExtractor.fromPayload(<String, Object?>{
        'title': 'Physics',
        'stated_total': 6,
        'sections': <Object?>[
          <String, Object?>{'section_id': 'A', 'title': '', 'instructions': 'Answer all.', 'stated_marks': -1},
        ],
        'questions': <Object?>[
          <String, Object?>{'number': '1', 'section_id': 'A', 'text': 'Forces', 'max_marks': -1},
          <String, Object?>{'number': '1(a)', 'section_id': 'A', 'text': 'Define force.', 'max_marks': 2},
          <String, Object?>{'number': '1(b)(i)', 'section_id': 'A', 'text': 'Calculate.', 'max_marks': 3},
          <String, Object?>{'number': '2', 'section_id': 'A', 'text': 'Explain.', 'max_marks': -1},
        ],
      }, documentId: 'qp');

      expect(paper.markable.map((Question q) => q.displayNumber), <String>['1(a)', '1(b)(i)', '2']);
      expect(paper.byId('Q1')!.maximumMarks, 5);
      expect(paper.byId('Q2')!.maximumMarks, isNull);
      expect(paper.warnings.join(), contains('Question 2'));
      expect(paper.sections.single.instructions, 'Answer all.');
    });

    test('keeps a printed mark scheme apart from the wording', () {
      final QuestionPaper paper = ModelQuestionPaperExtractor.fromPayload(<String, Object?>{
        'title': '',
        'stated_total': -1,
        'marking_guidance': ' Ignore spelling. ',
        'sections': <Object?>[],
        'questions': <Object?>[
          <String, Object?>{'number': '1', 'section_id': '', 'text': 'Define osmosis.', 'max_marks': 2, 'mark_scheme': 'Water (1); partially permeable membrane (1)'},
          <String, Object?>{'number': '2', 'section_id': '', 'text': 'Name it.', 'max_marks': 1, 'mark_scheme': ''},
        ],
      }, documentId: 'qp');

      expect(paper.byId('Q1')!.questionText, 'Define osmosis.');
      expect(paper.byId('Q1')!.markScheme, contains('partially permeable'));
      expect(paper.byId('Q2')!.hasMarkScheme, isFalse);
      expect(paper.markingGuidance, 'Ignore spelling.');
      expect(paper.markSchemeCount, 1);
    });

    test('an OR from the model counts one alternative in the totals', () {
      Map<String, Object?> q(String number, num marks) => <String, Object?>{
            'number': number, 'section_id': '', 'text': 'Explain.', 'max_marks': marks, 'mark_scheme': '',
          };
      final QuestionPaper paper = ModelQuestionPaperExtractor.fromPayload(<String, Object?>{
        'title': '',
        'stated_total': 12,
        'marking_guidance': '',
        'choices': <Object?>[
          <String, Object?>{
            'options': <Object?>[
              <String>['11(a)', '11(b)'],
              <String>['11(c)', '11(d)'],
            ],
            'choose': 1,
            'instruction': '',
          },
        ],
        'sections': <Object?>[],
        'questions': <Object?>[
          q('11', -1), q('11(a)', 6), q('11(b)', 6), q('11(c)', 4), q('11(d)', 8),
        ],
      }, documentId: 'qp');

      expect(paper.choices.single.options, <List<String>>[
        <String>['Q11a', 'Q11b'],
        <String>['Q11c', 'Q11d'],
      ]);
      expect(paper.byId('Q11')!.maximumMarks, 12);
      expect(paper.totalMarks, 12);
      expect(paper.warnings, isEmpty);
    });

    test('alternatives worth different marks are reported', () {
      final QuestionPaper paper = ModelQuestionPaperExtractor.fromPayload(<String, Object?>{
        'title': '',
        'stated_total': -1,
        'marking_guidance': '',
        'choices': <Object?>[
          <String, Object?>{'options': <Object?>['1', '2'], 'choose': 1, 'instruction': ''},
        ],
        'sections': <Object?>[],
        'questions': <Object?>[
          <String, Object?>{'number': '1', 'section_id': '', 'text': 'A.', 'max_marks': 10, 'mark_scheme': ''},
          <String, Object?>{'number': '2', 'section_id': '', 'text': 'B.', 'max_marks': 8, 'mark_scheme': ''},
        ],
      }, documentId: 'qp');

      expect(paper.totalMarks, 10);
      expect(paper.warnings.single, contains('carry different marks (10, 8)'));
    });

    test('the model is asked for the printed mark scheme', () {
      final Map<String, Object?> item = ((ModelQuestionPaperExtractor.schema['properties']!
              as Map<String, Object?>)['questions']! as Map<String, Object?>)['items']!
          as Map<String, Object?>;
      expect(item['required'], contains('mark_scheme'));
      expect(ModelQuestionPaperExtractor.systemPrompt, contains('never into text'));
    });

    QuestionPaperSourceData source(String? text) => QuestionPaperSourceData(
          document: const SelectedDocument(
            role: DocumentRole.questionPaper,
            filePath: '/qp.pdf',
            fileName: 'qp.pdf',
            contentHash: 'qp',
            byteCount: 1,
            pageCount: 1,
            source: DocumentSource.textLayer,
          ),
          text: text,
        );

    test('a trustworthy parse spends no request', () async {
      final FakeModelClient client = FakeModelClient((ModelRequest r, List<String> m) => null);
      final QuestionPaper paper = await CompositeQuestionPaperExtractor(
        parser: const HeuristicQuestionPaperParser(),
        model: ModelQuestionPaperExtractor(client, () => pipelineConfig),
      ).extract(source('1 Define osmosis. [2 marks]\n2 Explain diffusion. [3 marks]'));

      expect(client.requests, isEmpty);
      expect(paper.totalMarks, 5);
    });

    test('an untrustworthy parse is checked by the model', () async {
      final FakeModelClient client = FakeModelClient((ModelRequest r, List<String> m) => <String, Object?>{
            'title': '', 'stated_total': -1, 'sections': <Object?>[],
            'questions': <Object?>[
              <String, Object?>{'number': '1', 'section_id': '', 'text': 'Define osmosis.', 'max_marks': 2},
              <String, Object?>{'number': '2', 'section_id': '', 'text': 'Explain diffusion.', 'max_marks': 3},
            ],
          });
      final QuestionPaper paper = await CompositeQuestionPaperExtractor(
        parser: const HeuristicQuestionPaperParser(),
        model: ModelQuestionPaperExtractor(client, () => pipelineConfig),
      ).extract(source('1 Define osmosis. [2 marks]\n2 Explain diffusion.'));

      expect(client.requests, hasLength(1));
      expect(paper.source, QuestionPaperSource.modelText);
      expect(paper.byId('Q2')!.maximumMarks, 3);
    });

    test('a scan with no API key is refused with the remedy', () async {
      await expectLater(
        CompositeQuestionPaperExtractor(
          parser: const HeuristicQuestionPaperParser(),
          model: ModelQuestionPaperExtractor(
            FakeModelClient((ModelRequest r, List<String> m) => null, available: false),
            () => pipelineConfig,
          ),
        ).extract(source(null)),
        throwsA(isA<PipelineException>().having(
          (PipelineException e) => e.message,
          'message',
          contains('add an API key'),
        )),
      );
    });
  });

  test('text-layer lines become blocks split at blank lines', () async {
    final RegionDetection result = await const TextLayerRegionDetector(_Layer())
        .detect(document(<ExamPage>[page(1)], source: DocumentSource.textLayer), <ExamPage>[page(1)]);

    final List<PageRegion> regions = result.pages.single.regions;
    expect(regions.map((PageRegion r) => r.detectedText), <String>[
      '1 Name the organelle\nthat makes ATP. [2 marks]',
      'Answer: The mitochondrion.',
    ]);
    expect(regions.first.lineBoxes, hasLength(2));
    expect(regions.every((PageRegion r) => r.origin == RegionOrigin.textLayer), isTrue);
    expect(result.readings[regions.last.regionId]!.source, ReadingSource.textLayer);
  });

  test('local layout results convert from pixels, keeping parents', () {
    final List<PageRegion> regions = LocalRegionDetector.regionsFrom(page(1), <String, Object?>{
      'width': 1000,
      'height': 1400,
      'regions': <Object?>[
        <String, Object?>{'type': 'diagram', 'box': <int>[100, 140, 500, 700], 'confidence': 0.55, 'reading_order': 0, 'parent': null, 'lines': <Object?>[], 'line_words': <Object?>[]},
        <String, Object?>{'type': 'label', 'box': <int>[200, 300, 100, 28], 'confidence': 0.5, 'reading_order': 1, 'parent': 0,
          'lines': <Object?>[<int>[200, 300, 100, 28]], 'line_words': <Object?>[<Object?>[<int>[200, 300, 100, 28]]]},
      ],
    });
    expect(regions.first.box.x, closeTo(0.1, 1e-9));
    expect(regions.first.box.y, closeTo(0.1, 1e-9));
    expect(regions.last.parentRegionId, regions.first.regionId);
    expect(regions.last.lineWords.single.single.width, closeTo(0.1, 1e-9));
  });

  test('configuration rejects nonsense with the setting\'s name', () {
    expect(() => AppConfig.fromMap(const <String, String>{'EXAM_CORRECTOR_LAYOUT_ENGINE': 'magic'}),
        throwsA(isA<ConfigException>()));
    expect(() => AppConfig.fromMap(const <String, String>{'EXAM_CORRECTOR_REVIEW_THRESHOLD': '1.5'}),
        throwsA(isA<ConfigException>().having((ConfigException e) => e.message, 'message',
            contains('EXAM_CORRECTOR_REVIEW_THRESHOLD'))));
    expect(() => AppConfig.fromMap(const <String, String>{'EXAM_CORRECTOR_API_ENDPOINT': 'ftp://x'}),
        throwsA(isA<ConfigException>()));
    expect(() => AppConfig.fromMap(const <String, String>{'EXAM_CORRECTOR_PAGES_PER_REQUEST': '0'}),
        throwsA(isA<ConfigException>()));

    final AppConfig config = AppConfig.fromMap(const <String, String>{
      'EXAM_CORRECTOR_LAYOUT_ENGINE': 'Vision',
      'EXAM_CORRECTOR_VISION_MODEL': 'eyes',
      'EXAM_CORRECTOR_TIMEOUT_SECONDS': '60',
      'EXAM_CORRECTOR_RETRIES': '4',
      'EXAM_CORRECTOR_MAX_IMAGE_DIM': '1024',
      'EXAM_CORRECTOR_DEBUG': 'true',
      'EXAM_CORRECTOR_CACHE': 'off',
    });
    expect(config.layoutEngine, LayoutEngine.vision);
    expect(config.effectiveVisionModel, 'eyes');
    expect(config.effectiveDiagramModel, 'eyes');
    expect(config.chainFor('eyes').first, 'eyes');
    expect(config.requestTimeout, const Duration(seconds: 60));
    expect(config.retryCount, 4);
    expect(config.maxImageDimension, 1024);
    expect(config.developerMode, isTrue);
    expect(config.cacheEnabled, isFalse);
  });

  group('sidecar client', () {
    test('streams progress and returns the done event; errors name the page', () async {
      final SidecarClient ok = SidecarClient(
        process: SidecarProcessService(
          externalEndpoint: () => SidecarEndpoint(baseUrl: Uri.parse('http://127.0.0.1:1/'), token: 't'),
          client: _answering('{}'),
        ),
        client: _answering('data: {"type":"progress","message":"Rendering page 1 of 2…","fraction":0.5}\n\n'
            'data: {"type":"done","pages":[]}\n\n'),
      );
      final List<String> progress = <String>[];
      final Map<String, Object?> done =
          await ok.stream('render', const <String, Object?>{}, onProgress: (String m, double f) => progress.add(m));
      expect(done['type'], 'done');
      expect(progress, <String>['Rendering page 1 of 2…']);

      final SidecarClient failing = SidecarClient(
        process: SidecarProcessService(
          externalEndpoint: () => SidecarEndpoint(baseUrl: Uri.parse('http://127.0.0.1:1/'), token: 't'),
          client: _answering('{}'),
        ),
        client: _answering('data: {"type":"error","message":"corrupt","page":7}\n\n'),
      );
      await expectLater(
        failing.stream('render', const <String, Object?>{}),
        throwsA(isA<PipelineException>().having((PipelineException e) => e.page, 'page', 7)),
      );
    });
  });
}

class _Layer implements TextLayerReader {
  const _Layer();

  @override
  Future<List<TextLayerPage>> read(String path) async => const <TextLayerPage>[
        TextLayerPage(pageNumber: 1, width: 600, height: 800, lines: <TextLayerLine>[
          TextLayerLine(text: '1 Name the organelle', left: 50, top: 100, width: 300, height: 12),
          TextLayerLine(text: 'that makes ATP. [2 marks]', left: 50, top: 114, width: 300, height: 12),
          TextLayerLine(text: 'Answer: The mitochondrion.', left: 60, top: 150, width: 300, height: 12),
        ]),
      ];
}

/// A local layout stand-in: one handwriting region per page, with a verdict.
class _Local extends LocalRegionDetector {
  _Local({this.needsVision = const <int>{}, this.unavailable = false})
      : super(SidecarClient(process: SidecarProcessService()));

  final Set<int> needsVision;
  final bool unavailable;

  @override
  Future<Map<int, LocalPageLayout>> analyze(
    List<ExamPage> pages, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    if (unavailable) {
      throw const OcrException('not installed', sidecarUnavailable: true);
    }
    return <int, LocalPageLayout>{
      for (final ExamPage p in pages)
        p.pageNumber: LocalPageLayout(
          regions: <PageRegion>[region('${p.pageId}:r0', page: p.pageNumber)],
          needsVision: needsVision.contains(p.pageNumber),
        ),
    };
  }
}

class _Reader implements HandwritingRecognizer {
  _Reader(this.readings, {this.source = ReadingSource.trocr, this.fail = false});

  final Map<String, HandwritingReading> readings;
  final ReadingSource source;
  final bool fail;
  final List<String> asked = <String>[];

  @override
  String get fingerprint => 'reader';

  @override
  Future<Map<String, HandwritingEvidence>> recognize(
    ExamDocument document,
    List<PageRegion> regions, {
    Map<String, HandwritingReading> priorReadings = const <String, HandwritingReading>{},
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    if (fail) throw const OcrException('The recogniser is not installed.');
    asked.addAll(regions.map((PageRegion r) => r.regionId));
    return <String, HandwritingEvidence>{
      for (final PageRegion r in regions)
        if (readings[r.regionId] case final HandwritingReading reading)
          r.regionId: HandwritingEvidence(regionId: r.regionId, readings: <HandwritingReading>[reading]),
    };
  }
}

/// Answers every request — the health check and the stream — with [body].
http.Client _answering(String body) => MockClient.streaming(
      (http.BaseRequest request, http.ByteStream _) async => http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(body)),
        200,
      ),
    );

/// Records how many analyses run at the same time.
class _Counting implements DiagramAnalyzer, GraphAnalyzer, TableAnalyzer, EquationRecognizer {
  int calls = 0;
  int running = 0;
  int peak = 0;

  Future<Map<String, VisualEvidence>> _go(List<VisualTask> tasks) async {
    calls++;
    running++;
    if (running > peak) peak = running;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    running--;
    return const <String, VisualEvidence>{};
  }

  @override
  Future<Map<String, VisualEvidence>> analyzeDiagrams(List<VisualTask> tasks,
          {StageProgress? onProgress, CancellationToken? cancel}) =>
      _go(tasks);

  @override
  Future<Map<String, VisualEvidence>> analyzeGraphs(List<VisualTask> tasks,
          {StageProgress? onProgress, CancellationToken? cancel}) =>
      _go(tasks);

  @override
  Future<Map<String, VisualEvidence>> analyzeTables(List<VisualTask> tasks,
          {StageProgress? onProgress, CancellationToken? cancel}) =>
      _go(tasks);

  @override
  Future<Map<String, VisualEvidence>> recognizeEquations(List<VisualTask> tasks,
          {StageProgress? onProgress, CancellationToken? cancel}) =>
      _go(tasks);
}
