import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/services/settings_store.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'fakes.dart';

CorrectionController buildController({
  FakePdfService? pdfService,
  FakeCorrectionService? correctionService,
  String? pickedPath = 'C:\\papers\\paper.pdf',
  AppConfig config = configuredApp,
  SettingsStore? settings,
}) {
  return CorrectionController(
    config: config,
    correctionService: correctionService ?? FakeCorrectionService(),
    pdfService: pdfService ?? FakePdfService(),
    filePicker: FakeFilePicker(pickedPath),
    settings: settings ?? RecordingSettingsStore(),
  );
}

void main() {
  group('exam paper', () {
    test('loads the paper and reports it', () async {
      final CorrectionController controller = buildController();

      await controller.chooseExamPaper();

      expect(controller.paper, isNotNull);
      expect(controller.paper!.fileName, 'paper.pdf');
      expect(controller.statusMessage, 'Exam paper loaded.');
      expect(controller.statusIsError, isFalse);
    });

    test('surfaces an unreadable PDF without keeping the paper', () async {
      final CorrectionController controller = buildController(
        pdfService: FakePdfService(error: 'No readable text was found.'),
      );

      await controller.chooseExamPaper();

      expect(controller.paper, isNull);
      expect(controller.pendingError, 'No readable text was found.');
      expect(controller.statusIsError, isTrue);
    });

    test('does nothing when the dialog is cancelled', () async {
      final CorrectionController controller =
          buildController(pickedPath: null);

      await controller.chooseExamPaper();

      expect(controller.paper, isNull);
      expect(controller.statusMessage, 'Ready.');
    });
  });

  group('mark scheme', () {
    test('loads from a PDF', () async {
      final CorrectionController controller = buildController(
        pdfService: FakePdfService(text: 'Question 1 (2 marks): names ATP.'),
      );

      await controller.loadMarkSchemeFromPdf();

      expect(controller.markScheme.trimmed, contains('names ATP'));
      expect(controller.statusMessage, 'Mark scheme loaded.');
    });

    test('clears on request', () {
      final CorrectionController controller = buildController()
        ..setMarkScheme('Question 1 (2 marks)')
        ..clearMarkScheme();

      expect(controller.markScheme.isEmpty, isTrue);
    });
  });

  group('correction', () {
    test('is blocked until both inputs are present', () async {
      final CorrectionController controller = buildController();
      expect(controller.canCorrect, isFalse);

      await controller.chooseExamPaper();
      expect(controller.canCorrect, isFalse);

      controller.setMarkScheme('Question 1 (2 marks): names ATP.');
      expect(controller.canCorrect, isTrue);
    });

    test('sends the extracted paper and mark scheme, then shows marks',
        () async {
      final FakeCorrectionService ai = FakeCorrectionService();
      final CorrectionController controller = buildController(
        pdfService: FakePdfService(text: 'Extracted paper.'),
        correctionService: ai,
      );

      await controller.chooseExamPaper();
      controller.setMarkScheme('  Question 1 (2 marks): names ATP.  ');
      await controller.startCorrection();

      expect(ai.callCount, 1);
      expect(ai.receivedPaper, 'Extracted paper.');
      expect(ai.receivedMarkScheme, 'Question 1 (2 marks): names ATP.');

      expect(controller.result, isNotNull);
      expect(controller.result!.questions, hasLength(1));
      expect(controller.statusMessage, 'Marked 1 question: 1 / 2 (50%).');
      expect(controller.statusIsError, isFalse);
      expect(controller.isBusy, isFalse);
    });

    test('refuses when the paper and the mark scheme are the same document',
        () async {
      // Choosing the mark scheme in step 1 marks every question "No answer
      // found" and spends a request to discover it.
      const String scheme = 'Question 1 (2 marks)\n  1. Names ATP (1 mark)';
      final FakeCorrectionService ai = FakeCorrectionService();
      final CorrectionController controller = buildController(
        pdfService: FakePdfService(text: '--- Page 1 ---\n$scheme'),
        correctionService: ai,
      );

      await controller.chooseExamPaper();
      controller.setMarkScheme(scheme);
      await controller.startCorrection();

      expect(ai.callCount, 0, reason: 'no request should be spent');
      expect(controller.result, isNull);
      expect(controller.pendingError, contains('same document'));
      expect(controller.pendingError, contains('paper.pdf'));
    });

    test('marks normally when the two documents differ', () async {
      final FakeCorrectionService ai = FakeCorrectionService();
      final CorrectionController controller = buildController(
        pdfService: FakePdfService(text: 'Answer: the mitochondrion.'),
        correctionService: ai,
      );

      await controller.chooseExamPaper();
      controller.setMarkScheme('Question 1 (2 marks): names ATP.');
      await controller.startCorrection();

      expect(ai.callCount, 1);
      expect(controller.result, isNotNull);
    });

    test('reports a correction failure and keeps the app usable', () async {
      final CorrectionController controller = buildController(
        correctionService:
            FakeCorrectionService(error: 'The API key was rejected.'),
      );

      await controller.chooseExamPaper();
      controller.setMarkScheme('Question 1 (2 marks): names ATP.');
      await controller.startCorrection();

      expect(controller.result, isNull);
      expect(controller.pendingError, 'The API key was rejected.');
      expect(controller.statusMessage, 'Correction failed.');
      expect(controller.statusIsError, isTrue);
      expect(controller.isBusy, isFalse);
      expect(controller.canCorrect, isTrue);
    });

    test('warns at startup when no API key is configured', () {
      final CorrectionController controller = buildController(
        config: const AppConfig(
          apiKey: null,
          model: 'gemini-3.7-flash',
          effort: 'high',
          maxTokens: 32000,
        ),
      );

      expect(controller.statusIsError, isTrue);
      expect(controller.statusMessage, contains('Settings'));
    });

    test('saving a key in Settings clears the warning and arms correction',
        () async {
      final RecordingSettingsStore store = RecordingSettingsStore();
      final CorrectionController controller = buildController(
        config: const AppConfig(
          apiKey: null,
          model: 'gemini-3.7-flash',
          effort: 'high',
          maxTokens: 32000,
        ),
        settings: store,
      );
      expect(controller.config.hasApiKey, isFalse);

      await controller.saveSettings(
        apiKey: '  a-new-key  ',
        model: 'gemini-3.5-flash',
      );

      expect(store.saved, 'a-new-key');
      expect(controller.config.hasApiKey, isTrue);
      expect(controller.config.apiKey, 'a-new-key');
      expect(controller.statusIsError, isFalse);
      // The chosen model is applied; limits are untouched.
      expect(store.savedModel, 'gemini-3.5-flash');
      expect(controller.config.model, 'gemini-3.5-flash');
      expect(controller.config.maxTokens, 32000);
    });
  });
}
