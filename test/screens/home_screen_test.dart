import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/model_roles.dart';

import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/shared/ui/ui.dart';
import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/marking/contracts.dart';
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
  testWidgets('the status bar floats in glass, its ends in line with the rail and the panes',
      (WidgetTester tester) async {
    await _sized(tester);
    await tester.pumpWidget(ExamCorrectorApp(controller: fakeController()));
    await tester.pumpAndSettle();

    final Finder bar = find.byKey(const Key('status-bar'));
    final Rect frame = tester.getRect(bar);
    const Size window = Size(1280, 900);
    expect(find.descendant(of: bar, matching: find.byType(Frosted)), findsOneWidget);
    expect(frame.height, AppTheme.statusHeight);
    expect(frame.left, AppTheme.floatInset);
    expect(frame.right, window.width - AppTheme.floatInset);
    expect(frame.bottom, window.height - AppTheme.floatInset);
    // Its left end meets the rail's, with the panes' gap above it.
    final Rect rail = tester.getRect(find.descendant(of: find.byType(AppRail), matching: find.byType(Frosted)));
    expect(rail.left, frame.left);
    expect(frame.top - rail.bottom, AppTheme.floatInset);
    expect(find.text('Ready.'), findsOneWidget);
  });

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
    expect(find.textContaining('Marked by $fakeMarker'), findsOneWidget);
    expect(find.textContaining('Marked 2 questions: 2 / 4 (50%). 1 need your review. Took '), findsOneWidget);
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
    // The footer times the run while it goes.
    expect(find.byKey(const Key('run-clock')), findsOneWidget);

    await tester.tap(find.text('Cancel').last);
    marker.gate!.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('resumes where it stopped'), findsOneWidget);
    expect(find.text('Current stage'), findsNothing);
    expect(find.byKey(const Key('run-clock')), findsNothing);
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

  testWidgets('with the first marker out of its allowance, the backup marks the paper and flags every mark',
      (WidgetTester tester) async {
    await _sized(tester);
    final UsageMonitor usage = UsageMonitor(dailyAllowance: (String m) => true);
    usage.modelFailed(
      usage.started(fakeMarker, 'marking'),
      fakeMarker,
      const CorrectionException('No quota left.', quotaExhausted: true, dailyQuota: true),
    );
    final CorrectionController controller = fakeController(
      marker: _FirstMarkerOut(),
      usage: usage,
    );
    // The quota indicator ticks every second, so the screen never settles:
    // pump for a while instead.
    Future<void> settle() async {
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(ExamCorrectorApp(controller: controller));
    await settle();
    await tester.runAsync(() async {
      await controller.chooseAnswerSheet();
      await controller.chooseQuestionPaper();
      await controller.startCorrection();
    });
    await settle();

    expect(controller.result, isNotNull);
    expect(controller.result!.model, fakeBackupMarker);
    expect(
      controller.result!.questions.where((QuestionResult q) => q.model.isNotEmpty).every((QuestionResult q) => q.needsReview),
      isTrue,
    );
    expect(find.text('Not marked yet'), findsNothing);
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
    testWidgets('warns when no key is set, then accepts one and the models of each job', (WidgetTester tester) async {
      await _sized(tester, const Size(1200, 1000));
      final RecordingSettingsStore store = RecordingSettingsStore();
      final CorrectionController controller = fakeController(
        ai: AiSettings.fromMap(const <String, String>{}),
        settings: store,
      );
      await tester.pumpWidget(ExamCorrectorApp(controller: controller));

      expect(find.text(AiSettings.notReadyMessage), findsOneWidget);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Gemini API key'), findsOneWidget);
      expect(find.text('NVIDIA API key'), findsOneWidget);
      expect(find.text('in-memory settings'), findsOneWidget);
      // Marking options are a section of their own; what was typed is kept
      // while moving between sections.
      await tester.enterText(find.byKey(const Key('settings-api-key')), 'a-typed-key');
      await tester.tap(find.byKey(const Key('settings-section-marking')));
      await tester.pumpAndSettle();
      expect(find.text('Mark in the background'), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-section-models')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('settings-models-marker')), 'gemini/gemini-3.5-flash, gemini/gemini-3.7-flash');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(store.saved, 'a-typed-key');
      expect(store.savedMarkerModels, 'gemini/gemini-3.5-flash, gemini/gemini-3.7-flash');
      expect(controller.ai.roles.marker, <String>['gemini/gemini-3.5-flash', 'gemini/gemini-3.7-flash']);
      expect(find.text('Settings saved. Ready to mark with Gemini (gemini-3.5-flash).'), findsOneWidget);
    });

    testWidgets('checks the first model of every job, as typed', (WidgetTester tester) async {
      await _sized(tester, const Size(1200, 1000));
      final List<String> checked = <String>[];
      final CorrectionController controller = fakeController(
        settings: RecordingSettingsStore(),
        modelCheck: (AiSettings ai, String model) async {
          checked.add(model);
          return (ok: !model.startsWith('nvidia/'), message: 'Checked $model.');
        },
      );
      await tester.pumpWidget(ExamCorrectorApp(controller: controller));

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('settings-models-reader')), 'server/Qwen/Qwen3-VL-8B-Instruct');
      await tester.ensureVisible(find.byKey(const Key('settings-test-connection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-test-connection')));
      await tester.pumpAndSettle();

      expect(checked, <String>[ModelRoles.defaults.prep.first, 'server/Qwen/Qwen3-VL-8B-Instruct', fakeMarker]);
      expect(find.text('Checked server/Qwen/Qwen3-VL-8B-Instruct.'), findsOneWidget);
      expect(find.byKey(const Key('settings-test-result-prep')), findsOneWidget);
    });

    testWidgets('marking in the background is switched on and saved', (WidgetTester tester) async {
      await _sized(tester);
      final RecordingSettingsStore store = RecordingSettingsStore();
      final CorrectionController controller = fakeController(settings: store);
      await tester.pumpWidget(ExamCorrectorApp(controller: controller));

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-section-marking')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-background')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(store.savedBackground, isTrue);
      expect(controller.config.backgroundProcessing, isTrue);
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
      expect(controller.ai.providers.byId('gemini')!.apiKey, 'test-key');
    });
  });

  group('look', () {
    testWidgets('the setup column scrolls with no scrollbar beside it', (WidgetTester tester) async {
      await _sized(tester, const Size(1280, 700));
      await tester.pumpWidget(ExamCorrectorApp(controller: fakeController()));
      await tester.pumpAndSettle();

      final Finder first = find.text("Student's answer sheet");
      expect(find.ancestor(of: first, matching: find.byType(Scrollbar)), findsNothing);
      expect(find.ancestor(of: first, matching: find.byType(RawScrollbar)), findsNothing);

      final ScrollPosition position =
          tester.state<ScrollableState>(find.ancestor(of: first, matching: find.byType(Scrollable)).first).position;
      expect(position.maxScrollExtent, greaterThan(0), reason: 'the column is taller than the window');
      final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
      mouse.hover(tester.getCenter(first));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 200)));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0), reason: 'the mouse wheel still scrolls it');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('marks a paper in the light theme without overflow', (WidgetTester tester) async {
      await _sized(tester);
      await tester.pumpWidget(ExamCorrectorApp(controller: fakeController()));
      await tester.pumpAndSettle();

      final BuildContext context = tester.element(find.text('Correction result'));
      expect(context.colors, AppColors.light);
      expect(Theme.of(context).brightness, Brightness.light);

      await _chooseBoth(tester);
      await _correct(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Total marks: 2 / 4'), findsOneWidget);
    });

    testWidgets('turns glass blur off from Settings at once, and saves the choice', (WidgetTester tester) async {
      await _sized(tester, const Size(1280, 1000));
      final RecordingSettingsStore store = RecordingSettingsStore();
      final Transparency transparency = Transparency(store: store);
      await tester.pumpWidget(ExamCorrectorApp(controller: fakeController(), transparency: transparency));
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsWidgets, reason: 'glass blurs by default');

      await tester.tap(find.byKey(const Key('open-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-section-look')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-glass-blur')));
      await tester.pumpAndSettle();

      expect(transparency.value, 0);
      expect(store.savedTransparency, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing, reason: 'the same bars, drawn solid');
    });
  });
}

/// The first marker is out of its allowance; the backup, asked on its own,
/// marks.
class _FirstMarkerOut extends FakeMarker {
  @override
  Future<List<QuestionResult>> mark(
    List<MarkingTask> tasks, {
    required String guidance,
    required bool typedAnswerSheet,
    String? judge,
    List<String>? models,
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) {
    if (models == null) {
      calls++;
      throw const CorrectionException('No quota left.', quotaExhausted: true);
    }
    return super.mark(
      tasks,
      guidance: guidance,
      typedAnswerSheet: typedAnswerSheet,
      judge: judge,
      models: models,
      onProgress: onProgress,
      cancel: cancel,
    );
  }
}
