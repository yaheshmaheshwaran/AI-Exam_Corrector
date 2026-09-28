import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/screens/home/home_screen.dart';
import 'package:exam_corrector/screens/students/student_status_screen.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/state/app_session.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'account_fakes.dart';
import 'fakes.dart';

void main() {
  late SqliteResultsRepository db;
  setUp(() => db = SqliteResultsRepository.inMemory());
  tearDown(() => db.close());

  Future<CorrectionController> published({FakeFilePicker? picker}) async {
    final CorrectionController controller = fakeController(results: db, store: MemoryArtifactStore(), picker: picker);
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    await controller.startCorrection();
    await controller.acceptMark('Q2');
    await controller.publishCurrent(rollNo: '21CS045', student: 'Priya', subjectCode: 'CCS356', exam: 'CAT 1');
    return controller;
  }

  void big(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('a student opens, verifies — held back while a request waits', (WidgetTester tester) async {
    big(tester);
    late CorrectionController controller;
    await tester.runAsync(() async => controller = await published());
    final Account student = MemoryAccountRepository.withCollege().account('priya');
    await tester.pumpWidget(ExamCorrectorApp(controller: controller, session: AppSession.signedIn(student), results: db));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('student-subject')), 'CCS356');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('student-search')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('· New'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('CCS356 · CAT 1'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final PublishedResult seen = (await tester.runAsync(() => db.resultsFor(rollNo: '21CS045')))!.single;
    expect(seen.isSeen, isTrue);

    // A request waiting holds verification back.
    await tester.runAsync(() => db.requestCorrection(resultId: seen.id, questionId: 'Q1', message: 'Check.'));
    await tester.tap(find.byKey(const Key('student-back')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('student-search')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('· Request waiting'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('CCS356 · CAT 1'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('verify'))).onPressed, isNull);

    // The teacher answers; now the student can verify.
    await tester.runAsync(() async {
      final int id = (await db.requests()).single.id;
      await db.declineRequest(id, reply: 'It stands.');
    });
    await tester.tap(find.byKey(const Key('student-back')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('student-search')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('CCS356 · CAT 1'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('verify')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('verify-confirm')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('verified-badge')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('request-Q3')), findsNothing);
    expect((await tester.runAsync(() => db.result(seen.id)))!.isVerified, isTrue);
  });

  testWidgets("the teacher's table: who has seen, verified, asked — filtered and exported", (WidgetTester tester) async {
    big(tester);
    // Synchronous: real asynchronous file work never completes on a widget
    // test's fake clock.
    final Directory dir = Directory.systemTemp.createTempSync('export');
    addTearDown(() => dir.deleteSync(recursive: true));
    final FakeFilePicker picker = FakeFilePicker(answerPath, questionPath)..savePath = '${dir.path}/students.csv';
    late CorrectionController controller;
    await tester.runAsync(() async {
      controller = await published(picker: picker);
      final PublishedResult one = (await db.resultsFor(rollNo: '21CS045')).single;
      // Two more students, straight into the database.
      for (final String roll in <String>['21CS046', '21CS047']) {
        await db.publish(PublishedResult(
          id: '',
          rollNo: roll,
          subjectCode: 'CCS356',
          exam: 'CAT 1',
          student: '',
          paperTitle: 'IoT',
          fileName: '$roll.pdf',
          publishedAt: DateTime(2026, 9, 26),
          total: 3,
          maximum: 4,
          percentage: 75,
          questions: one.questions,
        ));
      }
      final PublishedResult b = (await db.resultsFor(rollNo: '21CS046')).single;
      await db.markSeen(one.id);
      await db.verify(one.id);
      await db.markSeen(b.id);
      await db.requestCorrection(resultId: b.id, questionId: 'Q1', message: 'Please check.');
    });

    await tester.pumpWidget(MaterialApp(home: StudentStatusScreen(controller: controller)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('students-table')), findsOneWidget);
    expect(find.text('21CS045'), findsOneWidget);
    expect(find.text('21CS046'), findsOneWidget);
    expect(find.text('1 open'), findsOneWidget);
    expect(find.text('Priya'), findsOneWidget);

    // "Not seen" filters to the one who has not looked.
    await tester.tap(find.byKey(const ValueKey<String>('figure-notSeen')));
    await tester.pumpAndSettle();
    expect(find.text('21CS047'), findsOneWidget);
    expect(find.text('21CS045'), findsNothing);

    // Export what is shown.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('export-students')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final List<String> lines = File('${dir.path}/students.csv').readAsLinesSync();
    expect(lines.first, startsWith('Roll no,Name,Subject,Exam,Marks'));
    expect(lines, hasLength(2));
    expect(lines.first, endsWith('Status,Syllabus badges'));
    expect(lines.last, allOf(startsWith('21CS047'), endsWith('Not seen,0')));
  });

  testWidgets('the top bar fits a narrow window with every tool in it', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final CorrectionController controller = fakeController(results: db);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: controller, onSwitchRole: () {})));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('open-students')), findsOneWidget);
    expect(find.byType(IconButton), findsWidgets);
  });
}
