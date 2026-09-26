import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/recognition/ensemble_handwriting_recognizer.dart';
import 'package:exam_corrector/pipeline/recognition/equation_promoter.dart';
import 'package:exam_corrector/pipeline/reconstruction/evidence_answer_reconstructor.dart';

import '../pipeline_fakes.dart';

NormalizedBox line(double y) => NormalizedBox(x: 0.1, y: y, width: 0.6, height: 0.02);

HandwritingEvidence lined(String id, List<String> lines) =>
    HandwritingEvidence(regionId: id, readings: <HandwritingReading>[
      HandwritingReading(
        source: ReadingSource.trocr,
        text: lines.join('\n'),
        confidence: 0.9,
        lines: <RecognizedLine>[
          for (int i = 0; i < lines.length; i++)
            RecognizedLine(text: lines[i], confidence: 0.9, box: line(0.1 + i * 0.03)),
        ],
      ),
    ]);

void main() {
  group('equation promotion', () {
    const EquationPromoter promoter = EquationPromoter();

    test('a run of working inside a paragraph becomes an equation region', () {
      final ExamDocument doc = document(<ExamPage>[page(1, regions: <PageRegion>[region('a')])]);
      final ({ExamDocument document, Map<String, HandwritingEvidence> evidence}) result =
          promoter.promote(doc, <String, HandwritingEvidence>{
        'a': lined('a', <String>[
          'magnification is image over object',
          '= 100 / 0.05',
          '= 2000',
          'so the drawing is larger',
        ]),
      });

      final PageRegion eq = result.document.region('a.eq0')!;
      expect(eq.type, RegionType.equation);
      expect(eq.origin, RegionOrigin.derived);
      expect(eq.parentRegionId, 'a');
      expect(eq.box.y, closeTo(0.13, 1e-9));
      expect(eq.box.bottom, closeTo(0.18, 1e-9));
      expect(result.evidence['a.eq0']!.rawText, '= 100 / 0.05\n= 2000');
      expect(result.document.region('a'), isNotNull, reason: 'the parent keeps its text');
    });

    test('prose is left alone, and so is working the vision model already found', () {
      final ExamDocument prose = document(<ExamPage>[page(1, regions: <PageRegion>[region('a')])]);
      expect(
        promoter.promote(prose, <String, HandwritingEvidence>{
          'a': lined('a', <String>['Osmosis is the movement of water.']),
        }).document.regions,
        hasLength(1),
      );

      final ExamDocument found = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('a'),
          PageRegion(
            regionId: 'v',
            pageId: ExamPage.idFor(docId, 1),
            pageNumber: 1,
            type: RegionType.equation,
            box: line(0.13).union(line(0.16)),
            confidence: 0.9,
            readingOrder: 1,
            origin: RegionOrigin.vision,
          ),
        ]),
      ]);
      expect(
        promoter.promote(found, <String, HandwritingEvidence>{
          'a': lined('a', <String>['text', '= 100 / 0.05', '= 2000']),
        }).document.regions,
        hasLength(2),
      );
    });

    test('without line geometry nothing is guessed', () {
      final ExamDocument doc = document(<ExamPage>[page(1, regions: <PageRegion>[region('a')])]);
      expect(
        promoter.promote(doc, <String, HandwritingEvidence>{
          'a': reading('a', '= 100 / 0.05\n= 2000', source: ReadingSource.vision),
        }).document.regions,
        hasLength(1),
      );
    });

    test('a promoted equation joins its parent\'s answer as visual evidence', () {
      final ExamDocument doc = document(<ExamPage>[page(1, regions: <PageRegion>[region('a')])]);
      final ({ExamDocument document, Map<String, HandwritingEvidence> evidence}) promoted =
          promoter.promote(doc, <String, HandwritingEvidence>{
        'a': lined('a', <String>['working:', '= 100 / 0.05']),
      });
      final Map<String, StudentAnswer> answers =
          const EvidenceAnswerReconstructor(uncertainBelow: 0.8).reconstruct(
        document: promoted.document,
        evidence: EvidenceSet(
          handwriting: promoted.evidence,
          visuals: const <String, VisualEvidence>{
            'a.eq0': EquationEvidence(
              regionId: 'a.eq0',
              description: '',
              confidence: 0.8,
              latex: r'= \frac{100}{0.05}',
            ),
          },
        ),
        alignment: const AlignmentResult(
          segments: <AnswerSegment>[
            AnswerSegment(segmentId: 's', regionIds: <String>['a'], pageNumbers: <int>[1]),
          ],
          alignments: <String, QuestionAlignment>{
            'Q1': QuestionAlignment(
              questionId: 'Q1',
              segmentIds: <String>['s'],
              confidence: 1,
              methods: <AlignmentMethod>[AlignmentMethod.label],
            ),
          },
        ),
        paper: paperOf(<Question>[question('1')]),
      );

      expect(answers['Q1']!.visualRegionIds, <String>['a.eq0']);
      expect(answers['Q1']!.equations.single.latex, r'= \frac{100}{0.05}');
      expect(answers['Q1']!.text, contains('= 100 / 0.05'));
    });
  });

  group('crossed-out work', () {
    HandwritingEvidence withVerdict(String id, bool? struck) => HandwritingEvidence(
          regionId: id,
          readings: <HandwritingReading>[
            const HandwritingReading(source: ReadingSource.trocr, text: 'mitochondria', confidence: 0.9),
            HandwritingReading(
              source: ReadingSource.vision,
              text: 'mitochondria',
              confidence: 0.9,
              crossedOut: struck,
            ),
          ],
          primaryIndex: 1,
        );

    test('a suspected strike the vision model confirms leaves the answer', () {
      expect(
        EvidenceAnswerReconstructor.strikeLikelihood(
          region('x', type: RegionType.crossedOut, confidence: 0.5),
          withVerdict('x', true),
        ),
        0.85,
      );
    });

    test('a suspected strike the vision model rejects stays, unflagged', () {
      expect(
        EvidenceAnswerReconstructor.strikeLikelihood(
          region('x', type: RegionType.crossedOut, confidence: 0.5),
          withVerdict('x', false),
        ),
        0.2,
      );
    });

    test('a strike only the vision model saw is still a strike', () {
      expect(EvidenceAnswerReconstructor.strikeLikelihood(region('x'), withVerdict('x', true)), 0.85);
      expect(EvidenceAnswerReconstructor.strikeLikelihood(region('x'), withVerdict('x', null)), 0);
    });

    test('a suspected strike is always shown to the vision model', () async {
      final List<String> asked = <String>[];
      await EnsembleHandwritingRecognizer(
        local: _Fixed(const HandwritingReading(source: ReadingSource.trocr, text: 'clear', confidence: 0.99)),
        vision: _Fixed(
          const HandwritingReading(
            source: ReadingSource.vision,
            text: 'clear',
            confidence: 0.9,
            crossedOut: true,
          ),
          asked: asked,
        ),
        configProvider: () => pipelineConfig,
      ).recognize(
        document(<ExamPage>[page(1)]),
        <PageRegion>[region('struck', type: RegionType.crossedOut, confidence: 0.5), region('fine')],
      );
      expect(asked, <String>['struck']);
    });

    test('verdicts survive the cache', () {
      expect(HandwritingEvidence.fromJson(withVerdict('x', false).toJson())!.crossedOutVerdict, isFalse);
      expect(HandwritingEvidence.fromJson(reading('y', 't').toJson())!.crossedOutVerdict, isNull);
    });
  });
}

class _Fixed implements HandwritingRecognizer {
  _Fixed(this.reading, {this.asked});

  final HandwritingReading reading;
  final List<String>? asked;

  @override
  String get fingerprint => 'fixed';

  @override
  Future<Map<String, HandwritingEvidence>> recognize(
    ExamDocument document,
    List<PageRegion> regions, {
    Map<String, HandwritingReading> priorReadings = const <String, HandwritingReading>{},
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    asked?.addAll(regions.map((PageRegion r) => r.regionId));
    return <String, HandwritingEvidence>{
      for (final PageRegion r in regions)
        r.regionId: HandwritingEvidence(regionId: r.regionId, readings: <HandwritingReading>[reading]),
    };
  }
}
