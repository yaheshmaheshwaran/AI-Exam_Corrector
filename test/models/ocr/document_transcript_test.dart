import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';

import '../../state/fakes.dart';

DocumentTranscript transcriptOf(List<List<TextLine>> pages) {
  return DocumentTranscript(
    pages: <PageTranscript>[
      for (int index = 0; index < pages.length; index++)
        PageTranscript(
          index: index,
          imagePath: '/pages/page_${index.toString().padLeft(3, '0')}.png',
          width: 1240,
          height: 1754,
          lines: pages[index],
        ),
    ],
    engine: 'microsoft/trocr-large-handwritten',
    detector: 'db_resnet50',
    dpi: 300,
    workdir: '/tmp/t',
  );
}

void main() {
  group('assembling the text the AI marks', () {
    test('uses the same page markers the text layer produces', () {
      // The controller compares the paper against the mark scheme by stripping
      // "--- Page N ---" lines; a different marker here would break that check
      // silently.
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[fakeLine('first page', y: 10)],
        <TextLine>[fakeLine('second page', y: 10)],
      ]);

      expect(
        transcript.toMarkedText(),
        '--- Page 1 ---\nfirst page\n\n--- Page 2 ---\nsecond page',
      );
    });

    test('keeps lines in order', () {
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[
          fakeLine('one', y: 10),
          fakeLine('two', y: 50),
          fakeLine('three', y: 90),
        ],
      ]);

      expect(transcript.toMarkedText(), contains('one\ntwo\nthree'));
    });

    test('flags only the lines below the threshold', () {
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[
          fakeLine('confident', confidence: 0.99, y: 10),
          fakeLine('unsure', confidence: 0.4, y: 50),
        ],
      ]);

      final String text = transcript.toMarkedText(flagBelow: 0.92);

      expect(text, contains('\nconfident'));
      expect(text, contains('⚠ unsure'));
    });

    test('flags nothing when no threshold is given', () {
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[fakeLine('unsure', confidence: 0.1, y: 10)],
      ]);

      expect(transcript.toMarkedText(), isNot(contains('⚠')));
    });

    test('never flags a line the teacher wrote', () {
      // A teacher's correction is the authority; marking it as doubtful would
      // invite the model to second-guess a human.
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[
          fakeLine('corrected', confidence: 0.1, y: 10)
              .copyWith(source: OcrSource.teacher),
        ],
      ]);

      expect(transcript.toMarkedText(flagBelow: 0.92), isNot(contains('⚠')));
    });
  });

  group('summarising', () {
    test('counts lines across every page', () {
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[fakeLine('a', y: 10), fakeLine('b', y: 50)],
        <TextLine>[fakeLine('c', y: 10)],
      ]);

      expect(transcript.lineCount, 3);
    });

    test('averages confidence across every line', () {
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[
          fakeLine('a', confidence: 1.0, y: 10),
          fakeLine('b', confidence: 0.5, y: 50),
        ],
      ]);

      expect(transcript.meanConfidence, closeTo(0.75, 1e-9));
    });

    test('an empty transcript averages zero rather than dividing by zero', () {
      expect(transcriptOf(<List<TextLine>>[<TextLine>[]]).meanConfidence, 0);
    });

    test('counts the uncertain lines at a given threshold', () {
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[
          fakeLine('a', confidence: 0.99, y: 10),
          fakeLine('b', confidence: 0.80, y: 50),
          fakeLine('c', confidence: 0.60, y: 90),
        ],
      ]);

      expect(transcript.uncertainCount(0.92), 2);
      expect(transcript.uncertainCount(0.70), 1);
    });

    test('counts the lines the teacher changed', () {
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[fakeLine('as read', y: 10), fakeLine('also as read', y: 50)],
      ]);

      final DocumentTranscript edited = transcript.withLine(
        0,
        0,
        transcript.pages[0].lines[0].copyWith(text: 'as corrected'),
      );

      expect(transcript.editedCount, 0);
      expect(edited.editedCount, 1);
    });
  });

  group('replacing lines', () {
    test('leaves the original transcript untouched', () {
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[fakeLine('original', y: 10)],
      ]);

      final DocumentTranscript updated = transcript.withLine(
        0,
        0,
        transcript.pages[0].lines[0].copyWith(text: 'changed'),
      );

      expect(transcript.pages[0].lines[0].text, 'original');
      expect(updated.pages[0].lines[0].text, 'changed');
    });

    test('keeps what the recogniser originally read', () {
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[fakeLine('as read', y: 10)],
      ]);

      final TextLine edited = transcript
          .withLine(
            0,
            0,
            transcript.pages[0].lines[0].copyWith(text: 'as corrected'),
          )
          .pages[0]
          .lines[0];

      expect(edited.text, 'as corrected');
      expect(edited.ocrText, 'as read');
      expect(edited.isEdited, isTrue);
    });

    test('ignores an index that is not there', () {
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[fakeLine('only', y: 10)],
      ]);

      final TextLine line = transcript.pages[0].lines[0];

      expect(transcript.withLine(9, 0, line).pages[0].lines[0].text, 'only');
      expect(transcript.withLine(0, 9, line).pages[0].lines[0].text, 'only');
    });

    test('applies many replacements across pages at once', () {
      final DocumentTranscript transcript = transcriptOf(<List<TextLine>>[
        <TextLine>[fakeLine('a', y: 10), fakeLine('b', y: 50)],
        <TextLine>[fakeLine('c', y: 10)],
      ]);

      final DocumentTranscript updated =
          transcript.withLines(<int, Map<int, TextLine>>{
        0: <int, TextLine>{
          1: transcript.pages[0].lines[1].copyWith(text: 'B'),
        },
        1: <int, TextLine>{
          0: transcript.pages[1].lines[0].copyWith(text: 'C'),
        },
      });

      expect(updated.pages[0].lines[0].text, 'a');
      expect(updated.pages[0].lines[1].text, 'B');
      expect(updated.pages[1].lines[0].text, 'C');
    });
  });
}
