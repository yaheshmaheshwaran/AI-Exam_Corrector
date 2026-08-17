import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/exam_paper.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';
import 'package:exam_corrector/services/ai/vision_transcription_service.dart';
import 'package:exam_corrector/services/ocr/document_ingest_service.dart';
import 'package:exam_corrector/services/ocr/ocr_service.dart';

import '../../state/fakes.dart';

/// A cross-check that never calls out, so ingest can be tested offline.
class _NoCrossCheck extends VisionTranscriptionService {
  _NoCrossCheck() : super(() => _config);

  @override
  Future<CrossCheckOutcome> crossCheck(
    DocumentTranscript transcript, {
    OcrProgress? onProgress,
  }) async {
    return CrossCheckOutcome(
      transcript: transcript,
      rechecked: 0,
      changed: 0,
    );
  }
}

const AppConfig _config = AppConfig(
  apiKey: 'test-key',
  model: 'gemini-3.6-flash',
  effort: 'high',
  maxTokens: 32000,
  ocrConfidenceThreshold: 0.92,
);

DocumentIngestService ingestWith({
  FakePdfService? pdf,
  FakeOcrService? ocr,
  AppConfig config = _config,
}) {
  return DocumentIngestService(
    configProvider: () => config,
    ocrService: ocr ?? FakeOcrService(),
    visionService: _NoCrossCheck(),
    pdfService: pdf ?? FakePdfService(),
  );
}

void main() {
  group('a PDF with a text layer', () {
    test('is read directly and never reaches the recogniser', () async {
      final FakeOcrService ocr = FakeOcrService();

      final IngestResult result = await ingestWith(
        pdf: FakePdfService(text: 'Question 1. The mitochondrion.'),
        ocr: ocr,
      ).loadDocument('/papers/typed.pdf');

      expect(result.document.source, ExamSource.textLayer);
      expect(result.document.text, 'Question 1. The mitochondrion.');
      expect(result.document.transcript, isNull);
      expect(result.needsReview, isFalse);
      expect(ocr.callCount, 0);
    });

    test('keeps its file name', () async {
      final IngestResult result =
          await ingestWith().loadDocument('/papers/typed.pdf');

      expect(result.document.fileName, 'typed.pdf');
    });
  });

  group('a scan with no text layer', () {
    test('is sent to the recogniser', () async {
      final FakeOcrService ocr = FakeOcrService();

      final IngestResult result = await ingestWith(
        pdf: FakePdfService(hasTextLayer: false),
        ocr: ocr,
      ).loadDocument('/papers/scan.pdf');

      expect(ocr.callCount, 1);
      expect(ocr.receivedPath, '/papers/scan.pdf');
      expect(result.document.source, ExamSource.ocr);
      expect(result.document.isHandwritten, isTrue);
      expect(result.needsReview, isTrue);
    });

    test('carries the transcript alongside the text', () async {
      final IngestResult result = await ingestWith(
        pdf: FakePdfService(hasTextLayer: false),
      ).loadDocument('/papers/scan.pdf');

      expect(result.document.transcript, isNotNull);
      expect(result.document.text, contains('--- Page 1 ---'));
      expect(result.document.text, contains('The mitochondrion makes ATP.'));
    });

    test('flags the lines the recogniser was unsure of', () async {
      final IngestResult result = await ingestWith(
        pdf: FakePdfService(hasTextLayer: false),
      ).loadDocument('/papers/scan.pdf');

      // The sample transcript's second line scores 0.42.
      expect(result.document.text, contains('⚠ 2. The rate was 12.5 mol'));
      expect(result.warnings.join(), contains('still uncertain'));
    });

    test('is rejected with an actionable message when OCR is off', () async {
      await expectLater(
        ingestWith(
          pdf: FakePdfService(hasTextLayer: false),
          config: _config.copyWith(ocrEnabled: false),
        ).loadDocument('/papers/scan.pdf'),
        throwsA(
          isA<PdfExtractionException>().having(
            (PdfExtractionException e) => e.message,
            'message',
            contains('Turn on handwriting recognition'),
          ),
        ),
      );
    });
  });

  group('a photograph', () {
    test('goes straight to the recogniser without a PDF attempt', () async {
      final FakeOcrService ocr = FakeOcrService();

      final IngestResult result = await ingestWith(ocr: ocr)
          .loadDocument('/papers/scan.jpg');

      expect(ocr.callCount, 1);
      expect(result.document.source, ExamSource.ocr);
    });

    test('is recognised whatever the case of its extension', () async {
      final IngestResult result =
          await ingestWith().loadDocument('/papers/SCAN.PNG');

      expect(result.document.source, ExamSource.ocr);
    });

    test('is refused when OCR is off, since there is no text layer to try',
        () async {
      await expectLater(
        ingestWith(config: _config.copyWith(ocrEnabled: false))
            .loadDocument('/papers/scan.png'),
        throwsA(isA<OcrException>()),
      );
    });
  });

  group('normalisation', () {
    test('tidies recognition artefacts in the stored lines', () async {
      final DocumentTranscript messy = DocumentTranscript(
        pages: <PageTranscript>[
          PageTranscript(
            index: 0,
            imagePath: '/pages/page_000.png',
            width: 100,
            height: 100,
            lines: <TextLine>[fakeLine('the cell’s   wall', y: 10)],
          ),
        ],
        engine: 'trocr',
        detector: 'db_resnet50',
        dpi: 300,
        workdir: '/tmp/t',
      );

      final IngestResult result = await ingestWith(
        pdf: FakePdfService(hasTextLayer: false),
        ocr: FakeOcrService(transcript: messy),
      ).loadDocument('/papers/scan.pdf');

      final TextLine line = result.document.transcript!.pages[0].lines[0];

      expect(line.text, "the cell's wall");
      // The original reading is preserved so review can still show it.
      expect(line.ocrText, 'the cell’s   wall');
    });
  });

  group('failures', () {
    test('a recogniser failure surfaces as an OCR error', () async {
      await expectLater(
        ingestWith(
          pdf: FakePdfService(hasTextLayer: false),
          ocr: FakeOcrService(error: 'The sidecar died.'),
        ).loadDocument('/papers/scan.pdf'),
        throwsA(isA<OcrException>()),
      );
    });

    test('a corrupt PDF still fails as a PDF problem, not an OCR one', () async {
      // OCR cannot rescue a file that will not open, and saying so would send
      // the teacher chasing the wrong fix.
      await expectLater(
        ingestWith(pdf: FakePdfService(error: 'This file is not a valid PDF.'))
            .loadDocument('/papers/broken.pdf'),
        throwsA(isA<PdfExtractionException>()),
      );
    });
  });

  test('progress is reported while recognising', () async {
    final List<String> messages = <String>[];

    await ingestWith(pdf: FakePdfService(hasTextLayer: false)).loadDocument(
      '/papers/scan.pdf',
      onProgress: (String message, double fraction) => messages.add(message),
    );

    expect(messages, isNotEmpty);
  });
}
