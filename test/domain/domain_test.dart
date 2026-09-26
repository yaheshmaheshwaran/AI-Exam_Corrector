import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';

/// Every stage's output goes through JSON on its way to and from the cache.
JsonMap roundTrip(JsonMap json) => jsonDecode(jsonEncode(json)) as JsonMap;

void main() {
  group('geometry', () {
    test('a vision box_2d becomes page fractions', () {
      final NormalizedBox box = NormalizedBox.fromBox2d(<int>[100, 200, 300, 600])!;
      expect(box.x, closeTo(0.2, 1e-9));
      expect(box.y, closeTo(0.1, 1e-9));
      expect(box.width, closeTo(0.4, 1e-9));
      expect(box.height, closeTo(0.2, 1e-9));
    });

    test('reversed or out-of-range corners are repaired, empty boxes refused', () {
      final NormalizedBox box = NormalizedBox.fromBox2d(<int>[300, 600, 100, 1200])!;
      expect(box.right, closeTo(1, 1e-9));
      expect(NormalizedBox.fromBox2d(<int>[100, 100, 100, 100]), isNull);
      expect(NormalizedBox.fromBox2d(<int>[1, 2, 3]), isNull);
    });

    test('is independent of rendering resolution', () {
      final NormalizedBox low = NormalizedBox.fromPixels(
          x: 62, y: 87, width: 124, height: 43, pageWidth: 620, pageHeight: 877);
      final NormalizedBox high = NormalizedBox.fromPixels(
          x: 248, y: 350, width: 496, height: 175, pageWidth: 2480, pageHeight: 3508);
      expect(low.x, closeTo(high.x, 0.001));
      expect(low.width, closeTo(high.width, 0.001));
      expect(high.toPixels(2480, 3508).width, 496);
    });

    test('overlap measures', () {
      const NormalizedBox a = NormalizedBox(x: 0, y: 0, width: 0.5, height: 0.5);
      const NormalizedBox b = NormalizedBox(x: 0.25, y: 0.25, width: 0.5, height: 0.5);
      expect(a.intersectionArea(b), closeTo(0.0625, 1e-9));
      expect(a.coverageBy(b), closeTo(0.25, 1e-9));
      expect(a.union(b).right, closeTo(0.75, 1e-9));
    });
  });

  group('question labels', () {
    test('every way a label is written lands on the same key', () {
      for (final String written in <String>[
        '2(a)', '2 (a)', '2a', '2a)', 'Q2(a)', 'Question 2 (a)', '2.a', '2 ( a )',
      ]) {
        expect(QuestionLabel.parse(written)!.key, '2.a', reason: written);
      }
    });

    test('keeps two levels of part and knows its parent', () {
      final QuestionLabel label = QuestionLabel.parse('3(b)(ii)')!;
      expect(label.parts, <String>['3', 'b', 'ii']);
      expect(label.display, '3(b)(ii)');
      expect(label.questionId, 'Q3bii');
      expect(label.parent!.key, '3.b');
      expect(label.isWithin(QuestionLabel.parse('3')!), isTrue);
      expect(label.isWithin(QuestionLabel.parse('30')!), isFalse);
    });

    test('question 1 is not question 10', () {
      expect(QuestionLabel.parse('10')!.isWithin(QuestionLabel.parse('1')!), isFalse);
    });

    test('only a leading number makes a label', () {
      expect(QuestionLabel.parse('The answer'), isNull);
      expect(QuestionLabel.parse('Answer: 50 micrometres'), isNull);
      expect(QuestionLabel.parse('2 The cell')!.parts, <String>['2']);
    });
  });

  test('a document and its regions survive the cache', () {
    const ExamDocument document = ExamDocument(
      documentId: 'abc',
      role: DocumentRole.answerSheet,
      filePath: '/x.pdf',
      fileName: 'x.pdf',
      source: DocumentSource.mixed,
      pages: <ExamPage>[
        ExamPage(
          pageId: 'abc:p1',
          pageNumber: 1,
          width: 2480,
          height: 3508,
          dpi: 300,
          imagePath: '/p1.png',
          inkCoverage: 0.03,
          detector: 'hybrid',
          regions: <PageRegion>[
            PageRegion(
              regionId: 'abc:p1:v0',
              pageId: 'abc:p1',
              pageNumber: 1,
              type: RegionType.diagram,
              box: NormalizedBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
              confidence: 0.8,
              readingOrder: 3,
              origin: RegionOrigin.vision,
              parentRegionId: 'abc:p1:v9',
              cropPath: '/c.png',
              detectedLabel: 'Q4',
              lineBoxes: <NormalizedBox>[NormalizedBox(x: 0.1, y: 0.2, width: 0.3, height: 0.1)],
              lineWords: <List<NormalizedBox>>[
                <NormalizedBox>[NormalizedBox(x: 0.1, y: 0.2, width: 0.1, height: 0.1)],
              ],
            ),
          ],
        ),
      ],
    );

    final ExamDocument restored = ExamDocument.fromJson(roundTrip(document.toJson()))!;
    final PageRegion region = restored.pages.single.regions.single;
    expect(restored.source, DocumentSource.mixed);
    expect(restored.pages.single.dpi, 300);
    expect(region.type, RegionType.diagram);
    expect(region.origin, RegionOrigin.vision);
    expect(region.box, document.pages.single.regions.single.box);
    expect(region.parentRegionId, 'abc:p1:v9');
    expect(region.detectedLabel, 'Q4');
    expect(region.lineWords.single, hasLength(1));
    expect(restored.region('abc:p1:v0'), isNotNull);
  });

  test('evidence of every kind survives the cache', () {
    const HandwritingEvidence handwriting = HandwritingEvidence(
      regionId: 'r',
      primaryIndex: 1,
      agreement: 0.7,
      teacherText: 'fixed',
      readings: <HandwritingReading>[
        HandwritingReading(source: ReadingSource.trocr, text: 'chloroplost', confidence: 0.6),
        HandwritingReading(
          source: ReadingSource.vision,
          text: 'chloroplast',
          confidence: 0.9,
          uncertainSpans: <UncertainSpan>[UncertainSpan(text: 'chloroplast', confidence: 0.7, start: 0, end: 11)],
          lines: <RecognizedLine>[
            RecognizedLine(text: 'chloroplast', confidence: 0.9, box: NormalizedBox(x: 0, y: 0, width: 1, height: 0.1)),
          ],
        ),
      ],
    );
    final HandwritingEvidence back = HandwritingEvidence.fromJson(roundTrip(handwriting.toJson()))!;
    expect(back.rawText, 'chloroplast');
    expect(back.effectiveText, 'fixed');
    expect(back.enginesDisagree, isTrue);
    expect(back.readings.first.text, 'chloroplost', reason: 'every reading is kept');

    for (final VisualEvidence visual in <VisualEvidence>[
      const DiagramEvidence(regionId: 'd', description: 'cell', confidence: 0.8, labels: <String>['nucleus']),
      const GraphEvidence(regionId: 'g', description: 'rate', confidence: 0.7, xAxis: 'time / s', trend: 'rises'),
      const TableEvidence(regionId: 't', description: 'results', confidence: 0.9, rows: <List<String>>[<String>['a', 'b']]),
      const EquationEvidence(regionId: 'e', description: '', confidence: 0.6, latex: r'\frac{100}{0.05}'),
      VisualEvidence.unanalysed(regionId: 'f', kind: RegionType.graph, status: AnalysisStatus.failed, error: 'quota'),
    ]) {
      final VisualEvidence back = VisualEvidence.fromJson(roundTrip(visual.toJson()))!;
      expect(back.runtimeType, visual.runtimeType);
      expect(back.toJson(), visual.toJson());
    }
  });

  test('the question paper survives the cache, parts and all', () {
    final QuestionPaper paper = QuestionPaper(
      documentId: 'qp',
      title: 'Biology',
      statedTotal: 5,
      sections: const <QuestionSection>[QuestionSection(sectionId: 'A', statedMarks: 5)],
      questions: <Question>[
        Question(
          label: QuestionLabel.parse('1')!,
          questionText: 'Parts',
          sectionId: 'A',
          maximumMarks: 5,
          marksStated: true,
          subQuestions: <Question>[
            Question(label: QuestionLabel.parse('1(a)')!, questionText: 'a', maximumMarks: 2, marksStated: true),
            Question(label: QuestionLabel.parse('1(b)')!, questionText: 'b', maximumMarks: 3, marksStated: true),
          ],
        ),
      ],
    );
    final QuestionPaper back = QuestionPaper.fromJson(roundTrip(paper.toJson()))!;
    expect(back.markable.map((Question q) => q.questionId), <String>['Q1a', 'Q1b']);
    expect(back.totalMarks, 5);
    expect(back.byId('Q1b')!.maximumMarks, 3);
    expect(back.section('A')!.statedMarks, 5);
  });

  test('a mark scheme printed on the question paper survives the cache', () {
    final QuestionPaper paper = QuestionPaper(
      documentId: 'qp',
      markingGuidance: 'Ignore spelling.',
      questions: <Question>[
        Question(
          label: QuestionLabel.parse('1')!,
          questionText: 'Parts',
          markScheme: 'Either part may carry the unit mark.',
          subQuestions: <Question>[
            Question(label: QuestionLabel.parse('1(a)')!, questionText: 'a', maximumMarks: 2, markScheme: 'Mitochondrion (1); ATP (1)'),
            Question(label: QuestionLabel.parse('1(b)')!, questionText: 'b', maximumMarks: 1),
          ],
        ),
      ],
    );
    final QuestionPaper back = QuestionPaper.fromJson(roundTrip(paper.toJson()))!;
    expect(back.markingGuidance, 'Ignore spelling.');
    expect(back.byId('Q1a')!.markScheme, 'Mitochondrion (1); ATP (1)');
    expect(back.byId('Q1b')!.hasMarkScheme, isFalse);
    expect(back.markSchemeFor(back.byId('Q1a')!),
        '(For 1 as a whole) Either part may carry the unit mark.\nMitochondrion (1); ATP (1)');
    expect(back.markSchemeCount, 2);
    expect(back.hasMarkScheme, isTrue);
  });

  test('alignment, answers, results, reviews and jobs survive the cache', () {
    const AlignmentResult alignment = AlignmentResult(
      segments: <AnswerSegment>[
        AnswerSegment(segmentId: 's', regionIds: <String>['a', 'b'], pageNumbers: <int>[1, 2], label: 'Q4', labelKey: '4'),
      ],
      alignments: <String, QuestionAlignment>{
        'Q4': QuestionAlignment(questionId: 'Q4', segmentIds: <String>['s'], confidence: 0.85, methods: <AlignmentMethod>[AlignmentMethod.continuation]),
      },
      unassignedRegionIds: <String>['z'],
      unmatchedLabels: <UnmatchedLabel>[UnmatchedLabel(label: 'Q9', segmentId: 's2')],
    );
    final AlignmentResult back = AlignmentResult.fromJson(roundTrip(alignment.toJson()));
    expect(back.questionsByRegion['b'], <String>['Q4']);
    expect(back.alignments['Q4']!.methods, <AlignmentMethod>[AlignmentMethod.continuation]);
    expect(back.unmatchedLabels.single.label, 'Q9');

    const QuestionResult result = QuestionResult(
      questionNumber: '4',
      questionId: 'Q4',
      maximumMarks: 2,
      awardedMarks: 1,
      studentAnswer: 'x',
      evaluation: 'y',
      confidence: 0.6,
      needsReview: true,
      reviewReasons: <String>['why'],
      markingPoints: <MarkingPoint>[
        MarkingPoint(
          id: 'MP1',
          criterion: 'c',
          satisfied: true,
          marks: 1,
          marksAvailable: 1,
          evidenceRegionIds: <String>['a'],
          basis: EvidenceBasis.inferred,
          source: MarkingPointSource.teacherGuidance,
        ),
      ],
      interpretedReadings: <InterpretedReading>[
        InterpretedReading(regionId: 'a', raw: 'chloroplost', interpreted: 'chloroplast', basis: EvidenceBasis.inferred),
      ],
    );
    final QuestionResult marked = QuestionResult.fromJson(roundTrip(result.toJson()))!;
    expect(marked.markingPoints.single.basis, EvidenceBasis.inferred);
    expect(marked.markingPoints.single.source, MarkingPointSource.teacherGuidance);
    expect(marked.interpretedReadings.single.interpreted, 'chloroplast');
    expect(CorrectionResult.fromJson(roundTrip(CorrectionResult.fromQuestions(<QuestionResult>[result]).toJson())).totalMarks, 1);

    final TeacherReviewBook book = const TeacherReviewBook().withReview(TeacherReview(
      questionId: 'Q4',
      status: ReviewStatus.overridden,
      aiMarks: 1,
      teacherMarks: 2,
      comment: 'ok',
      timestamp: DateTime.utc(2026, 9, 25, 10),
    ));
    final TeacherReviewBook restored = TeacherReviewBook.fromJson(roundTrip(book.toJson()));
    expect(restored['Q4']!.teacherMarks, 2);
    expect(restored['Q4']!.timestamp, DateTime.utc(2026, 9, 25, 10));
    expect(restored.finalMarks(result), 2);

    final ProcessingJob job = const ProcessingJob(jobId: 'a_b', stage: ProcessingStage.marking)
        .copyWith(
          completedStages: <ProcessingStage>{ProcessingStage.rendering},
          failedStage: () => ProcessingStage.marking,
          error: () => 'quota',
        );
    final ProcessingJob again = ProcessingJob.fromJson(roundTrip(job.toJson()))!;
    expect(again.completedStages, <ProcessingStage>{ProcessingStage.rendering});
    expect(again.failedStage, ProcessingStage.marking);
    expect(again.error, 'quota');
  });

  test('overall progress is weighted by stage and reaches 1 when done', () {
    const ProcessingJob start = ProcessingJob(jobId: 'j', stage: ProcessingStage.rendering, stageFraction: 0.5);
    expect(start.overallFraction, closeTo(ProcessingStage.rendering.weight / 2, 1e-9));
    expect(
      ProcessingStage.pipeline.fold<double>(0, (double s, ProcessingStage st) => s + st.weight),
      closeTo(1, 1e-9),
    );
    expect(const ProcessingJob(jobId: 'j', stage: ProcessingStage.completed).overallFraction, 1);
  });
}
