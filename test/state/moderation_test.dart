import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/moderation.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'fakes.dart';

const String fourthPath = 'C:\\papers\\dev.pdf';

/// Four scripts, two questions of two marks each; the fake AI gives every
/// answered question 1.
Future<CorrectionController> fourScripts() async {
  final CorrectionController controller = fakeController(
    picker: FakeFilePicker(questionPath)..classSet = <String>[answerPath, secondPath, thirdPath, fourthPath],
    inspector: FakeInspector(documents: <String, SelectedDocument>{
      answerPath: FakeInspector.document(answerPath, DocumentRole.answerSheet, 'answers'),
      secondPath: FakeInspector.document(secondPath, DocumentRole.answerSheet, 'bailey'),
      thirdPath: FakeInspector.document(thirdPath, DocumentRole.answerSheet, 'chen'),
      fourthPath: FakeInspector.document(fourthPath, DocumentRole.answerSheet, 'dev'),
      questionPath: FakeInspector.document(questionPath, DocumentRole.questionPaper, 'questions'),
    }),
  );
  await controller.chooseAnswerSheet();
  await controller.chooseQuestionPaper();
  await controller.markAll();
  return controller;
}

double mark(CorrectionController c, int script, String id) {
  final MarkedScript s = c.scripts[script];
  final QuestionResult q = s.result!.question(id)!;
  return s.reviews.finalMarks(q);
}

void main() {
  test("the teacher marks a few scripts and the rest come to their standard", () async {
    final CorrectionController controller = await fourScripts();
    expect(controller.moderation.isActive, isFalse);
    expect(controller.suggestedModeration, isNull);

    // The teacher finds the AI too generous: half of its 1 mark, on three scripts.
    for (final int script in <int>[0, 1, 2]) {
      controller.openScript(script);
      await controller.overrideMark('Q1', 0.5);
      if (script == 2) {
        await controller.acceptMark('Q2');
      } else {
        await controller.overrideMark('Q2', 0.5);
      }
    }
    expect(controller.moderationSampleCount, 6);
    expect(controller.agreement!.before, closeTo((0.5 * 5 + 0) / 6, 1e-9));
    expect(controller.agreement!.after.abs(), lessThan(controller.agreement!.before));
    final Moderation suggested = controller.suggestedModeration!;
    expect(suggested.longFactor, closeTo(3.5 / 6, 1e-9));
    expect(controller.moderationOutdated, isTrue);

    await controller.applyModeration();
    expect(controller.moderation.isActive, isTrue);
    expect(controller.moderationOutdated, isFalse);
    // The script the teacher did not mark is brought to their standard…
    expect(mark(controller, 3, 'Q1'), 0.5);
    expect(controller.scripts[3].result!.question('Q1')!.moderatedFrom, 1);
    // …and what the teacher marked or accepted stands.
    expect(mark(controller, 0, 'Q1'), 0.5);
    expect(mark(controller, 2, 'Q2'), 1);

    await controller.removeModeration();
    expect(controller.moderation.isActive, isFalse);
    expect(mark(controller, 3, 'Q1'), 1);
  });

  test('moderation is kept with the paper', () async {
    final CorrectionController controller = await fourScripts();
    for (final int script in <int>[0, 1, 2]) {
      controller.openScript(script);
      await controller.overrideMark('Q1', 0.5);
      await controller.overrideMark('Q2', 0.5);
    }
    await controller.applyModeration();

    // Choosing the paper again reads it back.
    await controller.chooseQuestionPaper();
    expect(controller.moderation.isActive, isTrue);
    expect(controller.moderation.longFactor, closeTo(0.5, 1e-9));
    expect(controller.moderationSampleCount, 6);
  });

  test('a class marked higher than real classes get is pointed out', () async {
    final CorrectionController controller = fakeController(picker: FakeFilePicker(questionPath)
      ..classSet = <String>[answerPath, secondPath, thirdPath]);
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    await controller.markAll();
    expect(controller.classMarksLookHigh, isFalse); // 50%

    for (final int script in <int>[0, 1, 2]) {
      controller.openScript(script);
      await controller.overrideMark('Q1', 2);
      await controller.overrideMark('Q2', 2);
    }
    expect(controller.classMarksLookHigh, isTrue);
  });

  test("the teacher's answer key replaces the AI's and asks for re-marking", () async {
    final CorrectionController controller = await fourScripts();
    expect(controller.markedPaper, isNotNull);
    expect(await controller.answerKey(), isNull); // no key engine in the fakes

    await controller.saveAnswerKeyEdits(<String, String>{'Q1': '- Names the mitochondrion [2]', 'Q2': ''});
    final AnswerKey key = (await controller.answerKey())!;
    expect(key.textFor('Q1'), '- Names the mitochondrion [2]');
    expect(key.edits.containsKey('Q2'), isFalse);
    expect(controller.scripts.every((MarkedScript s) => s.correctionsPending), isTrue);
    expect(controller.statusMessage, contains('Re-mark to apply it to 4 scripts'));
  });
}
