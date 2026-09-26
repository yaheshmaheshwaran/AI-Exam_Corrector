import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/pipeline/alignment/label_boundary_detector.dart';
import 'package:exam_corrector/pipeline/alignment/paper_question_aligner.dart';
import 'package:exam_corrector/pipeline/alignment/question_label_detector.dart';
import 'package:exam_corrector/pipeline/engines.dart';

import '../pipeline_fakes.dart';

/// Runs boundary detection and alignment together, as the pipeline does.
({BoundaryResult boundaries, AlignmentResult alignment}) align(
  ExamDocument doc,
  Map<String, HandwritingEvidence> evidence,
  QuestionPaper paper,
) {
  final BoundaryResult boundaries = const LabelBoundaryDetector()
      .detect(doc, EvidenceSet(handwriting: evidence), paper);
  return (
    boundaries: boundaries,
    alignment: const PaperQuestionAligner().align(boundaries.segments, paper),
  );
}

List<String> regionsOf(AlignmentResult alignment, String questionId) => <String>[
      for (final String segment in alignment.alignments[questionId]!.segmentIds)
        ...alignment.segment(segment)!.regionIds,
    ];

void main() {
  final QuestionPaper fiveQuestions = paperOf(<Question>[
    for (final String n in <String>['1', '2', '3', '4', '5']) question(n),
  ]);

  group('label detection', () {
    const QuestionLabelDetector detector = QuestionLabelDetector();
    final QuestionPaper paper = paperOf(<Question>[
      question('1'),
      question('2', parts: <Question>[question('2(a)'), question('2(b)')]),
      question('3', parts: <Question>[
        question('3(a)', parts: <Question>[question('3(a)(i)'), question('3(a)(ii)')]),
      ]),
      question('12'),
    ]);

    String? key(String line, {String? current, bool standalone = false}) => detector
        .detect(
          line,
          paper: paper,
          current: current == null ? null : QuestionLabel.parse(current),
          standalone: standalone,
        )
        ?.label
        .key;

    test('reads the forms students and papers actually use', () {
      expect(key('1 The mitochondrion.'), '1');
      expect(key('1. the mitochondrion'), '1');
      expect(key('Q1 the mitochondrion'), '1');
      expect(key('Question 2(b) Because'), '2.b');
      expect(key('2 ( a ) Write the word equation'), '2.a');
      expect(key('2b) glucose'), '2.b');
      expect(key('3(a)(ii) Show that'), '3.a.ii');
    });

    test('reads "Q. No." forms as explicit labels, and MCQ answers after them', () {
      bool explicit(String line) =>
          detector.detect(line, paper: paper)?.explicit ?? false;
      expect(key('Q. No. 1. [ b ] Answer: A dedicated application.'), '1');
      expect(key('Q.No:3 The cell wall'), '3');
      expect(key('Question No. 2(a) Glucose'), '2.a');
      expect(key('Ques. 12 Explain'), '12');
      expect(key('Qs.1 The nucleus'), '1');
      expect(key('2. [ b ] Answer: Data processing and control.'), '2');
      expect(explicit('Q. No. 1. [ b ] Answer: A dedicated application.'), isTrue);
      expect(explicit('Q.No:3 The cell wall'), isTrue);
      expect(explicit('2. [ b ] Answer'), isFalse);
      // "No." alone, without a Q, is not a label prefix.
      expect(key('No. 3 is the answer'), isNull);
    });

    test('resolves a bare part against the answer being read', () {
      expect(key('(b) Because muscles', current: '2(a)'), '2.b');
      expect(key('(ii) the rate', current: '3(a)(i)'), '3.a.ii');
    });

    test('takes a question-number region as a label however it is written', () {
      expect(key('12', standalone: true), '12');
      expect(key('Q.1', standalone: true), '1');
    });

    test('never takes working or measurements for a label', () {
      expect(key('50 micrometres = 0.05 mm'), isNull);
      expect(key('12.5 mol of gas'), isNull);
      expect(key('100 / 0.05'), isNull);
      expect(key('2 marks were lost'), isNull);
      expect(key('7 Define osmosis.'), isNull, reason: 'no question 7 in paper');
      expect(key('Answer: 50 micrometres = 0.05 mm'), isNull);
      expect(key('Answer: 2 The cell'), isNull);
    });

    test('an explicit label the paper lacks is still reported, as unmatched', () {
      final DetectedLabel? label = detector.detect('Q9 Lactic acid', paper: paper);
      expect(label, isNotNull);
      expect(label!.inPaper, isFalse);
      expect(label.explicit, isTrue);
    });

    test('a number that repeats the question\'s wording is near certain', () {
      final QuestionPaper worded = paperOf(<Question>[
        question('1', text: 'Name the organelle that carries out aerobic respiration.'),
        question('2', text: 'Explain why muscle cells contain many mitochondria.'),
      ]);
      final DetectedLabel echo = detector.detect(
        '2 Explain why muscle cells contain a large number of',
        paper: worded,
        current: QuestionLabel.parse('1'),
      )!;
      final DetectedLabel next = detector.detect(
        '2 Because they need energy',
        paper: worded,
        current: QuestionLabel.parse('1'),
      )!;
      final DetectedLabel outOfOrder = detector.detect(
        '2 Because they need energy',
        paper: paperOf(<Question>[question('1'), question('2'), question('3'), question('4')]),
        current: QuestionLabel.parse('4'),
      )!;
      expect(echo.confidence, 0.98);
      expect(next.confidence, 0.92);
      expect(outOfOrder.confidence, 0.8);
    });

    test('marks continuation labels', () {
      final DetectedLabel? label =
          detector.detect('Q2(b) continued', paper: paper);
      expect(label!.continuation, isTrue);
      expect(label.label.key, '2.b');
    });
  });

  group('answer boundaries', () {
    test('everything between Q4 and Q5 belongs to Q4 — diagrams included', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('q4', type: RegionType.questionNumber, order: 0, label: '4'),
          region('p1', order: 1),
          region('p2', order: 2),
          region('d1', type: RegionType.diagram, order: 3),
          region('lab', type: RegionType.label, order: 4, parent: 'd1'),
          region('p3', order: 5),
          region('p4', order: 6),
          region('q5', type: RegionType.questionNumber, order: 7, label: 'Q5'),
          region('p5', order: 8),
        ]),
      ]);
      final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
        'q4': reading('q4', '4'),
        'p1': reading('p1', 'The nucleus controls the cell.'),
        'p2': reading('p2', 'It contains DNA.'),
        'lab': reading('lab', '5 nucleus'),
        'p3': reading('p3', 'the membrane controls entry'),
        'p4': reading('p4', 'and exit.'),
        'q5': reading('q5', 'Q5'),
        'p5': reading('p5', 'Osmosis is the movement of water.'),
      };

      final AlignmentResult alignment = align(doc, evidence, fiveQuestions).alignment;

      expect(regionsOf(alignment, 'Q4'), <String>['q4', 'p1', 'p2', 'd1', 'lab', 'p3', 'p4']);
      expect(regionsOf(alignment, 'Q5'), <String>['q5', 'p5']);
      expect(alignment.alignments.keys, unorderedEquals(<String>['Q4', 'Q5']));
    });

    test('an answer continues onto a page that has no label of its own', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[region('a', order: 0), region('b', order: 1)]),
        page(2, regions: <PageRegion>[region('c', page: 2, order: 0)]),
        page(3, regions: <PageRegion>[region('d', page: 3, order: 0)]),
      ]);
      final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
        'a': reading('a', '3 A cell is 50 micrometres long.'),
        'b': reading('b', '50 micrometres = 0.05 mm'),
        'c': reading('c', 'so the magnification is 2000'),
        'd': reading('d', 'Q4 Root hair cells have a large surface area.'),
      };

      final AlignmentResult alignment = align(doc, evidence, fiveQuestions).alignment;

      expect(regionsOf(alignment, 'Q3'), <String>['a', 'b', 'c']);
      final QuestionAlignment three = alignment.alignments['Q3']!;
      expect(three.methods, contains(AlignmentMethod.continuation));
      expect(three.confidence, lessThan(0.9));
      expect(regionsOf(alignment, 'Q4'), <String>['d']);
    });

    test('a block holding the end of one answer and the next label is split', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('blk', order: 0, lines: const <NormalizedBox>[
            NormalizedBox(x: 0.1, y: 0.10, width: 0.8, height: 0.02),
            NormalizedBox(x: 0.1, y: 0.13, width: 0.8, height: 0.02),
            NormalizedBox(x: 0.1, y: 0.16, width: 0.8, height: 0.02),
          ]),
        ]),
      ]);
      final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
        'blk': reading(
          'blk',
          '1 The mitochondrion.\n2 Because muscles need energy.\nfrom respiration',
          spans: const <UncertainSpan>[
            UncertainSpan(text: 'respiration', confidence: 0.4, start: 57, end: 68),
          ],
        ),
      };

      final ({BoundaryResult boundaries, AlignmentResult alignment}) result =
          align(doc, evidence, fiveQuestions);

      expect(regionsOf(result.alignment, 'Q1'), <String>['blk.0']);
      expect(regionsOf(result.alignment, 'Q2'), <String>['blk.1']);
      final PageRegion second = result.boundaries.document.region('blk.1')!;
      expect(second.parentRegionId, 'blk');
      expect(second.box.y, closeTo(0.13, 1e-6));
      final HandwritingEvidence split = result.boundaries.evidence.handwriting['blk.1']!;
      expect(split.rawText, '2 Because muscles need energy.\nfrom respiration');
      expect(split.uncertainSpans.single.start, 36);
      expect(
        split.rawText.substring(split.uncertainSpans.single.start!, split.uncertainSpans.single.end),
        'respiration',
      );
      // The parent's own reading is untouched and still available.
      expect(result.boundaries.evidence.handwriting['blk']!.rawText, startsWith('1 The'));
    });

    test('content before the first label is not guessed at', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('name', order: 0),
          region('a', order: 1),
        ]),
      ]);
      final AlignmentResult alignment = align(doc, <String, HandwritingEvidence>{
        'name': reading('name', 'Candidate: A. Whitfield'),
        'a': reading('a', '1 The mitochondrion.'),
      }, fiveQuestions).alignment;

      expect(alignment.preambleRegionIds, <String>['name']);
      expect(alignment.unassignedRegionIds, isEmpty);
      expect(regionsOf(alignment, 'Q1'), <String>['a']);
    });

    test('with a single question, unlabelled writing answers it', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[region('a', order: 0)]),
      ]);
      final AlignmentResult alignment = align(
        doc,
        <String, HandwritingEvidence>{'a': reading('a', 'Photosynthesis makes glucose.')},
        paperOf(<Question>[question('1')]),
      ).alignment;

      expect(alignment.alignments['Q1']!.methods, <AlignmentMethod>[AlignmentMethod.soleQuestion]);
    });

    test('an answer labelled with a question the paper lacks is reported, not marked', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[region('a', order: 0), region('b', order: 1)]),
      ]);
      final AlignmentResult alignment = align(doc, <String, HandwritingEvidence>{
        'a': reading('a', 'Q9 Lactic acid builds up.'),
        'b': reading('b', 'It causes fatigue.'),
      }, fiveQuestions).alignment;

      expect(alignment.alignments, isEmpty);
      expect(alignment.unmatchedLabels.single.label, contains('9'));
      expect(alignment.unassignedRegionIds, <String>['a', 'b']);
      expect(alignment.warnings.single, contains('not marked'));
    });

    test('a parent label is shared with every part, at lower confidence', () {
      final QuestionPaper paper = paperOf(<Question>[
        question('2', parts: <Question>[question('2(a)'), question('2(b)')]),
      ]);
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[region('a', order: 0)]),
      ]);
      final AlignmentResult alignment = align(
        doc,
        <String, HandwritingEvidence>{'a': reading('a', '2. Glucose and oxygen.')},
        paper,
      ).alignment;

      expect(alignment.alignments.keys, unorderedEquals(<String>['Q2a', 'Q2b']));
      expect(alignment.alignments['Q2a']!.confidence, lessThan(0.7));
    });

    test('sub-parts written without their number follow the question', () {
      final QuestionPaper paper = paperOf(<Question>[
        question('2', parts: <Question>[question('2(a)'), question('2(b)')]),
        question('3'),
      ]);
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('a', order: 0),
          region('b', order: 1),
          region('c', order: 2),
        ]),
      ]);
      final AlignmentResult alignment = align(doc, <String, HandwritingEvidence>{
        'a': reading('a', '2 (a) glucose + oxygen'),
        'b': reading('b', '(b) Because muscles need energy'),
        'c': reading('c', '3 A cell'),
      }, paper).alignment;

      expect(regionsOf(alignment, 'Q2a'), <String>['a']);
      expect(regionsOf(alignment, 'Q2b'), <String>['b']);
      expect(regionsOf(alignment, 'Q3'), <String>['c']);
    });

    test('a label the vision model reported is used even if the text omits it', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[region('a', order: 0, label: '3')]),
      ]);
      final AlignmentResult alignment = align(
        doc,
        <String, HandwritingEvidence>{'a': reading('a', 'magnification = 2000')},
        fiveQuestions,
      ).alignment;
      expect(regionsOf(alignment, 'Q3'), <String>['a']);
    });

    test('a misread label lowers the confidence of its answer', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[region('a', order: 0)]),
      ]);
      final AlignmentResult clear = align(doc, <String, HandwritingEvidence>{
        'a': reading('a', '1. The mitochondrion', confidence: 0.99),
      }, fiveQuestions).alignment;
      final AlignmentResult smudged = align(doc, <String, HandwritingEvidence>{
        'a': reading('a', '1. The mitochondrion', confidence: 0.4),
      }, fiveQuestions).alignment;

      expect(
        smudged.alignments['Q1']!.confidence,
        lessThan(clear.alignments['Q1']!.confidence),
      );
    });

    test('headers and footers never join an answer', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('h', type: RegionType.header, order: 0),
          region('a', order: 1),
          region('f', type: RegionType.footer, order: 2),
        ]),
      ]);
      final AlignmentResult alignment = align(doc, <String, HandwritingEvidence>{
        'h': reading('h', 'Q2 page header'),
        'a': reading('a', '1. The mitochondrion'),
        'f': reading('f', 'Page 1'),
      }, fiveQuestions).alignment;

      expect(regionsOf(alignment, 'Q1'), <String>['a']);
    });
  });
}
