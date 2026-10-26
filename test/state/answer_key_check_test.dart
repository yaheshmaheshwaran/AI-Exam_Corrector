import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/marking/stage_store.dart';
import 'package:exam_corrector/marking/exam/answer_key.dart';
import 'package:exam_corrector/services/review/teacher_work_store.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'fakes.dart';

/// The AI's key as the pipeline saves it, written by [model].
JsonKey _aiKey(String model, {String point = 'Names the mitochondrion'}) => AnswerKey(entries: <String, AnswerKeyEntry>{
      'Q1': AnswerKeyEntry(
        questionId: 'Q1',
        maximum: 2,
        points: <AnswerKeyPoint>[AnswerKeyPoint(criterion: point, marks: 2)],
        model: model,
      ),
    }).toJson();

typedef JsonKey = Map<String, Object?>;

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _until(bool Function() done) async {
  for (int i = 0; i < 2000 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A class with its paper chosen and the AI's key saved for the paper.
Future<CorrectionController> _class(StageStore store,
    {AppConfig config = configuredApp, FakeMarker? marker, List<String>? scripts}) async {
  final CorrectionController controller = fakeController(
    config: config,
    store: store,
    marker: marker,
    picker: FakeFilePicker(questionPath)..classSet = scripts ?? <String>[answerPath, secondPath],
  );
  await controller.chooseAnswerSheet();
  await controller.chooseQuestionPaper();
  await TeacherWorkStore(store).saveAnswerKey(controller.questionPaper!.contentHash, _aiKey('gemini/gemini-3.6-flash'));
  return controller;
}

void main() {
  test("the AI's key says who wrote it and that it is not checked yet", () async {
    final CorrectionController controller = await _class(MemoryArtifactStore());
    await controller.markAll();
    await _settle();

    expect(controller.aiKeyStatus, (writer: 'Gemini (gemini-3.6-flash)', checked: false));
  });

  test('checking the key is remembered for the paper', () async {
    final MemoryArtifactStore store = MemoryArtifactStore();
    final CorrectionController controller = await _class(store);
    await controller.markAll();
    await _settle();

    await controller.saveAnswerKeyEdits(const <String, String>{}, checked: true);
    expect(controller.aiKeyStatus?.checked, isTrue);
    expect(controller.statusMessage, 'Answer key checked.');
    expect(controller.scripts.any((MarkedScript s) => s.correctionsPending), isFalse,
        reason: 'checking alone changes no mark');

    final CorrectionController again = fakeController(store: store, picker: FakeFilePicker(questionPath));
    await again.chooseQuestionPaper();
    expect(again.aiKeyStatus?.checked, isTrue);
  });

  test('a key the AI writes again needs checking again', () async {
    final MemoryArtifactStore store = MemoryArtifactStore();
    final CorrectionController controller = await _class(store);
    await controller.markAll();
    await _settle();
    await controller.saveAnswerKeyEdits(const <String, String>{}, checked: true);

    await TeacherWorkStore(store)
        .saveAnswerKey(controller.questionPaper!.contentHash, _aiKey('server/Qwen/Qwen3-VL-8B-Instruct', point: 'ATP'));
    await controller.chooseQuestionPaper();

    expect(controller.aiKeyStatus, (writer: 'GPU server (Qwen/Qwen3-VL-8B-Instruct)', checked: false));
  });

  test("a key the teacher's corrections cover entirely needs no check", () async {
    final CorrectionController controller = await _class(MemoryArtifactStore());
    await controller.markAll();
    await _settle();

    await controller.saveAnswerKeyEdits(const <String, String>{'Q1': 'Mitochondria [2]'});
    expect(controller.aiKeyStatus, isNull);
  });

  test('in the background, a changed key re-marks the class by itself', () async {
    final FakeMarker marker = FakeMarker();
    final CorrectionController controller = await _class(
      MemoryArtifactStore(),
      config: configuredApp.copyWith(backgroundProcessing: true),
      marker: marker,
    );
    await _until(() => !controller.isProcessing);
    final int first = marker.calls;

    final List<String> said = <String>[];
    controller.addListener(() => said.add(controller.statusMessage));
    await controller.saveAnswerKeyEdits(const <String, String>{'Q1': 'Mitochondria [2]'});
    expect(said, contains(contains('Re-marking 2 scripts in the background')));
    await _until(() => !controller.isProcessing);

    expect(marker.calls, greaterThan(first));
    expect(controller.scripts.any((MarkedScript s) => s.correctionsPending), isFalse);
  });

  test('without background marking, the teacher is asked to re-mark', () async {
    final CorrectionController controller = await _class(MemoryArtifactStore());
    await controller.markAll();

    await controller.saveAnswerKeyEdits(const <String, String>{'Q1': 'Mitochondria [2]'});
    expect(controller.statusMessage, contains('Re-mark to apply it to 2 scripts'));
    expect(controller.isProcessing, isFalse);
  });

  test('a key changed during a background run is applied to the scripts it already marked', () async {
    final Completer<void> first = Completer<void>();
    final Completer<void> second = Completer<void>();
    final FakeMarker marker = FakeMarker(gate: first);
    final CorrectionController controller = await _class(
      MemoryArtifactStore(),
      config: configuredApp.copyWith(backgroundProcessing: true),
      marker: marker,
      scripts: <String>[answerPath, secondPath, thirdPath],
    );
    await _until(() => marker.calls == 1);
    marker.gate = second;
    first.complete();
    await _until(() => marker.calls == 2);
    final MarkedScript done = controller.scripts.firstWhere((MarkedScript s) => s.result != null);

    await controller.saveAnswerKeyEdits(const <String, String>{'Q1': 'Mitochondria [2]'});
    expect(controller.statusMessage, contains('This run re-marks 1 script against it'));

    marker.gate = null;
    second.complete();
    await _until(() => !controller.isProcessing);

    expect(done.correctionsPending, isFalse, reason: 're-marked before the run ended');
    expect(marker.calls, greaterThanOrEqualTo(4));
  });
}
