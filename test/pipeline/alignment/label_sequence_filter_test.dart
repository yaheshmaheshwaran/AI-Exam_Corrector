import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/pipeline/alignment/label_boundary_detector.dart';
import 'package:exam_corrector/pipeline/alignment/paper_question_aligner.dart';
import 'package:exam_corrector/pipeline/engines.dart';

import '../pipeline_fakes.dart';

({BoundaryResult boundaries, AlignmentResult alignment}) align(
  ExamDocument doc,
  Map<String, HandwritingEvidence> evidence,
  QuestionPaper paper,
) {
  final BoundaryResult boundaries = const LabelBoundaryDetector()
      .detect(doc, EvidenceSet(handwriting: evidence), paper);
  return (
    boundaries: boundaries,
    alignment: const PaperQuestionAligner()
        .align(boundaries.segments, paper)
        .withWarnings(boundaries.warnings),
  );
}

List<String> regionsOf(AlignmentResult alignment, String questionId) => <String>[
      for (final String segment
          in alignment.alignments[questionId]?.segmentIds ?? const <String>[])
        ...alignment.segment(segment)!.regionIds,
    ];

/// A region whose writing starts [x] across the page.
PageRegion at(String id, double x, {int order = 0, RegionType? type, String? label}) =>
    region(id, order: order, type: type ?? RegionType.handwrittenAnswer, label: label)
        .copyWith(box: NormalizedBox(x: x, y: 0.1 + order * 0.05, width: 0.6, height: 0.04));

QuestionPaper paperOfCount(int count) => paperOf(<Question>[
      for (int n = 1; n <= count; n++) question('$n'),
    ]);

void main() {
  final QuestionPaper six = paperOfCount(6);

  test("a student's numbered points stay in their answer", () {
    final ExamDocument doc = document(<ExamPage>[
      page(1, regions: <PageRegion>[
        region('a1', order: 0),
        region('a4', order: 1),
        region('a5', order: 2),
        region('a6', order: 3),
      ]),
    ]);
    final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
      'a1': reading('a1', '1 The mitochondrion.'),
      'a4': reading('a4', '4 Root hairs have a large surface area.'),
      'a5': reading(
        'a5',
        '5 Three features of the alveoli:\n'
            '1. They have a large surface area.\n'
            '2. The walls are one cell thick.\n'
            '3. A good blood supply keeps the gradient.',
      ),
      'a6': reading('a6', '6 Osmosis is the movement of water.'),
    };

    final ({BoundaryResult boundaries, AlignmentResult alignment}) result =
        align(doc, evidence, six);

    expect(regionsOf(result.alignment, 'Q5'), <String>['a5']);
    expect(regionsOf(result.alignment, 'Q1'), <String>['a1']);
    expect(result.alignment.alignments.containsKey('Q2'), isFalse);
    expect(result.alignment.alignments.containsKey('Q3'), isFalse);
    expect(regionsOf(result.alignment, 'Q6'), <String>['a6']);
    expect(result.boundaries.document.region('a5.1'), isNull);
    expect(result.alignment.warnings.single, contains('Numbered points 1–3 in the answer to 5'));
  });

  test('a list longer than the paper still gives way to the real questions after it', () {
    final ExamDocument doc = document(<ExamPage>[
      page(1, regions: <PageRegion>[
        region('a5', order: 0),
        region('a6', order: 1),
      ]),
    ]);
    final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
      'a5': reading('a5', <String>[
        '5 Eight uses of energy:',
        for (int n = 1; n <= 6; n++) '$n. Use number $n',
      ].join('\n')),
      'a6': reading('a6', '6 Osmosis is the movement of water.'),
    };

    final AlignmentResult alignment = align(doc, evidence, six).alignment;

    expect(regionsOf(alignment, 'Q5'), <String>['a5']);
    expect(regionsOf(alignment, 'Q6'), <String>['a6']);
    expect(alignment.alignments.keys, unorderedEquals(<String>['Q5', 'Q6']));
  });

  test('a list the layout split into labelled regions is still a list', () {
    final ExamDocument doc = document(<ExamPage>[
      page(1, regions: <PageRegion>[
        at('q3', 0.05, order: 0, type: RegionType.questionNumber, label: '3'),
        at('t3', 0.12, order: 1),
        at('p1', 0.12, order: 2, label: '1.'),
        at('p2', 0.12, order: 3, label: '2.'),
        at('q4', 0.05, order: 4, type: RegionType.questionNumber, label: '4'),
        at('t4', 0.12, order: 5),
      ]),
    ]);
    final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
      'q3': reading('q3', '3'),
      't3': reading('t3', 'Two reasons:'),
      'p1': reading('p1', '1. Energy for contraction.'),
      'p2': reading('p2', '2. Heat.'),
      'q4': reading('q4', '4'),
      't4': reading('t4', 'Root hairs are long and thin.'),
    };

    final AlignmentResult alignment = align(doc, evidence, six).alignment;

    expect(regionsOf(alignment, 'Q3'), <String>['q3', 't3', 'p1', 'p2']);
    expect(regionsOf(alignment, 'Q4'), <String>['q4', 't4']);
  });

  test('the list ends where a number returns to the margin', () {
    final ExamDocument doc = document(<ExamPage>[
      page(1, regions: <PageRegion>[
        at('q2', 0.05, order: 0, type: RegionType.questionNumber, label: '2'),
        at('p1', 0.15, order: 1, label: '1.'),
        at('p2', 0.15, order: 2, label: '2.'),
        at('q3', 0.05, order: 3, type: RegionType.questionNumber, label: '3'),
        at('t3', 0.12, order: 4),
      ]),
    ]);
    final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
      'q2': reading('q2', '2'),
      'p1': reading('p1', '1. High energy demand.'),
      'p2': reading('p2', '2. More ATP released.'),
      'q3': reading('q3', '3'),
      't3': reading('t3', 'Magnification = 2000'),
    };

    final AlignmentResult alignment = align(doc, evidence, six).alignment;

    expect(regionsOf(alignment, 'Q2'), <String>['q2', 'p1', 'p2']);
    expect(regionsOf(alignment, 'Q3'), <String>['q3', 't3']);
  });

  test('an answer written out of order is still found', () {
    final ExamDocument doc = document(<ExamPage>[
      page(1, regions: <PageRegion>[
        region('a5', order: 0),
        region('a2', order: 1),
        region('q1', order: 2),
      ]),
    ]);
    final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
      'a5': reading('a5', '5 The membrane controls entry.'),
      'a2': reading('a2', '2 Glucose and oxygen.'),
      'q1': reading('q1', 'Q1 The mitochondrion.'),
    };

    final AlignmentResult alignment = align(doc, evidence, six).alignment;

    expect(regionsOf(alignment, 'Q5'), <String>['a5']);
    expect(regionsOf(alignment, 'Q2'), <String>['a2']);
    expect(regionsOf(alignment, 'Q1'), <String>['q1']);
    expect(alignment.warnings, isEmpty);
  });

  test('a backwards number inside a block, or indented, is part of the answer', () {
    final ExamDocument doc = document(<ExamPage>[
      page(1, regions: <PageRegion>[
        at('a5', 0.05, order: 0),
        at('in', 0.2, order: 1),
      ]),
    ]);
    final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
      'a5': reading('a5', '5 The answer is shown below.\n2 Times the length.'),
      'in': reading('in', '3) See the diagram.'),
    };

    final AlignmentResult alignment = align(doc, evidence, six).alignment;

    expect(regionsOf(alignment, 'Q5'), <String>['a5', 'in']);
    expect(alignment.warnings, hasLength(2));
    expect(alignment.warnings.first, contains('taken as part of that answer'));
  });
}
