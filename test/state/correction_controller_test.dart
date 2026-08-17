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

const String _answerPath = 'C:\\papers\\answers.pdf';
const String _questionPath = 'C:\\papers\\questions.pdf';

const String _answerText = '1. The mitochondrion. It makes ATP.';
const String _questionText = 'SECTION A\n1. Name the organelle. [2 marks]';

/// A controller whose two slots read genuinely different documents, which is
/// what marking actually requires.
CorrectionController twoDocumentController({
  FakeCorrectionService? correctionService,
  String answerText = _answerText,
  String questionText = _questionText,
}) {
  return CorrectionController(
    config: configuredApp,
    correctionService: correctionService ?? FakeCorrectionService(),
    pdfService: FakePdfService(
      textByPath: <String, String>{
        _answerPath: answerText,
        _questionPath: questionText,
      },
    ),
    filePicker: FakeFilePicker(_answerPath, _questionPath),
    settings: RecordingSettingsStore(),
  );
}

Future<void> loadBoth(CorrectionController controller) async {
  await controller.chooseAnswerSheet();
  await controller.chooseQuestionPaper();
}

void main() {
  group('answer sheet', () {
    test('loads and reports it', () async {
      final CorrectionController controller = buildController();

      await controller.chooseAnswerSheet();

      expect(controller.answerSheet, isNotNull);
      expect(controller.answerSheet!.fileName, 'paper.pdf');
      expect(controller.statusMessage, 'Answer sheet loaded.');
      expect(controller.statusIsError, isFalse);
    });

    test('surfaces an unreadable PDF without keeping it', () async {
      final CorrectionController controller = buildController(
        pdfService: FakePdfService(error: 'No readable text was found.'),
      );

      await controller.chooseAnswerSheet();

      expect(controller.answerSheet, isNull);
      expect(controller.pendingError, 'No readable text was found.');
      expect(controller.statusIsError, isTrue);
    });

    test('does nothing when the dialog is cancelled', () async {
      final CorrectionController controller =
          buildController(pickedPath: null);

      await controller.chooseAnswerSheet();

      expect(controller.answerSheet, isNull);
      expect(controller.statusMessage, 'Ready.');
    });
  });

  group('question paper', () {
    test('loads and reports it', () async {
      final CorrectionController controller = buildController(
        pdfService: FakePdfService(text: 'Section A\n1. Name it. [2 marks]'),
      );

      await controller.chooseQuestionPaper();

      expect(controller.questionPaper, isNotNull);
      expect(controller.questionPaper!.text, contains('[2 marks]'));
      expect(controller.statusMessage, 'Question paper loaded.');
    });

    test('is kept separate from the answer sheet', () async {
      final CorrectionController controller = buildController();

      await controller.chooseAnswerSheet();
      expect(controller.questionPaper, isNull);

      await controller.chooseQuestionPaper();
      expect(controller.answerSheet, isNotNull);
      expect(controller.questionPaper, isNotNull);
    });

    test('naming the failure says which document it was', () async {
      final CorrectionController controller = buildController(
        pdfService: FakePdfService(error: 'This file is not a valid PDF.'),
      );

      await controller.chooseQuestionPaper();

      expect(controller.questionPaper, isNull);
      expect(controller.statusMessage, contains('question paper'));
    });
  });

  group('marking guidance', () {
    test('starts empty and stays optional', () {
      final CorrectionController controller = buildController();

      expect(controller.guidance.isEmpty, isTrue);
    });

    test('clears on request', () {
      final CorrectionController controller = buildController()
        ..setGuidance('Section A: one mark each.')
        ..clearGuidance();

      expect(controller.guidance.isEmpty, isTrue);
    });
  });

  group('correction', () {
    test('needs both documents, and only those', () async {
      final CorrectionController controller = buildController();
      expect(controller.canCorrect, isFalse);

      await controller.chooseAnswerSheet();
      expect(controller.canCorrect, isFalse,
          reason: 'the question paper supplies the marks');

      await controller.chooseQuestionPaper();
      expect(controller.canCorrect, isTrue,
          reason: 'guidance is optional, so this is enough');
    });

    test('sends each document to its own slot, then shows marks', () async {
      final FakeCorrectionService ai = FakeCorrectionService();
      final CorrectionController controller =
          twoDocumentController(correctionService: ai);

      await loadBoth(controller);
      await controller.startCorrection();

      expect(ai.callCount, 1);
      // Crossing these over would mark the questions against themselves.
      expect(ai.receivedAnswerSheet, _answerText);
      expect(ai.receivedQuestionPaper, _questionText);

      expect(controller.result, isNotNull);
      expect(controller.result!.questions, hasLength(1));
      expect(controller.statusMessage, 'Marked 1 question: 1 / 2 (50%).');
      expect(controller.statusIsError, isFalse);
      expect(controller.isBusy, isFalse);
    });

    test('sends no guidance when the teacher wrote none', () async {
      final FakeCorrectionService ai = FakeCorrectionService();
      final CorrectionController controller =
          twoDocumentController(correctionService: ai);

      await loadBoth(controller);
      await controller.startCorrection();

      expect(ai.receivedGuidance, isEmpty);
    });

    test('passes the guidance through, trimmed, when there is some', () async {
      final FakeCorrectionService ai = FakeCorrectionService();
      final CorrectionController controller =
          twoDocumentController(correctionService: ai);

      await loadBoth(controller);
      controller.setGuidance('  Section A: one mark each.  ');
      await controller.startCorrection();

      expect(ai.receivedGuidance, 'Section A: one mark each.');
    });

    test('does not treat two typed documents as handwriting', () async {
      final FakeCorrectionService ai = FakeCorrectionService();
      final CorrectionController controller =
          twoDocumentController(correctionService: ai);

      await loadBoth(controller);
      await controller.startCorrection();

      expect(ai.receivedFromHandwriting, isFalse);
    });

    test('refuses when both slots hold the same document', () async {
      // Choosing the question paper twice marks every question "No answer
      // found" and spends a request to discover it.
      final FakeCorrectionService ai = FakeCorrectionService();
      final CorrectionController controller = buildController(
        pdfService: FakePdfService(text: '--- Page 1 ---\n1. Name it.'),
        correctionService: ai,
      );

      await loadBoth(controller);
      await controller.startCorrection();

      expect(ai.callCount, 0, reason: 'no request should be spent');
      expect(controller.result, isNull);
      expect(controller.pendingError, contains('same document'));
      expect(controller.pendingError, contains('paper.pdf'));
    });

    test('asks for the question paper when only the answer sheet is loaded',
        () async {
      final FakeCorrectionService ai = FakeCorrectionService();
      final CorrectionController controller =
          buildController(correctionService: ai);

      await controller.chooseAnswerSheet();
      await controller.startCorrection();

      expect(ai.callCount, 0);
      expect(controller.pendingError, contains('question paper'));
      expect(controller.pendingError, contains('how many marks'));
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

    test('saving a key in Settings clears the warning', () async {
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
