import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/models/correction_request.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/screens/requests/requests_screen.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/results/session_results.dart';
import 'package:exam_corrector/state/app_session.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'account_fakes.dart';
import 'fakes.dart';

void main() {
  late SqliteResultsRepository db;
  setUp(() => db = SqliteResultsRepository.inMemory());
  tearDown(() => db.close());

  Future<CorrectionController> marked() async {
    final CorrectionController controller = fakeController(results: db, store: MemoryArtifactStore());
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    await controller.startCorrection();
    return controller;
  }

  group('publishing', () {
    test('is held back until the flagged questions are reviewed, and needs a roll number', () async {
      final CorrectionController controller = await marked();

      expect(await controller.publishCurrent(rollNo: '21CS045', subjectCode: 'CCS356', exam: 'CAT 1'), isFalse);
      expect(controller.pendingError, contains('1 question still needs your review'));

      await controller.acceptMark('Q2');
      expect(await controller.publishCurrent(rollNo: '', subjectCode: 'CCS356', exam: 'CAT 1'), isFalse);

      await controller.overrideMark('Q1', 2, comment: 'Well explained.');
      expect(await controller.publishCurrent(rollNo: '21cs045', student: 'Priya', subjectCode: 'ccs356', exam: 'CAT 1'), isTrue);

      final PublishedResult published = (await db.resultsFor(rollNo: '21CS045', subjectCode: 'CCS356')).single;
      expect(published.student, 'Priya');
      expect(published.total, controller.finalTotal);
      expect(published.questions.first.marks, 2);
      expect(published.questions.first.comment, 'Well explained.');
      // The answer goes with it: what was asked, what was read, and where.
      final PublishedQuestion first = published.questions.first;
      expect(first.questionText, isNotEmpty);
      expect(first.answerText, isNotEmpty);
      expect(first.answerBoxes, isNotEmpty);

      // The paper remembers where it was published, for next time.
      final ({String rollNo, String subjectCode, String exam}) next =
          await controller.publishDefaults(controller.currentScript!);
      expect(next.subjectCode, 'CCS356');
      expect(next.exam, 'CAT 1');
    });
  });

  test("a student's request, accepted by the teacher, changes the mark here and there", () async {
    final CorrectionController controller = await marked();
    await controller.acceptMark('Q2');
    await controller.publishCurrent(rollNo: '21CS045', subjectCode: 'CCS356', exam: 'CAT 1');
    final PublishedResult published = (await db.resultsFor(rollNo: '21CS045')).single;

    await db.requestCorrection(resultId: published.id, questionId: 'Q1', message: 'I named both parts.');
    await controller.refreshRequests();
    expect(controller.openRequestCount, 1);

    final CorrectionRequest request = (await controller.correctionRequests(openOnly: true)).single;
    expect(await controller.acceptRequest(request, 2, 'Agreed.'), isTrue);

    expect(controller.openRequestCount, 0);
    expect((await db.result(published.id))!.questions.first.marks, 2);
    // The open script agrees with the database.
    expect(controller.reviews['Q1']!.teacherMarks, 2);
    expect(controller.finalTotal, (await db.result(published.id))!.total);
  });

  testWidgets('roles: a student signs in, sees only their own results, and asks for a correction',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late CorrectionController controller;
    await tester.runAsync(() async {
      controller = await marked();
      await controller.acceptMark('Q2');
      await controller.publishCurrent(rollNo: '21CS045', student: 'Priya', subjectCode: 'CCS356', exam: 'CAT 1');
      // Someone else's result, in the same subject: never shown to Priya.
      await controller.publishCurrent(rollNo: '21CS046', student: 'Arun', subjectCode: 'CCS356', exam: 'CAT 1');
    });
    final MemoryAccountRepository accounts = MemoryAccountRepository.withCollege(resultsFor: (_) => db);
    final SessionResults results = SessionResults();
    final AppSession session = AppSession(accounts: accounts, results: results, localResults: db);
    await tester.runAsync(session.restore);
    await tester.pumpWidget(ExamCorrectorApp(controller: controller, session: session, results: results));
    await tester.pump();
    expect(find.byKey(const Key('sign-in-screen')), findsOneWidget);

    Future<void> signIn(String login) async {
      await tester.enterText(find.byKey(const Key('sign-in-login')), login);
      await tester.enterText(find.byKey(const Key('sign-in-password')), 'password1');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('sign-in-submit')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    // A wrong password is refused, in words.
    await tester.enterText(find.byKey(const Key('sign-in-login')), 'priya');
    await tester.enterText(find.byKey(const Key('sign-in-password')), 'nope-nope');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('sign-in-submit')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('Wrong email, username or password.'), findsOneWidget);

    // Student, by username: straight to their own results.
    await signIn('priya');
    expect(find.text('Settings'), findsNothing);
    expect(find.textContaining('Priya S · 21CS045 · PSG Tech'), findsOneWidget);
    expect(find.text('CCS356 · CAT 1'), findsOneWidget, reason: 'only 21CS045’s result');

    Future<void> filter(String subject) async {
      await tester.enterText(find.byKey(const Key('student-subject')), subject);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('student-search')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
    }

    await filter('CS3401');
    expect(find.byKey(const Key('student-none')), findsOneWidget);
    await filter('ccs356');
    expect(find.text('CCS356 · CAT 1'), findsOneWidget);
    await tester.tap(find.text('CCS356 · CAT 1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('student-total')), findsOneWidget);

    // Their own answer, question by question.
    await tester.tap(find.byKey(const ValueKey<String>('view-answer-Q1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('answer-text-Q1')), findsOneWidget);
    expect(find.text('Hide my answer'), findsOneWidget);
    // The fake renderer keeps no page images: the sheet says so.
    await tester.tap(find.byKey(const Key('tab-sheet')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sheet-not-kept')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tab-marks')));
    await tester.pumpAndSettle();

    // Ask about question 1.
    await tester.tap(find.byKey(const ValueKey<String>('request-Q1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('request-reason')), 'I named the mitochondrion and ATP.');
    await tester.pump();
    await tester.tap(find.byKey(const Key('request-send')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey<String>('request-status-Q1')),
        matching: find.byType(Text),
      )).data,
      'Requested · waiting for your teacher',
    );
    expect(find.byKey(const ValueKey<String>('request-Q1')), findsNothing);

    // Teacher, by email: the badge counts it.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('switch-role')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign-in-screen')), findsOneWidget);
    await signIn('teach@college.edu');
    await tester.runAsync(controller.refreshRequests);
    await tester.pumpAndSettle();
    expect(controller.openRequestCount, 1);
    expect(find.byKey(const Key('open-requests')), findsOneWidget);
    expect(find.byKey(const Key('account-menu')), findsOneWidget);
  });

  testWidgets('the teacher accepts a request in the Requests screen; the student sees the new mark',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late CorrectionController controller;
    late PublishedResult published;
    await tester.runAsync(() async {
      controller = await marked();
      await controller.acceptMark('Q2');
      await controller.publishCurrent(rollNo: '21CS045', subjectCode: 'CCS356', exam: 'CAT 1');
      published = (await db.resultsFor(rollNo: '21CS045')).single;
      await db.requestCorrection(resultId: published.id, questionId: 'Q1', message: 'Both parts are there.');
    });
    await tester.pumpWidget(MaterialApp(home: RequestsScreen(controller: controller)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    // The first waiting request is open beside the answer.
    expect(find.byKey(const Key('detail-reason')), findsOneWidget);
    expect(find.textContaining('Both parts are there.'), findsWidgets);
    expect(find.byKey(const ValueKey<String>('answer-text-Q1')), findsOneWidget);

    // An impossible mark cannot be saved; the current one is no change.
    await tester.enterText(find.byKey(const Key('detail-marks')), '9');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('change-mark'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('detail-marks')), '1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('mark-up')));
    await tester.pump();
    expect(find.text('Change mark to 1.5'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mark-up')));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('detail-reply')), 'Agreed, both are named.');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('change-mark')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('requests-empty')), findsOneWidget);
    final CorrectionRequest answered = (await tester.runAsync(() => db.requests()))!.single;
    expect(answered.status, RequestStatus.accepted);
    expect(answered.newMarks, 2);
    expect((await tester.runAsync(() => db.result(published.id)))!.questions.first.marks, 2);
  });
}

