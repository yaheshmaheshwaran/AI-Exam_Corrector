import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/questions/question_paper_parser.dart';

void main() {
  const HeuristicQuestionPaperParser parser = HeuristicQuestionPaperParser();

  group('the sample question paper', () {
    late QuestionPaper paper;

    setUpAll(() {
      paper = parser.parse(File('sample/question_paper.txt').readAsStringSync());
    });

    test('finds every markable question, parts included, in paper order', () {
      expect(
        paper.markable.map((Question q) => q.displayNumber).toList(),
        <String>['1', '2(a)', '2(b)', '3', '4', '5', '6', '7', '8'],
      );
    });

    test('reads each printed allocation', () {
      expect(
        paper.markable.map((Question q) => q.maximumMarks).toList(),
        <double>[2, 1, 2, 3, 2, 1, 4, 3, 2],
      );
      expect(paper.markable.every((Question q) => q.marksStated), isTrue);
    });

    test('groups questions under their sections', () {
      expect(paper.sections.map((QuestionSection s) => s.sectionId), <String>['A', 'B']);
      expect(paper.sections.first.statedMarks, 10);
      expect(paper.byLabel(QuestionLabel.parse('4')!)!.sectionId, 'A');
      expect(paper.byLabel(QuestionLabel.parse('5')!)!.sectionId, 'B');
    });

    test('keeps a question with parts as the parent of its parts', () {
      final Question two = paper.byLabel(QuestionLabel.parse('2')!)!;
      expect(two.subQuestions.map((Question q) => q.displayNumber), <String>['2(a)', '2(b)']);
      expect(two.maximumMarks, 3);
    });

    test('joins wording that runs over several lines', () {
      final Question three = paper.byLabel(QuestionLabel.parse('3')!)!;
      expect(three.questionText, contains('Calculate the magnification'));
      expect(three.questionText, isNot(contains('[3 marks]')));
    });

    test('checks the totals and finds them consistent', () {
      expect(paper.statedTotal, 20);
      expect(paper.totalMarks, 20);
      expect(paper.warnings, isEmpty);
      expect(HeuristicQuestionPaperParser.isTrustworthy(paper), isTrue);
    });
  });

  test('reads Q-prefixed numbers and roman sub-parts', () {
    final QuestionPaper paper = parser.parse('''
Q1 Define diffusion. (2 marks)
Q2 (a) State Newton's first law. [1]
(b) A ball is dropped.
(i) Calculate its speed after 2 s. [2]
(ii) Explain why air resistance matters. [3]
''');

    expect(
      paper.markable.map((Question q) => q.key).toList(),
      <String>['1', '2.a', '2.b.i', '2.b.ii'],
    );
    expect(paper.byLabel(QuestionLabel.parse('2(b)')!)!.maximumMarks, 5);
  });

  test('treats (i) after (h) as a letter, not a roman numeral', () {
    final QuestionPaper paper = parser.parse('''
1 (g) Name it. [1]
(h) Name it again. [1]
(i) And again. [1]
''');
    expect(paper.markable.map((Question q) => q.key).last, '1.i');
    expect(paper.markable, hasLength(3));
  });

  test('does not mistake working or measurements for questions', () {
    final QuestionPaper paper = parser.parse('''
1 A cell is 50 micrometres long.
50 micrometres is 0.05 mm
100 mm is the drawing. [3 marks]
2 Name the organelle. [1 mark]
''');
    expect(paper.markable.map((Question q) => q.key), <String>['1', '2']);
    expect(paper.markable.first.maximumMarks, 3);
  });

  test('reports a question with no printed marks, and is not trusted', () {
    final QuestionPaper paper = parser.parse('''
1 Define osmosis. [2 marks]
2 Explain diffusion.
''');
    expect(paper.markable.last.maximumMarks, isNull);
    expect(paper.warnings.single, contains('Question 2'));
    expect(HeuristicQuestionPaperParser.isTrustworthy(paper), isFalse);
  });

  test('reports a total that does not add up', () {
    final QuestionPaper paper = parser.parse('''
Total marks: 10
1 Define osmosis. [2 marks]
2 Explain diffusion. [3 marks]
''');
    expect(paper.warnings.single, contains('total of 10'));
  });

  group('a question paper that prints its own mark scheme', () {
    late QuestionPaper plain;
    late QuestionPaper combined;

    setUpAll(() {
      plain = parser.parse(File('sample/question_paper.txt').readAsStringSync());
      combined = parser.parse(
        File('sample/question_paper_with_scheme.txt').readAsStringSync(),
      );
    });

    test('has the same questions and marks as the paper without it', () {
      expect(
        combined.markable.map((Question q) => q.key).toList(),
        plain.markable.map((Question q) => q.key).toList(),
      );
      expect(
        combined.markable.map((Question q) => q.maximumMarks).toList(),
        plain.markable.map((Question q) => q.maximumMarks).toList(),
      );
      expect(combined.totalMarks, 20);
      expect(combined.warnings, isEmpty);
      expect(HeuristicQuestionPaperParser.isTrustworthy(combined), isTrue);
    });

    test('keeps the scheme out of the wording and on its question', () {
      for (final Question question in combined.markable) {
        expect(
          question.questionText,
          plain.byId(question.questionId)!.questionText,
          reason: question.displayNumber,
        );
        expect(question.hasMarkScheme, isTrue, reason: question.displayNumber);
      }
      final Question one = combined.byLabel(QuestionLabel.parse('1')!)!;
      expect(one.markScheme, contains('Names the mitochondrion'));
      expect(one.markScheme, contains('Do not accept "energy" on its own'));
      expect(
        combined.byLabel(QuestionLabel.parse('5')!)!.markScheme,
        startsWith('controls what enters'),
      );
      expect(combined.markSchemeCount, 9);
    });

    test('the paper without a scheme has none', () {
      expect(plain.hasMarkScheme, isFalse);
      expect(plain.markingGuidance, isEmpty);
    });

    test('attaches a scheme printed after the questions to each question', () {
      final QuestionPaper paper = parser.parse('''
1 Define diffusion. [2 marks]
2 (a) Name the gas plants take in. [1 mark]
(b) Explain why leaves are thin. [2 marks]
END OF PAPER
MARK SCHEME
General marking guidance
Ignore spelling where the meaning is clear.
1 Net movement of particles (1)
  from high to low concentration (1)
2 (a) Carbon dioxide. Accept CO2. (1)
(b) 1. Short diffusion distance (1)
    2. For gases / carbon dioxide (1)
''');
      expect(paper.markable.map((Question q) => q.key), <String>['1', '2.a', '2.b']);
      expect(paper.markable.map((Question q) => q.maximumMarks), <double>[2, 1, 2]);
      expect(paper.markable.first.questionText, 'Define diffusion.');
      expect(paper.markable.first.markScheme, contains('from high to low'));
      expect(paper.markable[1].markScheme, contains('Accept CO2'));
      expect(paper.markable[2].markScheme, contains('For gases'));
      expect(paper.markingGuidance, contains('Ignore spelling'));
      expect(paper.warnings, isEmpty);
    });

    test('reads a document that is only a mark scheme', () {
      final QuestionPaper paper =
          parser.parse(File('sample/mark_scheme.txt').readAsStringSync());
      expect(
        paper.markable.map((Question q) => q.displayNumber).take(3),
        <String>['1', '2(a)', '2(b)'],
      );
      expect(paper.markable.first.maximumMarks, 2);
      expect(paper.markable.first.questionText, isEmpty);
      expect(paper.markable.first.markScheme, contains('ATP is produced'));
      expect(paper.markingGuidance, contains('Award one mark'));
      // No marking point was read as a question.
      expect(paper.markable, hasLength(9));
    });

    test('is not trusted when marking notes are mixed into the wording', () {
      final QuestionPaper paper = parser.parse('''
1 Define osmosis. [2 marks]
  Movement of water. Accept "diffusion of water". (1 mark)
2 Name the organelle. [1 mark]
''');
      expect(paper.warnings, isNotEmpty);
      expect(HeuristicQuestionPaperParser.isTrustworthy(paper), isFalse);
    });
  });

  group('choices', () {
    List<List<String>> options(QuestionPaper paper, [int index = 0]) =>
        paper.choices[index].options;

    test('an OR between two parts that have parts of their own', () {
      final QuestionPaper paper = parser.parse('''
Total marks: 14
1 Define osmosis. [2 marks]
2 (a) (i) Describe the heart. [6 marks]
(ii) Explain double circulation. [6 marks]
OR
(b) (i) Describe the lungs. [4 marks]
(ii) Explain gas exchange. [8 marks]
''');
      expect(paper.markable.map((Question q) => q.key),
          <String>['1', '2.a.i', '2.a.ii', '2.b.i', '2.b.ii']);
      expect(options(paper), <List<String>>[<String>['Q2a'], <String>['Q2b']]);
      expect(paper.byLabel(QuestionLabel.parse('2')!)!.maximumMarks, 12);
      expect(paper.totalMarks, 14);
      expect(paper.warnings, isEmpty);
      expect(HeuristicQuestionPaperParser.isTrustworthy(paper), isTrue);
    });

    test('an OR between groups of parts: a) b) OR c) d)', () {
      final QuestionPaper paper = parser.parse('''
1 (a) Describe the heart. [6 marks]
(b) Explain double circulation. [6 marks]
OR
(c) Describe the lungs. [4 marks]
(d) Explain gas exchange. [8 marks]
''');
      expect(options(paper), <List<String>>[
        <String>['Q1a', 'Q1b'],
        <String>['Q1c', 'Q1d'],
      ]);
      expect(paper.byLabel(QuestionLabel.parse('1')!)!.maximumMarks, 12);
      expect(paper.warnings, isEmpty);
    });

    test('an OR between neighbouring parts when that is what adds up', () {
      final QuestionPaper paper = parser.parse('''
1 (a) Name it. [2 marks]
(b) Explain it. [3 marks]
OR
(c) Describe it. [3 marks]
''');
      expect(options(paper), <List<String>>[<String>['Q1b'], <String>['Q1c']]);
      expect(paper.byLabel(QuestionLabel.parse('1')!)!.maximumMarks, 5);
    });

    test('an OR between whole questions', () {
      final QuestionPaper paper = parser.parse('''
Total marks: 22
1 Define osmosis. [2 marks]
2 Explain respiration. [10 marks]
OR
3 Explain photosynthesis. [10 marks]
4 Name an enzyme. [10 marks]
''');
      expect(options(paper), <List<String>>[<String>['Q2'], <String>['Q3']]);
      expect(paper.totalMarks, 22);
      expect(paper.warnings, isEmpty);
    });

    test('answer any N of a section', () {
      final QuestionPaper paper = parser.parse('''
SECTION A [20 marks]
Answer any two questions.
1 Define osmosis. [10 marks]
2 Define diffusion. [10 marks]
3 Define active transport. [10 marks]
''');
      expect(paper.choices.single.choose, 2);
      expect(options(paper), hasLength(3));
      expect(paper.totalMarks, 20);
      expect(paper.warnings, isEmpty);
    });

    test('an OR alternative with no label of its own is not trusted', () {
      final QuestionPaper paper = parser.parse('''
1 Explain respiration. [10 marks]
OR
Explain photosynthesis. [10 marks]
''');
      expect(paper.warnings.join(), contains('no number or letter'));
      expect(HeuristicQuestionPaperParser.isTrustworthy(paper), isFalse);
    });
  });
}
