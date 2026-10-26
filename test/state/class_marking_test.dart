import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/marking/contracts.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'fakes.dart';

/// The first-choice marker is out of its allowance; the backup marker,
/// asked on its own, marks.
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

/// The first marker is out of its allowance, and the backup is not
/// answering either.
class _BackupDown extends FakeMarker {
  int backupCalls = 0;

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
    calls++;
    if (models != null) {
      backupCalls++;
      throw const CorrectionException('marker-b is not answering.', modelUnavailable: true);
    }
    throw const CorrectionException('No quota left.', quotaExhausted: true);
  }
}

/// Fails on its [failOn]th call — a quota running out partway through a class.
class _FailingOnce extends FakeMarker {
  _FailingOnce(this.failOn);

  final int failOn;
  bool failing = true;

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
    if (failing && calls + 1 == failOn) {
      calls++;
      throw const CorrectionException('The free-tier quota has run out.');
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

FakeFilePicker classPicker() => FakeFilePicker(questionPath)
  ..classSet = <String>[answerPath, secondPath, thirdPath];

Future<CorrectionController> classReady({
  FakeMarker? marker,
  FakeFilePicker? picker,
  AppConfig config = configuredApp,
  AiSettings? ai,
  UsageMonitor? usage,
  FakeRenderer? renderer,
}) async {
  final CorrectionController controller = fakeController(
    marker: marker,
    picker: picker ?? classPicker(),
    config: config,
    ai: ai,
    usage: usage,
    renderer: renderer,
  );
  await controller.chooseAnswerSheet();
  await controller.chooseQuestionPaper();
  return controller;
}

void main() {
  group('a class set', () {
    test('several scripts chosen at once become a class', () async {
      final CorrectionController controller = await classReady();

      expect(controller.scripts.map((MarkedScript s) => s.document.fileName),
          <String>['answers.pdf', 'bailey.pdf', 'chen.pdf']);
      expect(controller.isClass, isTrue);
      expect(controller.showingClass, isTrue);
      expect(controller.scripts.every((MarkedScript s) => s.status == ScriptStatus.waiting), isTrue);
    });

    test('marks every script, one after another', () async {
      final FakeMarker marker = FakeMarker();
      final CorrectionController controller = await classReady(marker: marker);

      await controller.markAll();

      expect(marker.calls, 3);
      expect(controller.scripts.every((MarkedScript s) => s.result != null), isTrue);
      expect(controller.scripts.every((MarkedScript s) => s.status == ScriptStatus.reviewRequired), isTrue);
      expect(controller.statusMessage, startsWith('Marked 3 scripts in '));
      expect(controller.statusMessage, endsWith('. 3 need your review.'));
      expect(controller.scripts.every((MarkedScript s) => s.assessment!.job.elapsed != null), isTrue);
      expect(controller.lastRun?.scripts, 3);
      expect(controller.showingClass, isTrue);
    });

    test('each script keeps its own reviews', () async {
      final CorrectionController controller = await classReady();
      await controller.markAll();

      controller.openScript(1);
      expect(controller.answerSheet!.fileName, 'bailey.pdf');
      await controller.overrideMark('Q1', 2);
      await controller.acceptMark('Q2');

      expect(controller.scripts[1].finalTotal, 3);
      expect(controller.scripts[1].status, ScriptStatus.marked);
      expect(controller.scripts[0].finalTotal, 2);
      expect(controller.scripts[0].reviews.reviews, isEmpty);

      controller.showClass();
      expect(controller.showingClass, isTrue);
    });

    test('the next script is read while this one is being marked', () async {
      final FakeRenderer renderer = FakeRenderer();
      final Completer<void> gate = Completer<void>();
      final FakeMarker marker = FakeMarker(gate: gate);
      final CorrectionController controller = await classReady(marker: marker, renderer: renderer);

      final Future<void> run = controller.markAll();
      Future<void> until(bool Function() done) async {
        for (int i = 0; i < 500 && !done(); i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      await until(() => marker.calls == 1);
      await until(() => renderer.rendered.contains('bailey.pdf'));
      expect(marker.calls, 1, reason: 'the first script is still being marked');
      expect(renderer.rendered, contains('bailey.pdf'), reason: 'and the second has been read meanwhile');

      gate.complete();
      await run;
      expect(controller.scripts.every((MarkedScript s) => s.result != null), isTrue);
      for (final String name in <String>['answers.pdf', 'bailey.pdf', 'chen.pdf']) {
        expect(renderer.rendered.where((String f) => f == name), hasLength(1),
            reason: '$name read once: the prefetch is reused');
      }
    });

    group('when marking models run out of their allowance', () {
      /// A monitor that knows [models] are out of their allowance for the day.
      UsageMonitor outOfQuota(List<String> models) {
        final UsageMonitor usage = UsageMonitor(dailyAllowance: (String m) => true);
        for (final String model in models) {
          usage.modelFailed(
            usage.started(model, 'marking'),
            model,
            const CorrectionException('No quota left.', quotaExhausted: true, dailyQuota: true),
          );
        }
        return usage;
      }

      const String markerA = 'gemini/marker-a';
      const String markerB = 'gemini/marker-b';
      final AiSettings twoMarkers = fakeAi(values: <String, String>{
        ModelRole.marker.settingName: '$markerA, $markerB',
      });

      test('a script whose own marker ran out waits, and the class goes on', () async {
        final _FailingOnce marker = _FailingOnce(1);
        final CorrectionController controller = await classReady(
          marker: marker,
          ai: twoMarkers,
          usage: outOfQuota(<String>[markerB]),
        );

        await controller.markAll();

        expect(controller.scripts[0].result, isNull);
        expect(controller.scripts[1].result, isNotNull);
        expect(controller.scripts[2].result, isNotNull);
        expect(controller.statusMessage, contains('1 waits for the model that began marking it'));
        expect(controller.resumeAt, isNotNull);
        controller.cancelProcessing();
        expect(controller.resumeAt, isNull);
      });

      test('when the backup cannot take over either, every script is read, then marking waits', () async {
        final _BackupDown marker = _BackupDown();
        final FakeRenderer renderer = FakeRenderer();
        final CorrectionController controller = await classReady(
          marker: marker,
          ai: twoMarkers,
          usage: outOfQuota(<String>[markerA, markerB]),
          renderer: renderer,
        );

        await controller.markAll();

        expect(renderer.rendered, containsAll(<String>['answers.pdf', 'bailey.pdf', 'chen.pdf']),
            reason: 'scanning does not stop for quota');
        expect(marker.backupCalls, 1, reason: 'the backup was tried once, not for every script');
        expect(controller.statusMessage, startsWith('Every script read. Marking resumes at'));
        expect(controller.pendingError, contains('could not take over'));
        expect(controller.pendingError, contains('marker-b is not answering'));
        expect(controller.resumeAt, isNotNull);
        expect(controller.markingBackAt, isNotNull);
        controller.dispose();
      });

      test('a single script is marked by the backup when the first marker is out', () async {
        final CorrectionController controller = fakeController(
          marker: _FirstMarkerOut(),
          ai: twoMarkers,
          usage: outOfQuota(<String>[markerA]),
        );
        await controller.chooseAnswerSheet();
        await controller.chooseQuestionPaper();

        await controller.startCorrection();

        final List<QuestionResult> answered =
            controller.result!.questions.where((QuestionResult q) => q.model.isNotEmpty).toList();
        expect(answered.map((QuestionResult q) => q.model).toSet(), <String>{markerB});
        expect(answered.every((QuestionResult q) => q.needsReview), isTrue);
      });

      test('a single script the backup cannot mark is read in full and told when marking is back',
          () async {
        final CorrectionController controller = fakeController(
          marker: _BackupDown(),
          ai: twoMarkers,
          usage: outOfQuota(<String>[markerA, markerB]),
        );
        await controller.chooseAnswerSheet();
        await controller.chooseQuestionPaper();

        await controller.startCorrection();

        expect(controller.assessment, isNotNull, reason: 'everything read is kept');
        expect(controller.result, isNull);
        expect(controller.statusMessage, startsWith('Read in full. Marking waits for quota until'));
        expect(controller.pendingError, contains('could not take over'));
      });

      test('with the first marker out, the backup marks the class, every mark flagged', () async {
        final _FirstMarkerOut marker = _FirstMarkerOut();
        final CorrectionController controller = await classReady(
          marker: marker,
          ai: twoMarkers,
          usage: outOfQuota(<String>[markerA]),
        );

        await controller.markAll();

        expect(controller.resumeAt, isNull, reason: 'nothing waits for the first marker');
        expect(controller.scripts.every((MarkedScript s) => s.result != null), isTrue);
        for (final MarkedScript script in controller.scripts) {
          final List<QuestionResult> answered =
              script.result!.questions.where((QuestionResult q) => q.model.isNotEmpty).toList();
          expect(answered.map((QuestionResult q) => q.model).toSet(), <String>{markerB});
          expect(answered.every((QuestionResult q) => q.needsReview), isTrue);
        }
        controller.dispose();
      });
    });

    test('a failure stops the class, keeps what was marked, and resumes', () async {
      final _FailingOnce marker = _FailingOnce(2);
      final CorrectionController controller = await classReady(marker: marker);

      await controller.markAll();

      expect(controller.scripts[0].result, isNotNull);
      expect(controller.scripts[1].status, ScriptStatus.failed);
      expect(controller.scripts[1].assessment, isNotNull, reason: 'what was read is kept');
      expect(controller.scripts[2].status, ScriptStatus.waiting, reason: 'not attempted');
      expect(controller.pendingError, contains('quota'));

      marker.failing = false;
      marker.marked.clear();
      await controller.markAll();

      expect(controller.scripts.every((MarkedScript s) => s.result != null), isTrue);
      expect(marker.marked.toSet(), <String>{'Q1', 'Q2'},
          reason: 'only the two unmarked scripts were marked');
      expect(marker.marked, hasLength(4));
    });

    test('marking all again does nothing when everything is marked', () async {
      final FakeMarker marker = FakeMarker();
      final CorrectionController controller = await classReady(marker: marker);
      await controller.markAll();
      await controller.markAll();

      expect(marker.calls, 3);
      expect(controller.statusMessage, 'Every script is already marked.');
    });

    test('a script whose transcription was corrected is marked again', () async {
      final FakeMarker marker = FakeMarker();
      final CorrectionController controller = await classReady(marker: marker);
      await controller.markAll();

      controller.openScript(2);
      final String region = controller.assessment!.answers['Q2']!.textEvidence.first.regionId;
      await controller.correctTranscription(region, '2 Because they respire.');
      marker.marked.clear();
      await controller.markAll();

      expect(marker.marked, <String>['Q2']);
    });

    test('duplicates are skipped and unreadable files reported, the rest kept', () async {
      final FakeFilePicker picker = FakeFilePicker(questionPath)
        ..classSet = <String>[answerPath, answerPath, 'C:\\papers\\missing.pdf', secondPath];
      final CorrectionController controller = fakeController(picker: picker);

      await controller.chooseAnswerSheet();

      expect(controller.scripts, hasLength(2));
      expect(controller.pendingError, contains('missing.pdf'));
      expect(controller.statusMessage, '1 of 4 answer sheets could not be read.');
    });

    test('more scripts can be added, and one removed', () async {
      final FakeFilePicker picker = FakeFilePicker(questionPath)
        ..classSet = <String>[answerPath];
      final CorrectionController controller = fakeController(picker: picker);
      await controller.chooseAnswerSheet();
      expect(controller.isClass, isFalse);

      picker.classSet = <String>[secondPath, thirdPath, answerPath];
      await controller.addAnswerSheets();
      expect(controller.scripts, hasLength(3));

      controller.removeScript(0);
      expect(controller.scripts.map((MarkedScript s) => s.document.fileName),
          <String>['bailey.pdf', 'chen.pdf']);
    });

    test('the class exports as one gradebook, with the marks that count', () async {
      final Directory dir = await Directory.systemTemp.createTemp('class');
      addTearDown(() => dir.delete(recursive: true));
      final FakeFilePicker picker = classPicker()..savePath = '${dir.path}/class.csv';
      final CorrectionController controller = await classReady(picker: picker);
      await controller.markAll();
      controller.openScript(0);
      await controller.overrideMark('Q1', 2);

      final String? path = await controller.exportClass();

      final List<String> lines = File(path!).readAsLinesSync();
      expect(lines.first, 'Student,Q1,Q2,Total,Maximum,Percentage,To review,Changed by teacher,Marking time (s),Status');
      // The fakes mark in well under a second.
      expect(lines[1], 'answers.pdf,2,1,3,4,75%,1,1,0,marked');
      expect(lines[2], 'bailey.pdf,1,1,2,4,50%,1,0,0,marked');
      expect(lines, hasLength(4));
    });
  });

  group('the class screen', () {
    testWidgets('lists every student, marks them all, and opens one', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final CorrectionController controller = fakeController(picker: classPicker());
      await tester.pumpWidget(ExamCorrectorApp(controller: controller));

      await tester.tap(find.text('Choose…').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose…').last);
      await tester.pumpAndSettle();

      expect(find.text("Students' answer sheets"), findsOneWidget);
      expect(find.text('3 answer sheets · 3 scanned'), findsOneWidget);
      expect(find.text('Class results'), findsOneWidget);
      expect(find.text('Not marked'), findsNWidgets(3));

      await tester.tap(find.text('Mark all 3 scripts'));
      await tester.pumpAndSettle();

      expect(find.text('To review'), findsWidgets);
      expect(find.text('2 / 4'), findsNWidgets(3));
      expect(find.text('Class average'), findsOneWidget);
      expect(find.text('50%'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey<String>('script-row-1')));
      await tester.pumpAndSettle();
      expect(find.text('bailey.pdf'), findsOneWidget);
      expect(find.text('Question 1'), findsOneWidget);

      await tester.tap(find.text('All scripts'));
      await tester.pumpAndSettle();
      expect(find.text('Class results'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
