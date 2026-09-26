import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'fakes.dart';

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
      onProgress: onProgress,
      cancel: cancel,
    );
  }
}

FakeFilePicker classPicker() => FakeFilePicker(questionPath)
  ..classSet = <String>[answerPath, secondPath, thirdPath];

Future<CorrectionController> classReady({FakeMarker? marker, FakeFilePicker? picker}) async {
  final CorrectionController controller =
      fakeController(marker: marker, picker: picker ?? classPicker());
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
      expect(controller.statusMessage, 'Marked 3 scripts. 3 need your review.');
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
      expect(lines.first, 'Student,Q1,Q2,Total,Maximum,Percentage,To review,Changed by teacher,Status');
      expect(lines[1], 'answers.pdf,2,1,3,4,75%,1,1,marked');
      expect(lines[2], 'bailey.pdf,1,1,2,4,50%,1,0,marked');
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

      expect(find.text("1. Students' answer sheets"), findsOneWidget);
      expect(find.text('3 answer sheets · 3 scanned'), findsOneWidget);
      expect(find.text('4. Class results'), findsOneWidget);
      expect(find.text('Not marked'), findsNWidgets(3));

      await tester.tap(find.text('Mark all 3 scripts'));
      await tester.pumpAndSettle();

      expect(find.text('To review'), findsWidgets);
      expect(find.text('2 / 4'), findsNWidgets(3));
      expect(find.text('Class average'), findsOneWidget);
      expect(find.text('50%'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey<String>('script-row-1')));
      await tester.pumpAndSettle();
      expect(find.text('4. bailey.pdf'), findsOneWidget);
      expect(find.text('Question 1'), findsOneWidget);

      await tester.tap(find.text('All scripts'));
      await tester.pumpAndSettle();
      expect(find.text('4. Class results'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
