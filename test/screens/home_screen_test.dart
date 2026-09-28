import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/state/appearance.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import '../state/fakes.dart';

/// Fills both document slots by tapping the two Choose buttons in order.
Future<void> _chooseBoth(WidgetTester tester) async {
  await tester.tap(find.text('Choose…').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Choose…').last);
  await tester.pumpAndSettle();
}

Future<void> _correct(WidgetTester tester) async {
  await tester.tap(find.text('Correct paper'));
  await tester.pumpAndSettle();
}

Future<void> _sized(WidgetTester tester, [Size size = const Size(1280, 900)]) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets('walks the teacher from upload to marks', (WidgetTester tester) async {
    await _sized(tester);
    await tester.pumpWidget(ExamCorrectorApp(controller: fakeController()));

    expect(find.text("Student's answer sheet"), findsOneWidget);
    expect(find.text('Question paper'), findsOneWidget);
    expect(find.text('Marking guidance'), findsOneWidget);
    expect(find.text('Correction result'), findsOneWidget);
    expect(find.text('Correction results will appear here.'), findsOneWidget);

    FilledButton correctButton() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Correct paper'));
    expect(correctButton().onPressed, isNull);

    await tester.tap(find.text('Choose…').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('answers.pdf'), findsWidgets);
    expect(find.textContaining('scanned — handwriting will be read'), findsOneWidget);
    expect(correctButton().onPressed, isNull);

    await tester.tap(find.text('Choose…').last);
    await tester.pumpAndSettle();
    expect(correctButton().onPressed, isNotNull);

    await _correct(tester);

    // Grouped by question, with marks, review flags and the total.
    expect(find.text('Question 1'), findsOneWidget);
    expect(find.text('Question 2'), findsOneWidget);
    expect(find.text('1 / 2'), findsNWidgets(2));
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('Total marks: 2 / 4'), findsOneWidget);
    expect(find.text('Percentage: 50%'), findsOneWidget);
    expect(find.textContaining('Marked by gemini-3.6-flash'), findsOneWidget);
    expect(find.text('Marked 2 questions: 2 / 4 (50%). 1 need your review.'), findsOneWidget);
  });

  testWidgets('opens a question with its evidence, and takes an override',
      (WidgetTester tester) async {
    await _sized(tester, const Size(1400, 1000));
    final CorrectionController controller = fakeController();
    await tester.pumpWidget(ExamCorrectorApp(controller: controller));
    await _chooseBoth(tester);
    await _correct(tester);

    await tester.tap(find.byKey(const ValueKey<String>('question-row-Q1')));
    await tester.pumpAndSettle();

    // The question, the student's answer as read, and the marking.
    expect(find.text('Name the organelle that makes ATP.'), findsOneWidget);
    expect(find.text('Student answer'), findsOneWidget);
    expect(find.text('Recognised text'), findsOneWidget);
    expect(find.textContaining('1 The mitochondrion makes'), findsOneWidget);
    expect(find.text('Marking points'), findsOneWidget);
    expect(find.text('Names ATP'), findsOneWidget);
    expect(find.text('1/1'), findsOneWidget);
    expect(find.text('0/1'), findsOneWidget);
    expect(find.text('Names ATP but omits the site.'), findsOneWidget);
    expect(find.text('Confidence: 90%'), findsOneWidget);
    // Evidence points at the region on the page.
    expect(find.text('Page 1 → Region 1'), findsOneWidget);

    await tester.tap(find.text('Page 1 → Region 1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Page 1 → Region 1 (handwritten answer)'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    // The teacher's mark replaces the AI's in the total; the AI's is kept.
    await tester.enterText(find.byKey(const Key('teacher-mark')), '2');
    await tester.enterText(find.byKey(const Key('teacher-comment')), 'Site implied.');
    await tester.tap(find.byKey(const Key('save-mark')));
    await tester.pumpAndSettle();

    expect(find.text('You changed the mark from 1 to 2.'), findsOneWidget);
    expect(find.text('AI 1 → yours'), findsOneWidget);
    expect(controller.result!.question('Q1')!.awardedMarks, 1);

    await tester.tap(find.byTooltip('Back to the results'));
    await tester.pumpAndSettle();
    expect(find.text('Total marks: 3 / 4'), findsOneWidget);
    expect(find.text('Changed'), findsOneWidget);
    expect(find.textContaining('1 changed by you · AI total 2'), findsOneWidget);
  });

  testWidgets('a teacher can correct a transcription from the question', (WidgetTester tester) async {
    await _sized(tester, const Size(1400, 1000));
    final CorrectionController controller = fakeController();
    await tester.pumpWidget(ExamCorrectorApp(controller: controller));
    await _chooseBoth(tester);
    await _correct(tester);
    await tester.tap(find.byKey(const ValueKey<String>('question-row-Q2')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Correct transcription'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('transcription-field')), '2 Because they respire.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(controller.hasPendingCorrections, isTrue);
    await tester.tap(find.byTooltip('Back to the results'));
    await tester.pumpAndSettle();
    expect(find.text('Transcriptions were corrected'), findsOneWidget);

    await tester.tap(find.text('Re-mark'));
    await tester.pumpAndSettle();
    expect(controller.hasPendingCorrections, isFalse);
  });

  testWidgets('shows processing as it happens, and can cancel it', (WidgetTester tester) async {
    await _sized(tester);
    final FakeMarker marker = FakeMarker(gate: Completer<void>());
    final CorrectionController controller = fakeController(marker: marker);
    await tester.pumpWidget(ExamCorrectorApp(controller: controller));
    await _chooseBoth(tester);

    await tester.tap(find.text('Correct paper'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Current stage'), findsOneWidget);
    expect(find.text('Marking'), findsWidgets);
    expect(find.text('Questions: 2'), findsOneWidget);
    expect(find.text('Handwriting regions: 2'), findsOneWidget);
    expect(find.text('Pages'), findsOneWidget);
    expect(find.byKey(const Key('processing-progress')), findsOneWidget);

    await tester.tap(find.text('Cancel').last);
    marker.gate!.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('resumes where it stopped'), findsOneWidget);
    expect(find.text('Current stage'), findsNothing);
  });

  testWidgets('shows a failure in a dialog', (WidgetTester tester) async {
    await _sized(tester);
    await tester.pumpWidget(ExamCorrectorApp(
      controller: fakeController(
        marker: FakeMarker(
          error: const CorrectionException('The API key was rejected. Check GEMINI_API_KEY.'),
        ),
      ),
    ));
    await _chooseBoth(tester);
    await _correct(tester);

    expect(find.text('Correction could not continue'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('The API key was rejected. Check GEMINI_API_KEY.'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Everything read from the paper is kept, and marking can resume.
    expect(find.text('Not marked yet'), findsOneWidget);
    expect(find.text('Resume marking'), findsOneWidget);
  });

  testWidgets('reports an unreadable file before any processing', (WidgetTester tester) async {
    await _sized(tester);
    await tester.pumpWidget(ExamCorrectorApp(
      controller: fakeController(
        inspector: FakeInspector(error: 'This PDF is password protected.'),
      ),
    ));

    await tester.tap(find.text('Choose…').first);
    await tester.pumpAndSettle();

    expect(find.text('This PDF is password protected.'), findsOneWidget);
    expect(find.textContaining('Choose the completed script'), findsOneWidget);
  });

  testWidgets('keeps the optional guidance out of the way until used', (WidgetTester tester) async {
    await _sized(tester);
    final CorrectionController controller = fakeController();
    await tester.pumpWidget(ExamCorrectorApp(controller: controller));
    await _chooseBoth(tester);
    expect(controller.guidance.isEmpty, isTrue);

    await tester.enterText(find.byKey(const Key('guidance-input')), 'Section A: one mark each.');
    await tester.pump();
    expect(controller.guidance.trimmed, 'Section A: one mark each.');

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(controller.guidance.isEmpty, isTrue);
    expect(
      tester.widget<TextField>(find.byKey(const Key('guidance-input'))).controller!.text,
      isEmpty,
    );
  });

  testWidgets('the page inspector shows every region in developer mode', (WidgetTester tester) async {
    await _sized(tester, const Size(1400, 1000));
    await tester.pumpWidget(ExamCorrectorApp(controller: fakeController()));
    await _chooseBoth(tester);
    await _correct(tester);

    await tester.tap(find.text('Inspect pages'));
    await tester.pumpAndSettle();

    expect(find.text('Page inspector'), findsOneWidget);
    expect(find.text('Handwritten answer (2)'), findsOneWidget);
    expect(find.text('Page 1'), findsWidgets);
    expect(find.text('Tap a region to inspect it.'), findsOneWidget);
  });

  testWidgets('the inspector is hidden outside developer mode', (WidgetTester tester) async {
    await _sized(tester);
    await tester.pumpWidget(ExamCorrectorApp(
      controller: fakeController(config: configuredApp.copyWith(developerMode: false)),
    ));
    await _chooseBoth(tester);
    await _correct(tester);
    expect(find.text('Inspect pages'), findsNothing);
    expect(find.text('Export…'), findsOneWidget);
  });

  group('layout', () {
    for (final Size size in <Size>[
      const Size(1180, 900),
      const Size(1000, 830),
      const Size(900, 700),
      const Size(800, 560),
      const Size(640, 480),
      const Size(1920, 1080),
    ]) {
      testWidgets('lays out without overflow at ${size.width}x${size.height}',
          (WidgetTester tester) async {
        await _sized(tester, size);
        await tester.pumpWidget(ExamCorrectorApp(controller: fakeController()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await _chooseBoth(tester);
        await _correct(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Total marks: 2 / 4'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey<String>('question-row-Q1')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('settings', () {
    testWidgets('warns when no key is set, then accepts one', (WidgetTester tester) async {
      await _sized(tester, const Size(1200, 1000));
      final RecordingSettingsStore store = RecordingSettingsStore();
      final CorrectionController controller = fakeController(
        config: const AppConfig(apiKey: null, model: 'gemini-3.7-flash', effort: 'high', maxTokens: 32000),
        settings: store,
      );
      await tester.pumpWidget(ExamCorrectorApp(controller: controller));

      expect(find.text('No API key set — open Settings to add one.'), findsOneWidget);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Gemini API key'), findsOneWidget);
      expect(find.text('in-memory settings'), findsOneWidget);
      expect(find.text('Page understanding'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('settings-api-key')), 'a-typed-key');
      await tester.enterText(find.byKey(const Key('settings-model')), 'gemini-3.5-flash');
      await tester.enterText(find.byKey(const Key('settings-fallback-models')),
          'gemini-3.5-flash-lite, gemini-3.7-flash');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(store.saved, 'a-typed-key');
      expect(store.savedLayout, 'hybrid');
      expect(controller.config.model, 'gemini-3.5-flash');
      expect(controller.config.modelChain,
          <String>['gemini-3.5-flash', 'gemini-3.5-flash-lite', 'gemini-3.7-flash']);
      expect(find.text('Settings saved. Ready to mark with gemini-3.5-flash.'), findsOneWidget);
    });

    testWidgets('cancelling changes nothing', (WidgetTester tester) async {
      await _sized(tester);
      final RecordingSettingsStore store = RecordingSettingsStore();
      final CorrectionController controller = fakeController(settings: store);
      await tester.pumpWidget(ExamCorrectorApp(controller: controller));

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('settings-api-key')), 'discarded');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(store.saved, isNull);
      expect(controller.config.apiKey, configuredApp.apiKey);
    });
  });

  group('appearance', () {
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      testWidgets('marks a paper in the ${mode.name} theme without overflow', (WidgetTester tester) async {
        await _sized(tester);
        final Appearance appearance = Appearance(store: RecordingSettingsStore())..value = mode;
        await tester.pumpWidget(ExamCorrectorApp(controller: fakeController(), appearance: appearance));
        await tester.pumpAndSettle();

        final BuildContext context = tester.element(find.text('Correction result'));
        expect(context.colors, mode == ThemeMode.dark ? AppColors.dark : AppColors.light);

        await _chooseBoth(tester);
        await _correct(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Total marks: 2 / 4'), findsOneWidget);
      });
    }

    testWidgets('switches theme from Settings at once, and saves the choice', (WidgetTester tester) async {
      await _sized(tester, const Size(1280, 1000));
      final RecordingSettingsStore store = RecordingSettingsStore();
      final Appearance appearance = Appearance(store: store);
      await tester.pumpWidget(ExamCorrectorApp(controller: fakeController(), appearance: appearance));

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();

      expect(appearance.value, ThemeMode.dark);
      expect(store.savedTheme, 'dark');
      final BuildContext context = tester.element(find.text('Correction result'));
      expect(context.colors, AppColors.dark);
    });
  });
}
