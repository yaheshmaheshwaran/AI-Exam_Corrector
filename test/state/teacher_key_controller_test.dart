import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/pipeline/marking/teacher_key.dart';
import 'package:exam_corrector/services/document_text_reader.dart';
import 'package:exam_corrector/services/pdf_service.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'fakes.dart';

class _ScannedPdf extends PdfService {
  const _ScannedPdf();

  @override
  Future<String?> extractTextIfPresent(String path) async => null;
}

void main() {
  late Directory dir;
  late File key;
  late File other;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('teacher-key');
    key = File('${dir.path}/BIO-key.txt')..writeAsStringSync('1. The mitochondrion (2 marks)\n');
    other = File('${dir.path}/BIO-key-v2.txt')
      ..writeAsStringSync('1. Mitochondria\n2. They need energy for contraction.\n');
  });
  tearDown(() => dir.delete(recursive: true));

  CorrectionController controllerWith(FakeFilePicker picker) => fakeController(picker: picker);

  test('an answer key is matched to the paper straight away and remembered for it', () async {
    final FakeFilePicker picker = FakeFilePicker(answerPath, questionPath)..answerKeyPath = key.path;
    final CorrectionController controller = controllerWith(picker);
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    expect(controller.teacherKey, isNull);

    await controller.chooseAnswerKey();
    expect(controller.teacherKey!.fileName, 'BIO-key.txt');
    expect(controller.keyCoverage, (covered: 1, total: 2, printed: 0));
    expect(controller.statusMessage, contains('covers 1 of 2 questions'));

    // The key the dialog shows, before any script is marked.
    final AnswerKey? shown = await controller.answerKey();
    expect(shown!.sourceFor('Q1'), AnswerKeySource.teacher);
    expect(controller.keyPaper, isNotNull);

    // Choosing the same paper again brings the key back.
    await controller.chooseQuestionPaper();
    expect(controller.teacherKey!.fileName, 'BIO-key.txt');
  });

  test('a new key, or none, flags the marked scripts for re-marking', () async {
    final FakeFilePicker picker = FakeFilePicker(answerPath, questionPath)..answerKeyPath = key.path;
    final CorrectionController controller = controllerWith(picker);
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    await controller.chooseAnswerKey();
    await controller.startCorrection();
    expect(controller.result, isNotNull);
    expect(controller.hasPendingCorrections, isFalse);

    picker.answerKeyPath = other.path;
    await controller.chooseAnswerKey();
    expect(controller.keyCoverage, (covered: 2, total: 2, printed: 0));
    expect(controller.hasPendingCorrections, isTrue);
    expect(controller.statusMessage, contains('Re-mark to apply it'));

    await controller.startCorrection();
    expect(controller.hasPendingCorrections, isFalse);
    await controller.removeAnswerKey();
    expect(controller.teacherKey, isNull);
    expect(controller.hasPendingCorrections, isTrue);
  });

  test('a scanned key is refused, and says what to choose instead', () async {
    final File scan = File('${dir.path}/key.pdf')..writeAsStringSync('%PDF-1.4');
    await expectLater(
      const DocumentTextReader(pdf: _ScannedPdf()).readAnswerKey(scan.path),
      throwsA(isA<AnswerKeyException>().having((AnswerKeyException e) => e.message, 'message', contains('is a scan'))),
    );
  });

  test('a typed text key is read as it is, with its content hash', () async {
    final TeacherKeySource read = await const DocumentTextReader().readAnswerKey(key.path);
    expect(read.text, startsWith('1. The mitochondrion'));
    expect(read.hash, isNotEmpty);
  });
}
