import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/services/ocr/transcript_parser.dart';

const TranscriptParser parser = TranscriptParser();

Map<String, dynamic> payload({
  List<Map<String, dynamic>>? lines,
  List<Map<String, dynamic>>? pages,
}) {
  return <String, dynamic>{
    'pages': pages ??
        <Map<String, dynamic>>[
          <String, dynamic>{
            'index': 0,
            'image_path': '/pages/page_000.png',
            'width': 1240,
            'height': 1754,
            'lines': lines ?? <Map<String, dynamic>>[line()],
          },
        ],
    'engine': 'microsoft/trocr-large-handwritten',
    'detector': 'db_resnet50',
    'dpi': 300,
    'workdir': '/tmp/exam_ocr_x',
  };
}

Map<String, dynamic> line({
  Object? text = 'The mitochondrion makes ATP.',
  Object? confidence = 0.94,
  Object? box = const <int>[10, 20, 400, 30],
  Object? cropPath = '/crops/p000_l000.png',
}) {
  return <String, dynamic>{
    'text': text,
    'confidence': confidence,
    'box': box,
    'crop_path': cropPath,
  };
}

void main() {
  group('a well-formed response', () {
    test('is parsed into a transcript', () {
      final DocumentTranscript transcript = parser.parse(payload());

      expect(transcript.engine, 'microsoft/trocr-large-handwritten');
      expect(transcript.detector, 'db_resnet50');
      expect(transcript.dpi, 300);
      expect(transcript.workdir, '/tmp/exam_ocr_x');
      expect(transcript.lineCount, 1);
    });

    test('carries each line\'s geometry and crop', () {
      final DocumentTranscript transcript = parser.parse(payload());
      final line = transcript.pages[0].lines[0];

      expect(line.text, 'The mitochondrion makes ATP.');
      expect(line.confidence, closeTo(0.94, 1e-9));
      expect(line.box.x, 10);
      expect(line.box.width, 400);
      expect(line.cropPath, '/crops/p000_l000.png');
    });

    test('starts every line as its own original reading', () {
      // Nothing has edited it yet, so text and ocrText must agree — otherwise
      // the review screen would offer to revert a line to something else.
      final line = parser.parse(payload()).pages[0].lines[0];

      expect(line.text, line.ocrText);
      expect(line.isEdited, isFalse);
    });
  });

  group('a response that cannot be used', () {
    test('rejects something that is not an object', () {
      expect(() => parser.parse('nonsense'), throwsA(isA<OcrException>()));
    });

    test('rejects a response with no pages', () {
      expect(
        () => parser.parse(<String, dynamic>{'engine': 'trocr'}),
        throwsA(isA<OcrException>()),
      );
    });

    test('explains a document in which nothing was recognised', () {
      // A blank result is the single most likely real failure — an upside-down
      // scan, a blank page — so it gets an explanation, not a stack trace.
      expect(
        () => parser.parse(payload(lines: <Map<String, dynamic>>[])),
        throwsA(
          isA<OcrException>().having(
            (OcrException e) => e.message,
            'message',
            contains('right way up'),
          ),
        ),
      );
    });
  });

  group('a response with one bad line among good ones', () {
    test('drops the bad line and keeps the rest', () {
      // A single malformed line should cost that line, not the whole script
      // the teacher just waited minutes for.
      final DocumentTranscript transcript = parser.parse(
        payload(
          lines: <Map<String, dynamic>>[
            line(text: 'good one'),
            <String, dynamic>{'text': 'no box at all'},
            line(text: 'good two'),
          ],
        ),
      );

      expect(transcript.lineCount, 2);
      expect(
        transcript.pages[0].lines.map((l) => l.text),
        <String>['good one', 'good two'],
      );
    });

    test('drops a line with an empty text', () {
      final DocumentTranscript transcript = parser.parse(
        payload(
          lines: <Map<String, dynamic>>[line(text: '   '), line(text: 'kept')],
        ),
      );

      expect(transcript.lineCount, 1);
      expect(transcript.pages[0].lines.single.text, 'kept');
    });

    test('drops a line whose box has no area', () {
      final DocumentTranscript transcript = parser.parse(
        payload(
          lines: <Map<String, dynamic>>[
            line(box: const <int>[0, 0, 0, 0]),
            line(text: 'kept'),
          ],
        ),
      );

      expect(transcript.lineCount, 1);
    });
  });

  group('a confidence that makes no sense', () {
    test('is clamped rather than discarded', () {
      // The line's text may still be perfectly good; only the number is wrong.
      final DocumentTranscript transcript = parser.parse(
        payload(
          lines: <Map<String, dynamic>>[
            line(text: 'over', confidence: 4.2),
            line(text: 'under', confidence: -1),
          ],
        ),
      );

      expect(transcript.pages[0].lines[0].confidence, 1.0);
      expect(transcript.pages[0].lines[1].confidence, 0.0);
    });

    test('a missing confidence reads as no confidence', () {
      final DocumentTranscript transcript = parser.parse(
        payload(lines: <Map<String, dynamic>>[line(confidence: null)]),
      );

      expect(transcript.pages[0].lines.single.confidence, 0);
    });
  });
}
