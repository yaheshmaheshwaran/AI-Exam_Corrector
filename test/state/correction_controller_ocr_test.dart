import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/models/exam_paper.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';
import 'package:exam_corrector/services/ai/vision_transcription_service.dart';
import 'package:exam_corrector/services/ocr/document_ingest_service.dart';
import 'package:exam_corrector/services/ocr/ocr_service.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'fakes.dart';

const AppConfig _config = AppConfig(
  apiKey: 'test-key',
  model: 'gemini-3.6-flash',
  effort: 'high',
  maxTokens: 32000,
  ocrConfidenceThreshold: 0.92,
);

class _NoCrossCheck extends VisionTranscriptionService {
  _NoCrossCheck() : super(() => _config);

  @override
  Future<CrossCheckOutcome> crossCheck(
    DocumentTranscript transcript, {
    OcrProgress? onProgress,
  }) async =>
      CrossCheckOutcome(transcript: transcript, rechecked: 0, changed: 0);
}

const String _answerPath = '/papers/scan.pdf';
const String _questionPath = '/papers/questions.pdf';

/// The realistic pairing: a handwritten answer sheet and a typed question
/// paper. The answer sheet is picked first, matching the order of the steps.
CorrectionController controllerWith({
  FakeCorrectionService? correction,
  FakeOcrService? ocr,
  bool answerSheetIsScanned = true,
}) {
  final FakeOcrService recogniser = ocr ?? FakeOcrService();

  return CorrectionController(
    config: _config,
    correctionService: correction ?? FakeCorrectionService(),
    filePicker: FakeFilePicker(_answerPath, _questionPath),
    settings: RecordingSettingsStore(),
    ocrService: recogniser,
    ingestService: DocumentIngestService(
      configProvider: () => _config,
      ocrService: recogniser,
      visionService: _NoCrossCheck(),
      pdfService: FakePdfService(
        scannedPaths: answerSheetIsScanned ? <String>{_answerPath} : <String>{},
        textByPath: const <String, String>{
          _questionPath: 'SECTION A\n1. Name the organelle. [2 marks]',
          _answerPath: '1. The mitochondrion makes ATP.',
        },
      ),
    ),
  );
}

/// Loads the answer sheet, accepts its transcript, then the question paper.
Future<void> loadBoth(CorrectionController controller) async {
  await controller.chooseAnswerSheet();
  if (controller.isReviewingTranscript) controller.confirmTranscript();
  await controller.chooseQuestionPaper();
}

void main() {
  group('choosing a handwritten paper', () {
    test('stops for review instead of becoming ready to mark', () async {
      final CorrectionController controller = controllerWith();

      await controller.chooseAnswerSheet();

      expect(controller.stage, CorrectionStage.reviewingTranscript);
      expect(controller.isReviewingTranscript, isTrue);
      expect(controller.answerSheet?.isHandwritten, isTrue);
      expect(controller.transcript, isNotNull);
    });

    test('cannot be marked while the transcript is under review', () async {
      final CorrectionController controller = controllerWith();

      await controller.chooseAnswerSheet();
      expect(controller.canCorrect, isFalse, reason: 'review is still open');

      controller.confirmTranscript();
      await controller.chooseQuestionPaper();
      expect(controller.stage, CorrectionStage.idle);
      expect(controller.canCorrect, isTrue);

      // Reopening it withdraws readiness again, so a paper cannot be marked
      // out from under a transcript the teacher is still editing.
      controller.reopenTranscript();
      expect(controller.canCorrect, isFalse);
    });

    test('reports how many lines still need attention', () async {
      final CorrectionController controller = controllerWith();

      await controller.chooseAnswerSheet();

      // The sample transcript's second line scores 0.42.
      expect(controller.uncertainLineCount, 1);
      expect(controller.ingestWarnings, isNotEmpty);
    });

    test('reports progress while recognising', () async {
      final CorrectionController controller = controllerWith();
      final List<String> statuses = <String>[];
      controller.addListener(() => statuses.add(controller.statusMessage));

      await controller.chooseAnswerSheet();

      expect(statuses, contains('Reading page 1 of 1…'));
    });
  });

  test('a typed paper skips review entirely', () async {
    final CorrectionController controller = controllerWith(answerSheetIsScanned: false);

    await controller.chooseAnswerSheet();

    expect(controller.stage, CorrectionStage.idle);
    expect(controller.answerSheet?.source, ExamSource.textLayer);
    expect(controller.transcript, isNull);
  });

  group('correcting a line', () {
    test('replaces the text and records the teacher as its source', () async {
      final CorrectionController controller = controllerWith();
      await controller.chooseAnswerSheet();

      controller.updateLine(0, 1, '2. The rate was 12.5 mol/s');

      final TextLine line = controller.transcript!.pages[0].lines[1];
      expect(line.text, '2. The rate was 12.5 mol/s');
      expect(line.source, OcrSource.teacher);
      expect(line.isEdited, isTrue);
    });

    test('a corrected line is no longer uncertain', () async {
      final CorrectionController controller = controllerWith();
      await controller.chooseAnswerSheet();
      expect(controller.uncertainLineCount, 1);

      controller.updateLine(0, 1, 'corrected by hand');

      expect(controller.uncertainLineCount, 0);
    });

    test('rebuilds the text that will be marked', () async {
      final CorrectionController controller = controllerWith();
      await controller.chooseAnswerSheet();

      controller.updateLine(0, 1, 'the corrected reading');

      expect(controller.answerSheet!.text, contains('the corrected reading'));
      expect(controller.answerSheet!.text, isNot(contains('12.5 mol')));
    });

    test('a corrected line is no longer flagged to the model', () async {
      final CorrectionController controller = controllerWith();
      await controller.chooseAnswerSheet();
      expect(controller.answerSheet!.text, contains('⚠'));

      controller.updateLine(0, 1, 'the corrected reading');

      expect(controller.answerSheet!.text, isNot(contains('⚠')));
    });

    test('reverting restores what the recogniser read', () async {
      final CorrectionController controller = controllerWith();
      await controller.chooseAnswerSheet();

      controller.updateLine(0, 0, 'something else');
      controller.revertLine(0, 0);

      final TextLine line = controller.transcript!.pages[0].lines[0];
      expect(line.text, '1. The mitochondrion makes ATP.');
      expect(line.isEdited, isFalse);
    });

    test('ignores an index that is not there', () async {
      final CorrectionController controller = controllerWith();
      await controller.chooseAnswerSheet();

      controller.updateLine(9, 9, 'nowhere');

      expect(controller.transcript!.pages[0].lines[0].text,
          '1. The mitochondrion makes ATP.');
    });
  });

  group('confirming', () {
    test('says how many corrections were made', () async {
      final CorrectionController controller = controllerWith();
      await controller.chooseAnswerSheet();

      controller.updateLine(0, 1, 'corrected');
      controller.confirmTranscript();

      expect(controller.statusMessage, contains('1 correction'));
    });

    test('says so when nothing was changed', () async {
      final CorrectionController controller = controllerWith();
      await controller.chooseAnswerSheet();

      controller.confirmTranscript();

      expect(controller.statusMessage, contains('as recognised'));
    });

    test('the transcript can be reopened afterwards', () async {
      final CorrectionController controller = controllerWith();
      await controller.chooseAnswerSheet();
      controller.confirmTranscript();

      controller.reopenTranscript();

      expect(controller.stage, CorrectionStage.reviewingTranscript);
    });
  });

  group('marking a handwritten paper', () {
    test('tells the correction service the text came from OCR', () async {
      // Without this the model marks transcription noise as the student's own
      // spelling errors.
      final FakeCorrectionService correction = FakeCorrectionService();
      final CorrectionController controller =
          controllerWith(correction: correction);

      await loadBoth(controller);
      await controller.startCorrection();

      expect(correction.receivedFromHandwriting, isTrue);
    });

    test('marks the corrected transcript, not the raw recognition', () async {
      final FakeCorrectionService correction = FakeCorrectionService();
      final CorrectionController controller =
          controllerWith(correction: correction);

      await controller.chooseAnswerSheet();
      controller.updateLine(0, 1, '2. The rate was 12.5 mol per second');
      controller.confirmTranscript();
      await controller.chooseQuestionPaper();
      await controller.startCorrection();

      expect(correction.receivedAnswerSheet, contains('mol per second'));
    });

    test('a typed paper is not marked as handwriting', () async {
      final FakeCorrectionService correction = FakeCorrectionService();
      final CorrectionController controller = controllerWith(
        correction: correction,
        answerSheetIsScanned: false,
      );

      await loadBoth(controller);
      await controller.startCorrection();

      expect(correction.receivedFromHandwriting, isFalse);
    });
  });

  test('a recogniser failure is reported and leaves no paper', () async {
    final CorrectionController controller = controllerWith(
      ocr: FakeOcrService(error: 'The handwriting recogniser is not installed.'),
    );

    await controller.chooseAnswerSheet();

    expect(controller.answerSheet, isNull);
    expect(controller.stage, CorrectionStage.idle);
    expect(controller.statusIsError, isTrue);
    expect(controller.pendingError, contains('not installed'));
  });

  test('an empty page list still leaves the transcript addressable', () async {
    final DocumentTranscript single = DocumentTranscript(
      pages: <PageTranscript>[
        PageTranscript(
          index: 0,
          imagePath: '/pages/page_000.png',
          width: 10,
          height: 10,
          lines: <TextLine>[fakeLine('only line', y: 5)],
        ),
      ],
      engine: 'trocr',
      detector: 'db_resnet50',
      dpi: 300,
      workdir: '/tmp/t',
    );

    final CorrectionController controller =
        controllerWith(ocr: FakeOcrService(transcript: single));
    await controller.chooseAnswerSheet();

    expect(controller.transcript!.lineCount, 1);
    expect(controller.uncertainLineCount, 0);
  });
}
