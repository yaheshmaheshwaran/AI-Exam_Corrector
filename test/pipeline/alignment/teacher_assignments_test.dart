import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/pipeline/alignment/teacher_assignments.dart';

import '../pipeline_fakes.dart';

void main() {
  final ExamDocument sheet = document(<ExamPage>[
    page(1, regions: <PageRegion>[
      region('lost', order: 0),
      region('a2', order: 1),
      region('extra', order: 2),
      region('a3', order: 3),
    ]),
  ]);
  final QuestionPaper paper = paperOf(<Question>[question('1'), question('2'), question('3')]);

  const AlignmentResult found = AlignmentResult(
    segments: <AnswerSegment>[
      AnswerSegment(segmentId: 's2', regionIds: <String>['a2', 'extra'], pageNumbers: <int>[1], labelKey: '2'),
      AnswerSegment(segmentId: 's3', regionIds: <String>['a3'], pageNumbers: <int>[1], labelKey: '3'),
    ],
    alignments: <String, QuestionAlignment>{
      'Q2': QuestionAlignment(questionId: 'Q2', segmentIds: <String>['s2'], confidence: 0.9, methods: <AlignmentMethod>[AlignmentMethod.label]),
      'Q3': QuestionAlignment(questionId: 'Q3', segmentIds: <String>['s3'], confidence: 0.9, methods: <AlignmentMethod>[AlignmentMethod.label]),
    },
    preambleRegionIds: <String>['lost'],
  );

  List<String> regionsOf(AlignmentResult a, String id) => <String>[
        for (final String s in a.alignments[id]?.segmentIds ?? const <String>[])
          ...a.segment(s)!.regionIds,
      ];

  test('writing before the first label becomes the answer the teacher chose', () {
    final AlignmentResult result =
        const TeacherAssignments().apply(found, <String, String>{'lost': 'Q1'}, sheet, paper);

    expect(regionsOf(result, 'Q1'), <String>['lost']);
    expect(result.alignments['Q1']!.methods, <AlignmentMethod>[AlignmentMethod.teacher]);
    expect(result.alignments['Q1']!.confidence, 1);
    expect(result.preambleRegionIds, isEmpty);
    expect(regionsOf(result, 'Q2'), <String>['a2', 'extra']);
  });

  test('writing moved from one answer to another leaves the rest in place, in reading order', () {
    final AlignmentResult result = const TeacherAssignments()
        .apply(found, <String, String>{'extra': 'Q3'}, sheet, paper);

    expect(regionsOf(result, 'Q2'), <String>['a2']);
    expect(regionsOf(result, 'Q3'), <String>['extra', 'a3']);
    expect(result.alignments['Q3']!.methods, contains(AlignmentMethod.teacher));
  });

  test('an answer whose only writing moves away is left with none', () {
    final AlignmentResult result = const TeacherAssignments()
        .apply(found, <String, String>{'a3': 'Q1'}, sheet, paper);

    expect(result.alignments.containsKey('Q3'), isFalse);
    expect(result.segment('s3'), isNull);
  });

  test('choices for a question or region that no longer exists are ignored', () {
    final AlignmentResult result = const TeacherAssignments()
        .apply(found, <String, String>{'lost': 'Q9', 'gone': 'Q1'}, sheet, paper);

    expect(identical(result, found), isTrue);
  });
}
