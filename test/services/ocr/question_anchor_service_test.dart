import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';
import 'package:exam_corrector/services/ocr/question_anchor_service.dart';

import '../../state/fakes.dart';

const QuestionAnchorService service = QuestionAnchorService();

String? detect(String line, [String? current]) =>
    service.detectQuestion(line, current);

DocumentTranscript transcriptOf(List<TextLine> lines) {
  return DocumentTranscript(
    pages: <PageTranscript>[
      PageTranscript(
        index: 0,
        imagePath: '/pages/page_000.png',
        width: 1240,
        height: 1754,
        lines: lines,
      ),
    ],
    engine: 'trocr',
    detector: 'db_resnet50',
    dpi: 300,
    workdir: '/tmp/t',
  );
}

void main() {
  group('detecting a question number', () {
    test('reads a delimited number', () {
      expect(detect('1. Name the organelle'), '1');
      expect(detect('3) Calculate the magnification'), '3');
      expect(detect('4: Describe two ways'), '4');
    });

    test('reads a number with no delimiter at all', () {
      // How most papers are actually typeset, and what recognition returns.
      expect(detect('1 Name the organelle that carries out respiration'), '1');
      expect(detect('7 Define osmosis'), '7');
    });

    test('reads a parenthesised sub-part', () {
      expect(detect('2 (a) Write the word equation'), '2a');
      expect(detect('2(b) Explain why muscle cells'), '2b');
    });

    test('tolerates the spacing recognition introduces inside parentheses', () {
      // The real transcript of this page reads "2 ( a ) Write the word…".
      expect(detect('2 ( a ) Write the word equation'), '2a');
      expect(detect('2 ( b ) Explain why muscle cells contain'), '2b');
    });

    test('reads a sub-part written without parentheses', () {
      expect(detect('4a. Describe the adaptation'), '4a');
      expect(detect('5b) State one function'), '5b');
    });

    test('resolves a bare sub-part against the question in progress', () {
      expect(detect('(b) Explain why', '2'), '2b');
      expect(detect('c) State one reason', '2a'), '2c');
    });

    test('ignores a bare sub-part when no question has been seen', () {
      expect(detect('(b) Explain why', null), isNull);
    });
  });

  group('not mistaking working for a question', () {
    test('a measurement opening with a number is not a question', () {
      // The decisive case: "50" is a plausible question number, and reading
      // the student's working as question 50 would wreck the mapping.
      expect(detect('50 micrometres = 0.05 mm'), isNull);
      expect(detect('50 micrometres -0.05 mm.'), isNull);
    });

    test('a calculation line is not a question', () {
      expect(detect('= 100 / 0.05'), isNull);
      expect(detect('= 2000'), isNull);
      expect(detect('100 mm total'), isNull);
    });

    test('prose is not a question', () {
      expect(detect('Because muscle cells need a lot of energy,'), isNull);
      expect(detect('answer :'), isNull);
    });

    test('a lone marker with nothing after it is not a question', () {
      expect(detect('1.'), isNull);
      expect(detect('2 (a)'), isNull);
    });

    test('a three-digit number is never a question number', () {
      expect(detect('100 Describe the process'), isNull);
    });
  });

  group('anchoring a transcript', () {
    test('marks each detected question in the assembled text', () {
      final DocumentTranscript transcript = transcriptOf(<TextLine>[
        fakeLine('1 Name the organelle', y: 10),
        fakeLine('The mitochondrion. It makes ATP.', y: 50),
        fakeLine('2 ( a ) Write the word equation', y: 90),
        fakeLine('glucose + oxygen -> carbon dioxide', y: 130),
      ]);

      final AnchoredTranscript anchored = service.anchor(transcript);

      expect(anchored.text, contains('[[Q1]] 1 Name the organelle'));
      expect(anchored.text, contains('[[Q2a]] 2 ( a ) Write the word equation'));
      // The answers themselves are left untouched.
      expect(anchored.text, contains('\nThe mitochondrion. It makes ATP.'));
    });

    test('records where every anchor came from', () {
      final DocumentTranscript transcript = transcriptOf(<TextLine>[
        fakeLine('1 Name the organelle', y: 10),
        fakeLine('The mitochondrion.', y: 50),
        fakeLine('2 (a) Write the equation', y: 90),
      ]);

      final AnchoredTranscript anchored = service.anchor(transcript);

      expect(anchored.anchors, hasLength(2));
      expect(anchored.anchors.first.questionNumber, '1');
      expect(anchored.anchors.first.lineIndex, 0);
      expect(anchored.anchors.last.questionNumber, '2a');
      expect(anchored.anchors.last.lineIndex, 2);
    });

    test('traces any line back to the question it belongs to', () {
      final DocumentTranscript transcript = transcriptOf(<TextLine>[
        fakeLine('1 Name the organelle', y: 10),
        fakeLine('The mitochondrion.', y: 50),
        fakeLine('2 (a) Write the equation', y: 90),
        fakeLine('glucose + oxygen', y: 130),
      ]);

      final AnchoredTranscript anchored = service.anchor(transcript);

      expect(anchored.questionAt(0, 1), '1');
      expect(anchored.questionAt(0, 3), '2a');
    });

    test('keeps the page marker convention the text layer uses', () {
      final DocumentTranscript transcript =
          transcriptOf(<TextLine>[fakeLine('1 Name the organelle', y: 10)]);

      expect(service.anchor(transcript).text, startsWith('--- Page 1 ---\n'));
    });

    test('flags low-confidence lines without disturbing the anchor', () {
      final DocumentTranscript transcript = transcriptOf(<TextLine>[
        fakeLine('1 Name the organelle', confidence: 0.4, y: 10),
      ]);

      final AnchoredTranscript anchored =
          service.anchor(transcript, flagBelow: 0.92);

      expect(anchored.text, contains('⚠ [[Q1]] 1 Name the organelle'));
    });
  });
}
