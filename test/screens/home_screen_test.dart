import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/services/settings_store.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import '../state/fakes.dart';

const String _answerPath = 'C:\\papers\\answers.pdf';
const String _questionPath = 'C:\\papers\\questions.pdf';

CorrectionController _controller({
  FakePdfService? pdfService,
  FakeCorrectionService? correctionService,
  AppConfig config = configuredApp,
  SettingsStore? settings,
}) {
  return CorrectionController(
    config: config,
    correctionService: correctionService ?? FakeCorrectionService(),
    pdfService: pdfService ??
        FakePdfService(
          textByPath: const <String, String>{
            _answerPath: '1. The mitochondrion makes ATP.',
            _questionPath: 'SECTION A\n1. Name the organelle. [2 marks]',
          },
        ),
    filePicker: FakeFilePicker(_answerPath, _questionPath),
    settings: settings ?? RecordingSettingsStore(),
  );
}

/// Fills both document slots by tapping the two Choose buttons in order.
Future<void> _chooseBoth(WidgetTester tester) async {
  await tester.tap(find.text('Choose…').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Choose…').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('walks the teacher from upload to marks', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ExamCorrectorApp(controller: _controller()));

    // The four workflow steps are on screen, and nothing is marked yet.
    expect(find.text("1. Student's answer sheet"), findsOneWidget);
    expect(find.text('2. Question paper'), findsOneWidget);
    expect(find.text('3. Marking guidance (optional)'), findsOneWidget);
    expect(find.text('4. Correction result'), findsOneWidget);
    expect(find.text('Correction results will appear here.'), findsOneWidget);

    // Correction is unavailable until both documents exist.
    FilledButton correctButton() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Correct paper'));
    expect(correctButton().onPressed, isNull);

    // Step 1 — the answer sheet alone is not enough.
    await tester.tap(find.text('Choose…').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('answers.pdf'), findsOneWidget);
    expect(correctButton().onPressed, isNull);

    // Step 2 — the question paper arms it, with no guidance typed.
    await tester.tap(find.text('Choose…').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('questions.pdf'), findsOneWidget);
    expect(correctButton().onPressed, isNotNull);

    // Step 4 — correct.
    await tester.tap(find.text('Correct paper'));
    await tester.pumpAndSettle();

    // Marks, reasoning and marking points for the question.
    expect(find.text('Question 1'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.textContaining('Maximum marks: 2'), findsOneWidget);
    expect(find.text('Names ATP  (1)'), findsOneWidget);
    expect(find.text('Identifies the site'), findsOneWidget);
    expect(find.text('The mitochondrion makes ATP.'), findsOneWidget);
    expect(find.text('Names ATP but omits the site.'), findsOneWidget);

    // The total and the percentage.
    expect(find.text('Total marks: 1 / 2'), findsOneWidget);
    expect(find.text('Percentage: 50%'), findsOneWidget);
    expect(find.text('Marked 1 question: 1 / 2 (50%).'), findsOneWidget);
    // Which model produced the marks, since a quota fallback can change it.
    expect(find.text('Marked by gemini-3.6-flash'), findsOneWidget);
  });

  testWidgets('shows a correction failure in a dialog', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ExamCorrectorApp(
        controller: _controller(
          correctionService: FakeCorrectionService(
            error: 'The API key was rejected. Check GEMINI_API_KEY.',
          ),
        ),
      ),
    );

    await _chooseBoth(tester);
    await tester.tap(find.text('Correct paper'));
    await tester.pumpAndSettle();

    expect(find.text('Correction could not continue'), findsOneWidget);
    expect(
      find.text('The API key was rejected. Check GEMINI_API_KEY.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Dismissed, and the teacher can try again.
    expect(find.text('Correction could not continue'), findsNothing);
    expect(find.text('Correction failed.'), findsOneWidget);
  });

  testWidgets('reports an unreadable PDF before any marking', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ExamCorrectorApp(
        controller: _controller(
          pdfService: FakePdfService(
            error: 'No readable text was found in this PDF.',
          ),
        ),
      ),
    );

    await tester.tap(find.text('Choose…').first);
    await tester.pumpAndSettle();

    expect(
      find.text('No readable text was found in this PDF.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Choose the completed script'),
      findsOneWidget,
    );
  });

  testWidgets('keeps the optional guidance out of the way until used',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final CorrectionController controller = _controller();
    await tester.pumpWidget(ExamCorrectorApp(controller: controller));

    // Empty to begin with, and marking is armed without it.
    await _chooseBoth(tester);
    expect(controller.guidance.isEmpty, isTrue);
    expect(
      tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Correct paper'))
          .onPressed,
      isNotNull,
    );

    await tester.enterText(
      find.byKey(const Key('guidance-input')),
      'Section A: one mark each.',
    );
    await tester.pump();
    expect(controller.guidance.trimmed, 'Section A: one mark each.');

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(controller.guidance.isEmpty, isTrue);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('guidance-input')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('explains a paper where no answers were found',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ExamCorrectorApp(
        controller: _controller(
          correctionService: FakeCorrectionService(result: unansweredResult),
        ),
      ),
    );

    await _chooseBoth(tester);
    await tester.tap(find.text('Correct paper'));
    await tester.pumpAndSettle();

    // Zero out of everything is far more often the wrong file than a blank
    // script, so the result says which file to check.
    expect(
      find.text('No answers were found anywhere in this paper'),
      findsOneWidget,
    );
    expect(find.textContaining('easy to choose the blank question paper'),
        findsOneWidget);
    expect(find.text('Total marks: 0 / 2'), findsOneWidget);
  });

  group('layout', () {
    // The window was overflowing at ordinary desktop sizes; every size the
    // teacher can drag the window to must lay out cleanly.
    for (final Size size in <Size>[
      Size(1180, 900), // default window
      Size(1000, 830), // the size that overflowed
      Size(900, 700),
      Size(800, 560), // below the comfortable height: the page scrolls
      Size(640, 480), // smallest sensible window
      Size(1920, 1080), // maximised
    ]) {
      testWidgets('lays out without overflow at ${size.width}x${size.height}',
          (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(ExamCorrectorApp(controller: _controller()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // …and with a result on screen, which is the taller state.
        await _chooseBoth(tester);
        await tester.tap(find.text('Correct paper'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Total marks: 1 / 2'), findsOneWidget);
      });
    }
  });

  group('settings', () {
    testWidgets('warns when no key is set, then accepts one',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final RecordingSettingsStore store = RecordingSettingsStore();
      final CorrectionController controller = _controller(
        config: const AppConfig(
          apiKey: null,
          model: 'gemini-3.7-flash',
          effort: 'high',
          maxTokens: 32000,
        ),
        settings: store,
      );

      await tester.pumpWidget(ExamCorrectorApp(controller: controller));

      expect(find.text('No API key set — open Settings to add one.'),
          findsOneWidget);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      // The dialog says where the key will be kept.
      expect(find.text('Gemini API key'), findsOneWidget);
      expect(find.text('in-memory settings'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('settings-api-key')),
        'a-typed-key',
      );
      await tester.enterText(
        find.byKey(const Key('settings-model')),
        'gemini-3.5-flash',
      );
      await tester.enterText(
        find.byKey(const Key('settings-fallback-models')),
        'gemini-3.5-flash-lite, gemini-3.7-flash',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(store.saved, 'a-typed-key');
      expect(controller.config.apiKey, 'a-typed-key');
      expect(controller.config.model, 'gemini-3.5-flash');
      expect(store.savedFallbacks, 'gemini-3.5-flash-lite, gemini-3.7-flash');
      expect(controller.config.modelChain, <String>[
        'gemini-3.5-flash',
        'gemini-3.5-flash-lite',
        'gemini-3.7-flash',
      ]);
      expect(
        find.text('Settings saved. Ready to mark with gemini-3.5-flash.'),
        findsOneWidget,
      );
    });

    testWidgets('cancelling changes nothing', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final RecordingSettingsStore store = RecordingSettingsStore();
      final CorrectionController controller = _controller(settings: store);

      await tester.pumpWidget(ExamCorrectorApp(controller: controller));
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('settings-api-key')),
        'discarded',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(store.saved, isNull);
      expect(controller.config.apiKey, configuredApp.apiKey);
    });
  });
}
