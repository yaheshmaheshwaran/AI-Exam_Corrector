import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';
import 'package:exam_corrector/screens/review/transcript_review_screen.dart';
import 'package:exam_corrector/services/ai/vision_transcription_service.dart';
import 'package:exam_corrector/services/ocr/document_ingest_service.dart';
import 'package:exam_corrector/services/ocr/ocr_service.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/transcript_line_tile.dart';

import '../state/fakes.dart';

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

Future<CorrectionController> loadedController() async {
  final FakeOcrService ocr = FakeOcrService();

  final CorrectionController controller = CorrectionController(
    config: _config,
    correctionService: FakeCorrectionService(),
    filePicker: FakeFilePicker('/papers/scan.pdf'),
    settings: RecordingSettingsStore(),
    ocrService: ocr,
    ingestService: DocumentIngestService(
      configProvider: () => _config,
      ocrService: ocr,
      visionService: _NoCrossCheck(),
      pdfService: FakePdfService(hasTextLayer: false),
    ),
  );

  await controller.chooseAnswerSheet();
  return controller;
}

Future<void> pumpReview(
  WidgetTester tester,
  CorrectionController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(),
      home: TranscriptReviewScreen(controller: controller),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows every recognised line', (WidgetTester tester) async {
    final CorrectionController controller = await loadedController();

    await pumpReview(tester, controller);

    expect(find.byType(TranscriptLineTile), findsNWidgets(2));
    expect(find.text('1. The mitochondrion makes ATP.'), findsOneWidget);
    expect(find.text('2. The rate was 12.5 mol'), findsOneWidget);
  });

  testWidgets('groups lines under their page', (WidgetTester tester) async {
    final CorrectionController controller = await loadedController();

    await pumpReview(tester, controller);

    expect(find.text('Page 1'), findsOneWidget);
  });

  testWidgets('says how many lines are uncertain',
      (WidgetTester tester) async {
    final CorrectionController controller = await loadedController();

    await pumpReview(tester, controller);

    expect(find.textContaining('1 uncertain line'), findsOneWidget);
  });

  testWidgets('marks the uncertain line and not the confident one',
      (WidgetTester tester) async {
    final CorrectionController controller = await loadedController();

    await pumpReview(tester, controller);

    // The 0.42 line is flagged; the 0.95 line is not.
    expect(find.textContaining('Unsure'), findsOneWidget);
  });

  testWidgets('an edit reaches the controller', (WidgetTester tester) async {
    final CorrectionController controller = await loadedController();
    await pumpReview(tester, controller);

    await tester.enterText(
      find.byType(TextField).last,
      '2. The rate was 12.5 mol/s',
    );
    await tester.pump();

    final TextLine line = controller.transcript!.pages[0].lines[1];
    expect(line.text, '2. The rate was 12.5 mol/s');
    expect(line.source, OcrSource.teacher);
  });

  testWidgets('an edited line offers to revert, and does',
      (WidgetTester tester) async {
    final CorrectionController controller = await loadedController();
    await pumpReview(tester, controller);

    expect(find.byIcon(Icons.undo), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'changed by hand');
    await tester.pump();
    expect(find.byIcon(Icons.undo), findsOneWidget);

    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();

    expect(
      controller.transcript!.pages[0].lines[0].text,
      '1. The mitochondrion makes ATP.',
    );
  });

  testWidgets('filtering hides the confident lines',
      (WidgetTester tester) async {
    final CorrectionController controller = await loadedController();
    await pumpReview(tester, controller);

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(find.byType(TranscriptLineTile), findsOneWidget);
    expect(find.text('2. The rate was 12.5 mol'), findsOneWidget);
    expect(find.text('1. The mitochondrion makes ATP.'), findsNothing);
  });

  testWidgets('confirming accepts the transcript and closes the screen',
      (WidgetTester tester) async {
    final CorrectionController controller = await loadedController();

    // Pushed onto a route so the confirm button has something to pop.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: Builder(
          builder: (BuildContext context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    TranscriptReviewScreen(controller: controller),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Use this transcript'));
    await tester.pumpAndSettle();

    expect(controller.stage, CorrectionStage.idle);
    expect(find.byType(TranscriptReviewScreen), findsNothing);
  });

  testWidgets('warns that flagged lines will be marked as they read',
      (WidgetTester tester) async {
    final CorrectionController controller = await loadedController();

    await pumpReview(tester, controller);

    expect(find.textContaining('still flagged as uncertain'), findsOneWidget);
  });

  testWidgets('says so when there is nothing left to check',
      (WidgetTester tester) async {
    final CorrectionController controller = await loadedController();
    await pumpReview(tester, controller);

    await tester.enterText(find.byType(TextField).last, 'corrected by hand');
    await tester.pump();

    expect(find.textContaining('Nothing is still flagged'), findsOneWidget);
  });
}
