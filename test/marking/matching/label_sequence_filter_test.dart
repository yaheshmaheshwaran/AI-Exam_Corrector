import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/marking/script/matching/question_label_detector.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/marking/script/matching/label_boundary_detector.dart';
import 'package:exam_corrector/marking/script/matching/paper_question_aligner.dart';
import 'package:exam_corrector/marking/contracts.dart';

import '../marking_fakes.dart';

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

  group('a question the sheet seems not to answer', () {
    test('"Q. No. 1" is a label, and the answer before "2." is not front matter', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('head', order: 0, type: RegionType.printedText),
          region('a1', order: 1),
          region('a2', order: 2),
          region('a3', order: 3),
        ]),
      ]);
      final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
        'head': reading('head', 'PART - A'),
        'a1': reading('a1', 'Q. No. 1. [ b ] Answer: A dedicated application.'),
        'a2': reading('a2', '2. [ b ] Answer: Data processing and control.'),
        'a3': reading('a3', '3. [ c ] Answer: Real-Time operating system.'),
      };

      final AlignmentResult alignment = align(doc, evidence, six).alignment;

      expect(regionsOf(alignment, 'Q1'), <String>['a1']);
      expect(regionsOf(alignment, 'Q2'), <String>['a2']);
      expect(regionsOf(alignment, 'Q3'), <String>['a3']);
      expect(alignment.preambleRegionIds, <String>['head']);
    });

    test('a misread number is recovered where the missing answer must sit', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('a4', order: 0),
          region('a5', order: 1),
          region('a6', order: 2),
        ]),
      ]);
      final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
        'a4': reading('a4', '4 Root hairs have a large surface area.'),
        'a5': reading('a5', 'S. The membrane controls what enters the cell.'),
        'a6': reading('a6', '6 The alveoli are thin.'),
      };

      final AlignmentResult alignment = align(doc, evidence, six).alignment;

      expect(regionsOf(alignment, 'Q5'), <String>['a5']);
      expect(regionsOf(alignment, 'Q4'), <String>['a4']);
      expect(alignment.alignments['Q5']!.confidence, lessThan(0.8));
      expect(alignment.warnings.single, contains('Question 5 had no label the app could read'));
    });

    test('a misread number outside that place is left alone', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('a4', order: 0),
          region('a6', order: 1),
          region('a7', order: 2),
        ]),
      ]);
      final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
        'a4': reading('a4', '4 Root hairs have a large surface area.'),
        'a6': reading('a6', '6 The alveoli are thin.'),
        'a7': reading('a7', '7 Osmosis is the movement of water.\nS. Water moves across a membrane.'),
      };

      final AlignmentResult alignment = align(doc, evidence, paperOfCount(8)).alignment;

      expect(alignment.alignments.containsKey('Q5'), isFalse);
      expect(regionsOf(alignment, 'Q7'), <String>['a7']);
    });

    test("a student's list does not take a question answered elsewhere", () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('a1', order: 0),
          region('a3', order: 1),
          region('a5', order: 2),
        ]),
      ]);
      final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
        'a1': reading('a1', '1 The mitochondrion.'),
        'a3': reading('a3', '3 Magnification is 2000.'),
        'a5': reading('a5', '5 Three features:\n1. Thin walls.\n2. Moist.\n3. Blood supply.'),
      };

      final AlignmentResult alignment = align(doc, evidence, six).alignment;

      expect(alignment.alignments.containsKey('Q2'), isFalse);
      expect(regionsOf(alignment, 'Q5'), <String>['a5']);
    });

    test('a set-aside label outside the missing answer\'s place stays set aside', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[
          region('a3', order: 0),
          region('a4', order: 1),
          region('a5', order: 2),
        ]),
      ]);
      final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
        'a3': reading('a3', '3 Magnification is 2000.'),
        'a4': reading('a4', '4 Root hairs are long.\n2 Glucose and oxygen react.'),
        'a5': reading('a5', '5 The membrane controls entry.'),
      };

      final ({BoundaryResult boundaries, AlignmentResult alignment}) result =
          align(doc, evidence, six);

      // Question 2 has no answer, but its answer would come before 3's
      // label, so a "2" inside answer 4 is still not taken as it.
      expect(result.alignment.alignments.containsKey('Q2'), isFalse);
      expect(regionsOf(result.alignment, 'Q4'), <String>['a4']);
    });
  });

  test('a set-aside label is taken back when its question has no other answer', () {
    // 6 answered out of order after 1; the "2" inside that block went
    // backwards and was set aside, but question 2 has no other answer and
    // the "2" sits between the answers to 1 and 3.
    final ExamDocument doc = document(<ExamPage>[
      page(1, regions: <PageRegion>[
        region('a1', order: 0),
        region('a6', order: 1),
        region('a3', order: 2),
      ]),
    ]);
    final Map<String, HandwritingEvidence> evidence = <String, HandwritingEvidence>{
      'a1': reading('a1', '1 The mitochondrion.'),
      'a6': reading('a6', '6 The alveoli are thin.\n2 Glucose and oxygen react.'),
      'a3': reading('a3', '3 Magnification is 2000.'),
    };

    final AlignmentResult alignment = align(doc, evidence, six).alignment;

    expect(regionsOf(alignment, 'Q6'), <String>['a6.0']);
    expect(regionsOf(alignment, 'Q2'), <String>['a6.1']);
    expect(regionsOf(alignment, 'Q3'), <String>['a3']);
    expect(alignment.warnings.single, contains('Question 2 had no other answer'));
  });

  group('stray numbers on a phone photo', () {
    test('a bare number going back to an answered question is not a label', () {
      // Page 2 continues the answer to 5; a "2" from the facing page's edge
      // sits at the margin in a block of its own.
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[at('a1', 0.1, order: 0), at('a2', 0.1, order: 1), at('a5', 0.1, order: 2)]),
        page(2, regions: <PageRegion>[at('stray', 0.1, order: 0), at('more', 0.1, order: 1)]),
      ]);
      final ({BoundaryResult boundaries, AlignmentResult alignment}) result = align(doc, <String, HandwritingEvidence>{
        'a1': reading('a1', '1. The mitochondrion.'),
        'a2': reading('a2', '2. Glucose and oxygen.'),
        'a5': reading('a5', '5. Osmosis moves water across a membrane.'),
        'stray': reading('stray', '2'),
        'more': reading('more', 'from a dilute solution to a concentrated one.'),
      }, six);

      expect(regionsOf(result.alignment, 'Q2'), <String>['a2']);
      expect(regionsOf(result.alignment, 'Q5'), containsAll(<String>['a5', 'more']));
      expect(result.boundaries.warnings, contains(startsWith('A stray "2" was not taken as question 2')));
    });

    test('written as a label, an answer out of order still starts there', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[at('a1', 0.1, order: 0), at('a2', 0.1, order: 1), at('a5', 0.1, order: 2)]),
        page(2, regions: <PageRegion>[at('again', 0.1, order: 0)]),
      ]);
      final ({BoundaryResult boundaries, AlignmentResult alignment}) result = align(doc, <String, HandwritingEvidence>{
        'a1': reading('a1', '1. The mitochondrion.'),
        'a2': reading('a2', '2. Glucose and oxygen.'),
        'a5': reading('a5', '5. Osmosis moves water across a membrane.'),
        'again': reading('again', '2. Also carbon dioxide is released.'),
      }, six);

      expect(regionsOf(result.alignment, 'Q2'), containsAll(<String>['a2', 'again']));
    });

    test('a bare number for a question not yet answered is still taken', () {
      final ExamDocument doc = document(<ExamPage>[
        page(1, regions: <PageRegion>[at('a1', 0.1, order: 0), at('a5', 0.1, order: 1)]),
        page(2, regions: <PageRegion>[at('four', 0.1, order: 0), at('body', 0.1, order: 1)]),
      ]);
      final ({BoundaryResult boundaries, AlignmentResult alignment}) result = align(doc, <String, HandwritingEvidence>{
        'a1': reading('a1', '1. The mitochondrion.'),
        'a5': reading('a5', '5. Osmosis moves water across a membrane.'),
        'four': reading('four', '4'),
        'body': reading('body', 'Root hairs have a large surface area.'),
      }, six);

      expect(regionsOf(result.alignment, 'Q4'), containsAll(<String>['four', 'body']));
    });

    test('whether words follow the number on its line', () {
      expect(LabelBoundaryDetector.wordsAfter('17. Temperature sensor', _label('17.')), isTrue);
      expect(LabelBoundaryDetector.wordsAfter('1 | r', _label('1')), isFalse);
      expect(LabelBoundaryDetector.wordsAfter('6 0', _label('6')), isFalse);
    });
  });

  group('an answer numbered as a question already answered', () {
    final QuestionPaper science = paperOf(<Question>[
      question('1', text: 'Name the gas plants take in for photosynthesis.'),
      question('2', text: 'Explain how a thermostat controls room temperature in a heating system.'),
      question('3', text: 'Describe the water cycle, including evaporation and condensation.'),
    ]);

    ({BoundaryResult boundaries, AlignmentResult alignment}) script(String third) => align(
          document(<ExamPage>[
            page(1, regions: <PageRegion>[at('a1', 0.1, order: 0), at('a2', 0.1, order: 1), at('x', 0.1, order: 2)]),
          ]),
          <String, HandwritingEvidence>{
            'a1': reading('a1', '1. Carbon dioxide.'),
            'a2': reading('a2', '2. The thermostat senses the room temperature and switches the heating.'),
            'x': reading('x', third),
          },
          science,
        );

    test('goes to the unanswered question its words answer, flagged', () {
      final ({BoundaryResult boundaries, AlignmentResult alignment}) result =
          script('2. The water cycle: evaporation from the sea, condensation into clouds, then rain.');

      expect(regionsOf(result.alignment, 'Q3'), <String>['x']);
      expect(regionsOf(result.alignment, 'Q2'), <String>['a2']);
      expect(result.boundaries.warnings, contains(allOf(startsWith('An answer labelled "2'), contains('placed under question 3'))));
      expect(result.alignment.alignments['Q3']!.confidence, lessThan(result.alignment.alignments['Q2']!.confidence));
    });

    test('stays where the student put it when its words are about that question', () {
      final ({BoundaryResult boundaries, AlignmentResult alignment}) result =
          script('2. Also, the thermostat switches the heating off again at the set temperature.');

      expect(regionsOf(result.alignment, 'Q2'), containsAll(<String>['a2', 'x']));
      expect(regionsOf(result.alignment, 'Q3'), isEmpty);
    });

    test('a continued answer is never moved', () {
      final ({BoundaryResult boundaries, AlignmentResult alignment}) result =
          script('2 contd. The water cycle: evaporation and condensation.');

      expect(regionsOf(result.alignment, 'Q3'), isEmpty);
    });
  });
}

DetectedLabel _label(String observed) => DetectedLabel(
      label: QuestionLabel.parse(observed)!,
      observed: observed,
      confidence: 0.9,
      inPaper: true,
      numbered: true,
    );
