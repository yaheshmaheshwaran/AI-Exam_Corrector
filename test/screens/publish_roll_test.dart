import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/models/correction_request.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/models/student_status.dart';
import 'package:exam_corrector/screens/home/home_screen.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/results/session_results.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import '../state/fakes.dart';

/// A college server's results, as far as publishing needs: who has signed
/// up, and everything else passed to a database on this computer.
class _CollegeResults implements ResultsRepository, StudentDirectory {
  _CollegeResults(this.db, this.rolls);

  final SqliteResultsRepository db;
  final Set<String> rolls;

  @override
  Future<Set<String>> registeredRolls() async => rolls;

  @override
  Future<PublishedResult> publish(PublishedResult result) => db.publish(result);
  @override
  Future<PublishedResult?> result(String id) => db.result(id);
  @override
  Future<List<PublishedResult>> resultsFor({required String rollNo, String? subjectCode}) =>
      db.resultsFor(rollNo: rollNo, subjectCode: subjectCode);
  @override
  Future<List<PublishedResult>> all() => db.all();
  @override
  Future<void> unpublish(String id) => db.unpublish(id);
  @override
  Future<CorrectionRequest> requestCorrection({
    required String resultId,
    required String questionId,
    required String message,
  }) => db.requestCorrection(resultId: resultId, questionId: questionId, message: message);
  @override
  Future<List<CorrectionRequest>> requests({
    String? rollNo,
    String? subjectCode,
    String? resultId,
    bool openOnly = false,
  }) => db.requests(rollNo: rollNo, subjectCode: subjectCode, resultId: resultId, openOnly: openOnly);
  @override
  Future<int> openRequestCount() => db.openRequestCount();
  @override
  Future<PublishedResult> acceptRequest(int id, {required double marks, required String reply}) =>
      db.acceptRequest(id, marks: marks, reply: reply);
  @override
  Future<void> declineRequest(int id, {required String reply}) => db.declineRequest(id, reply: reply);
  @override
  Future<void> markSeen(String resultId) => db.markSeen(resultId);
  @override
  Future<PublishedResult> verify(String resultId) => db.verify(resultId);
  @override
  Future<List<StudentStatus>> overview({String? subjectCode, String? exam}) =>
      db.overview(subjectCode: subjectCode, exam: exam);
  @override
  Future<List<String>> subjects() => db.subjects();
  @override
  Future<List<String>> exams({String? subjectCode}) => db.exams(subjectCode: subjectCode);
  @override
  Future<({String subjectCode, String exam})?> paperDefaults(String paperHash) => db.paperDefaults(paperHash);
  @override
  Future<void> savePaperDefaults(String paperHash, {required String subjectCode, required String exam}) =>
      db.savePaperDefaults(paperHash, subjectCode: subjectCode, exam: exam);
  @override
  void close() => db.close();
}

void main() {
  testWidgets('publishing to a roll no student has signed up with says so, and still publishes', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final SqliteResultsRepository db = SqliteResultsRepository.inMemory();
    addTearDown(db.close);
    final SessionResults results = SessionResults(active: _CollegeResults(db, <String>{'21CS045'}));
    late CorrectionController controller;
    await tester.runAsync(() async {
      controller = fakeController(results: results, store: MemoryArtifactStore());
      await controller.chooseAnswerSheet();
      await controller.chooseQuestionPaper();
      await controller.startCorrection();
      await controller.acceptMark('Q2');
    });
    expect(await tester.runAsync(controller.registeredRolls), <String>{'21CS045'});

    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('publish')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('publish-roll')), '21cs045');
    await tester.pump();
    expect(find.byKey(const Key('publish-roll-unregistered')), findsNothing, reason: 'Priya has signed up');
    await tester.enterText(find.byKey(const Key('publish-roll')), '21CS099');
    await tester.pump();
    expect(find.byKey(const Key('publish-roll-unregistered')), findsOneWidget);
    expect(find.textContaining('No student has signed up with 21CS099 yet'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('publish-subject')), 'CCS356');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('publish-confirm')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect((await tester.runAsync(() => db.resultsFor(rollNo: '21CS099')))!, hasLength(1));
  });
}
