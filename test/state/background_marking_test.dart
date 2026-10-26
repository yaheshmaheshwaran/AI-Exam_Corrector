import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';


import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/ai/provider_health.dart';
import 'package:exam_corrector/services/background_signals.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/features/results/ui/class_results_view.dart';

import 'fakes.dart';

/// Records what a background run asked of the computer.
class _Signals extends BackgroundSignals {
  final List<String> calls = <String>[];

  @override
  Future<void> keepAwake(bool on) async => calls.add('awake:$on');

  @override
  Future<void> badge(String? label) async => calls.add('badge:$label');

  @override
  Future<void> requestNotifications() async => calls.add('ask');

  @override
  Future<void> notify(String title, String body) async => calls.add('notify:$title');
}

/// Counts the checks made before each script.
class _Health extends ProviderHealth {
  int rechecks = 0;

  @override
  Future<void> recheck(AiSettings ai) async => rechecks++;
}

final AppConfig _background = configuredApp.copyWith(backgroundProcessing: true);

Future<void> _until(bool Function() done) async {
  for (int i = 0; i < 2000 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('with background on, marking starts by itself once scripts and the paper are in', () async {
    final _Signals signals = _Signals();
    final FakeMarker marker = FakeMarker();
    final CorrectionController controller = fakeController(
      config: _background,
      marker: marker,
      signals: signals,
      picker: FakeFilePicker(questionPath)..classSet = <String>[answerPath, secondPath, thirdPath],
    );

    await controller.chooseAnswerSheet();
    expect(controller.isProcessing, isFalse, reason: 'no question paper yet: nothing starts');
    await controller.chooseQuestionPaper();
    expect(controller.isBackgroundRun, isTrue);

    await _until(() => !controller.isProcessing);
    expect(marker.calls, 3);
    expect(controller.scripts.every((MarkedScript s) => s.result != null), isTrue);
    expect(signals.calls.first, 'awake:true');
    expect(signals.calls, containsAllInOrder(<String>['badge:0/3', 'badge:1/3', 'badge:2/3', 'badge:3/3']));
    expect(signals.calls.sublist(signals.calls.length - 3), <String>['awake:false', 'badge:null', 'notify:Class marked']);
    expect(controller.isBackgroundRun, isFalse);
  });

  test('with background off, nothing starts until the teacher presses Mark all', () async {
    final FakeMarker marker = FakeMarker();
    final CorrectionController controller = fakeController(
      marker: marker,
      picker: FakeFilePicker(questionPath)..classSet = <String>[answerPath, secondPath],
    );
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    await Future<void>.delayed(Duration.zero);

    expect(controller.isProcessing, isFalse);
    expect(marker.calls, 0);
  });

  test('a class that is not ready does not start, and raises no error', () async {
    final CorrectionController controller = fakeController(
      config: _background,
      picker: FakeFilePicker(answerPath)..classSet = <String>[answerPath, secondPath],
    );
    await controller.chooseAnswerSheet();

    expect(controller.isProcessing, isFalse);
    expect(controller.pendingError, isNull);
  });

  test('scripts added while it runs join the queue', () async {
    final Completer<void> gate = Completer<void>();
    final FakeMarker marker = FakeMarker(gate: gate);
    final CorrectionController controller = fakeController(
      config: _background,
      marker: marker,
      picker: FakeFilePicker.sequence(<String?>[questionPath, thirdPath])..classSet = <String>[answerPath, secondPath],
    );
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    await _until(() => marker.calls == 1);

    expect(controller.canAddScripts, isTrue);
    await controller.addAnswerSheets();
    expect(controller.scripts, hasLength(3));
    expect(controller.statusMessage, '1 answer sheet added to the queue.');

    gate.complete();
    await _until(() => !controller.isProcessing);
    expect(marker.calls, 3);
    expect(controller.scripts.every((MarkedScript s) => s.result != null), isTrue);
  });

  test('outside a background run, scripts cannot be added while marking', () async {
    final Completer<void> gate = Completer<void>();
    final FakeMarker marker = FakeMarker(gate: gate);
    final CorrectionController controller = fakeController(
      marker: marker,
      picker: FakeFilePicker.sequence(<String?>[questionPath, thirdPath])..classSet = <String>[answerPath, secondPath],
    );
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    final Future<void> run = controller.markAll();
    await _until(() => marker.calls == 1);

    expect(controller.canAddScripts, isFalse);
    await controller.addAnswerSheets();
    expect(controller.scripts, hasLength(2));
    gate.complete();
    await run;
  });

  test('cancelling lets the computer sleep again', () async {
    final _Signals signals = _Signals();
    final Completer<void> gate = Completer<void>();
    final CorrectionController controller = fakeController(
      config: _background,
      marker: FakeMarker(gate: gate),
      signals: signals,
      picker: FakeFilePicker(questionPath)..classSet = <String>[answerPath, secondPath],
    );
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    await _until(() => controller.job != null);

    controller.cancelProcessing();
    gate.complete();
    await _until(() => !controller.isProcessing);

    expect(signals.calls, contains('awake:false'));
    expect(signals.calls.last, startsWith('notify:'));
  });

  test('switching background on asks once about notifications and starts a waiting class', () async {
    final _Signals signals = _Signals();
    final FakeMarker marker = FakeMarker();
    final CorrectionController controller = fakeController(
      marker: marker,
      signals: signals,
      picker: FakeFilePicker(questionPath)..classSet = <String>[answerPath, secondPath],
    );
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();

    await controller.saveSettings(geminiKey: 'key', backgroundProcessing: true);
    expect(signals.calls.first, 'ask');
    await _until(() => !controller.isProcessing);
    expect(marker.calls, 2);
  });

  test('a GPU server that stopped is checked again before each script', () async {
    final _Health health = _Health();
    final CorrectionController controller = fakeController(
      health: health,
      picker: FakeFilePicker(questionPath)..classSet = <String>[answerPath, secondPath, thirdPath],
    );
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    await controller.markAll();

    expect(health.rechecks, 3);
  });

  group('where marking runs, in the teacher\'s words', () {
    AiSettings server() => fakeAi(values: <String, String>{
          ModelRole.marker.settingName: 'server/Qwen/Qwen3-VL-8B-Instruct, $fakeMarker',
          Providers.serverAddressName: 'https://gpu.example/v1',
        });

    test('the GPU server while it answers, and says so when it is down', () {
      final ProviderHealth health = ProviderHealth();
      final CorrectionController controller = fakeController(ai: server(), health: health);
      expect(controller.engineLabel, 'GPU server');
      health.markDown('server', 'not reachable');
      expect(controller.engineLabel, 'GPU server down');
    });

    test('the backup marker while the first is out of its allowance', () {
      final UsageMonitor usage = UsageMonitor(dailyAllowance: (String m) => true);
      final CorrectionController controller = fakeController(usage: usage);
      expect(controller.engineLabel, 'Gemini');
      usage.failed(usage.started(fakeMarker, 'marking'),
          const CorrectionException('out', quotaExhausted: true, dailyQuota: true));
      expect(controller.engineLabel, 'Gemini');
      expect(controller.modelLabel(fakeBackupMarker), 'Gemini (gemini-3.7-flash)');
    });
  });

  testWidgets('during a background run the class table stays, with a badge saying so', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final Completer<void> gate = Completer<void>();
    final CorrectionController controller = fakeController(
      config: _background,
      marker: FakeMarker(gate: gate),
      picker: FakeFilePicker(questionPath)..classSet = <String>[answerPath, secondPath],
    );
    await tester.pumpWidget(ExamCorrectorApp(controller: controller));
    await tester.runAsync(() async {
      await controller.chooseAnswerSheet();
      await controller.chooseQuestionPaper();
      await _until(() => controller.job != null);
    });
    await tester.pump(const Duration(milliseconds: 500));

    expect(controller.isBackgroundRun, isTrue);
    expect(find.byType(ClassResultsView), findsOneWidget);
    expect(find.byKey(const Key('background-pill')), findsOneWidget);
    expect(find.textContaining('In the background · 0 of 2'), findsOneWidget);

    gate.complete();
    // The run moves on real and test time both: pump while waiting.
    for (int i = 0; i < 200 && controller.isProcessing; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(controller.isProcessing, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('background-pill')), findsNothing);
  });
}
