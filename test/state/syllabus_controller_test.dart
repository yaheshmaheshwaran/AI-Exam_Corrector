import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/screens/home/home_screen.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'fakes.dart';

void main() {
  late Directory dir;
  late SyllabusLibrary library;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('syllabi');
    library = SyllabusLibrary(Directory('${dir.path}/library'));
  });
  tearDown(() async => dir.delete(recursive: true));

  Future<CorrectionController> ready() async {
    // A fresh picker each time: it hands out its files in order.
    final FakeFilePicker picker = FakeFilePicker(answerPath, questionPath)
      ..syllabusPath = 'sample/syllabus_iot.txt';
    final CorrectionController controller =
        fakeController(picker: picker, syllabi: library, store: MemoryArtifactStore());
    await controller.reloadSyllabi();
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    return controller;
  }

  test('a syllabus is uploaded to the library and can be removed', () async {
    final CorrectionController controller = await ready();

    final Syllabus? added = await controller.addSyllabus();
    expect(added?.courseCode, 'CCS356');
    expect(controller.syllabi.single.units, hasLength(5));
    expect(controller.statusMessage, contains('5 units'));

    await controller.removeSyllabus(added!.id);
    expect(controller.syllabi, isEmpty);
  });

  test("the teacher's choice is saved for the paper and used when marking", () async {
    final CorrectionController controller = await ready();
    final Syllabus added = (await controller.addSyllabus())!;
    // The fake paper is about cells: nothing matches it on its own.
    expect(controller.syllabusInUse, isNull);

    await controller.startCorrection();
    await controller.chooseSyllabus(added.id);
    expect(controller.syllabusInUse?.how, 'chosen by you');
    expect(controller.hasPendingCorrections, isTrue);
    expect(controller.statusMessage, contains('Re-mark to apply'));

    await controller.startCorrection();
    expect(controller.assessment!.syllabus?.id, added.id);

    // Kept for this paper across a restart.
    final CorrectionController reopened = await ready();
    expect(reopened.syllabusChoice, added.id);

    await reopened.chooseSyllabus(SyllabusLibrary.none);
    await reopened.startCorrection();
    expect(reopened.pendingError, isNull);
    expect(reopened.assessment!.syllabus, isNull);
  });

  test('several dropped files are added one by one; a bad one does not stop the rest', () async {
    final CorrectionController controller = await ready();
    final File os = File('${dir.path}/os.txt')
      ..writeAsStringSync('Course Code: CS3401\nCourse Title: Operating Systems\n'
          'UNIT I PROCESSES 9\nProcess states – Threads\nUNIT II MEMORY 9\nPaging – Segmentation');
    final File photo = File('${dir.path}/scan.png')..writeAsStringSync('x');
    final File letter = File('${dir.path}/letter.txt')..writeAsStringSync('Dear students.');

    final List<Syllabus> added = await controller.addSyllabusFiles(<String>[
      'sample/syllabus_iot.txt',
      photo.path,
      os.path,
      letter.path,
    ]);

    expect(added.map((Syllabus s) => s.courseCode), <String>['CCS356', 'CS3401']);
    expect(controller.syllabi, hasLength(2));
    expect(controller.statusMessage, '2 syllabi saved from 2 files. 2 could not be read.');
    expect(controller.pendingError, contains('scan.png: not a PDF, PowerPoint (.pptx), Word (.docx) or text file.'));
    expect(controller.pendingError, contains('letter.txt: No units or topics'));
    expect(controller.isBusy, isFalse);
  });

  test('clearing the cache keeps every syllabus', () async {
    final CorrectionController controller = await ready();
    await controller.addSyllabus();
    await controller.clearCache();
    await controller.reloadSyllabi();
    expect(controller.syllabi, hasLength(1));
  });

  testWidgets('the home screen offers the library and shows the syllabus in use', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late CorrectionController controller;
    await tester.runAsync(() async {
      controller = await ready();
      final Syllabus added = (await controller.addSyllabus())!;
      await controller.chooseSyllabus(added.id);
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: controller)));
    await tester.pump();

    expect(find.byKey(const Key('open-syllabi')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('syllabus-line'))).data,
      'Syllabus: Internet of Things and its Applications (CCS356) · chosen by you',
    );

    await tester.tap(find.byKey(const Key('open-syllabi')));
    await tester.pumpAndSettle();
    expect(find.text('Internet of Things and its Applications (CCS356)'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('5 units')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('syllabus-drop-zone')), findsOneWidget);
    expect(find.text('Drop syllabus files here, or click to choose'), findsOneWidget);
  });

  testWidgets('the main screen lists every uploaded file and its courses', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late CorrectionController controller;
    await tester.runAsync(() async {
      controller = await ready();
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: controller)));
    await tester.pump();

    // Empty, it invites a drop.
    expect(find.text('Syllabi (0)'), findsOneWidget);
    expect(find.text('Drop syllabus files here, or click to choose'), findsOneWidget);

    await tester.runAsync(() async {
      final Syllabus added = (await controller.addSyllabus())!;
      await controller.chooseSyllabus(added.id);
    });
    await tester.pump();

    expect(find.text('Syllabi (1)'), findsOneWidget);
    expect(find.text('syllabus_iot.txt'), findsOneWidget);
    expect(find.text('Internet of Things and its Applications (CCS356) · 5 units'), findsOneWidget);
    expect(find.text('used for this paper'), findsOneWidget);

    // A course opens to show what was read.
    await tester.tap(find.text('Internet of Things and its Applications (CCS356) · 5 units'));
    await tester.pumpAndSettle();
    expect(find.text('Unit III — IoT Communication and Connectivity  ·  9 hours'), findsOneWidget);
  });
}
