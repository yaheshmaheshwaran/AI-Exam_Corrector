import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import '../state/fakes.dart';

void main() {
  late Directory dir;
  late File key;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('key-section');
    key = File('${dir.path}/BIO-key.txt')..writeAsStringSync('1. The mitochondrion (2 marks)\n');
  });
  tearDown(() => dir.delete(recursive: true));

  testWidgets("the rail shows how much the teacher's key covers, and the dialog where each key comes from",
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final CorrectionController controller =
        fakeController(picker: FakeFilePicker(answerPath, questionPath)..answerKeyPath = key.path);
    await tester.pumpWidget(ExamCorrectorApp(controller: controller));

    // Before a paper, the key waits for it.
    expect(find.textContaining('Choose the question paper first'), findsOneWidget);

    await tester.runAsync(() async {
      await controller.chooseAnswerSheet();
      await controller.chooseQuestionPaper();
      await controller.chooseAnswerKey();
    });
    await tester.pumpAndSettle();

    expect(find.text('BIO-key.txt'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('answer-key-coverage'))).data,
        'Covers 1 of 2 questions · 1 marked the usual way');
    expect(find.text('Replace…'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('answer-key')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey<String>('answer-key-source-Q1')), matching: find.text('Your key')),
        findsOneWidget);
    expect(
      find.descendant(
          of: find.byKey(const ValueKey<String>('answer-key-source-Q2')), matching: find.text('Prepared when marking starts')),
      findsOneWidget,
    );
  });
}
