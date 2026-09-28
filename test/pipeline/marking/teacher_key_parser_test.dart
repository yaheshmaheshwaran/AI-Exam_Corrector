import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/marking/teacher_key.dart';
import 'package:exam_corrector/pipeline/marking/teacher_key_parser.dart';

import '../pipeline_fakes.dart';

const String _options = 'Which organelle makes ATP? (a) nucleus (b) mitochondrion (c) ribosome (d) vacuole';

/// A paper like a real one: three multiple-choice questions, short answers,
/// a question with parts, and a Part B.
QuestionPaper _paper() => paperOf(<Question>[
      question('1', marks: 1, text: _options),
      question('2', marks: 1, text: _options),
      question('3', marks: 1, text: _options),
      question('4', marks: 2, text: 'Name the organelle that makes ATP.'),
      question('5', marks: 4, text: 'Explain osmosis.', parts: <Question>[
        question('5(a)', marks: 2, text: 'Define osmosis.'),
        question('5(b)', marks: 2, text: 'Give an example.'),
      ]),
      question('11', marks: 6, text: 'Describe respiration.', section: 'B'),
    ]);

void main() {
  const TeacherKeyParser parser = TeacherKeyParser();

  test('reads a compact multiple-choice list', () {
    final TeacherKeyParse read = parser.parse('1-B, 2-C, 3-A', _paper());
    expect(read.entries['Q1']!.option, 'b');
    expect(read.entries['Q2']!.option, 'c');
    expect(read.entries['Q3']!.option, 'a');
    expect(read.trustworthy, isTrue);
  });

  test('reads multiple choice as a table and as "1. (b)"', () {
    expect(parser.parse('1\tB\n2\tD', _paper()).entries['Q2']!.option, 'd');
    final TeacherKeyParse read = parser.parse('1. (b)\n2. (c)\n3. (a)', _paper());
    expect(read.entries.values.map((TeacherKeyEntry e) => e.option), <String>['b', 'c', 'a']);
  });

  test('reads labelled answers with marks, points and alternatives', () {
    final TeacherKeyParse read = parser.parse('''
Answer key — Biology CAT 1
4. Mitochondrion (2 marks)
   - Names the mitochondrion (1)
   - States that it makes ATP (1)
   Also accept: powerhouse of the cell
''', _paper());
    final TeacherKeyEntry q4 = read.entries['Q4']!;
    expect(q4.answer, 'Mitochondrion');
    expect(q4.keyMarks, 2);
    expect(q4.points.map((p) => p.criterion), <String>['Names the mitochondrion', 'States that it makes ATP']);
    expect(q4.alternatives, <String>['powerhouse of the cell']);
    expect(read.warnings, isEmpty);
  });

  test('splits an answer to a question with parts by its parts', () {
    final TeacherKeyParse read = parser.parse('''
5. (a) Movement of water across a membrane.
   (b) A plant cell in salt water.
''', _paper());
    expect(read.entries['Q5a']!.answer, 'Movement of water across a membrane.');
    expect(read.entries['Q5b']!.answer, 'A plant cell in salt water.');
  });

  test('matches "Part B 11" to the question in Part B', () {
    final TeacherKeyParse read = parser.parse('Part B 11: Glycolysis, Krebs cycle, electron transport.', _paper());
    expect(read.entries['Q11']!.answer, 'Glycolysis, Krebs cycle, electron transport.');
  });

  test('numbered points inside an answer stay in that answer', () {
    final TeacherKeyParse read = parser.parse('''
11. Three stages:
1. Glycolysis
2. Krebs cycle
3. Electron transport
''', _paper());
    expect(read.entries.keys, <String>['Q11']);
    expect(read.entries['Q11']!.answer, contains('Krebs cycle'));
  });

  test('reports answers for questions not on the paper, and marks that disagree', () {
    final TeacherKeyParse read = parser.parse('''
4. Mitochondrion (3 marks)
21. Not a question on this paper.
''', _paper());
    expect(read.unmatched, <String>['21']);
    expect(read.warnings.single, contains('the paper says 2 marks'));
  });

  test('is not trusted when little of it matches the paper', () {
    final TeacherKeyParse read = parser.parse('''
Chapter summary
30. Something
31. Something else
4. Mitochondrion
''', _paper());
    expect(read.trustworthy, isFalse);
  });
}
