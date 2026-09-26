import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/models/correction_request.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/models/student_status.dart';
import 'package:exam_corrector/services/results/results_repository.dart';

PublishedResult result({
  String roll = '21CS045',
  String subject = 'CCS356',
  String exam = 'CAT 1',
  double q3 = 2,
  TotalRounding rounding = TotalRounding.none,
}) =>
    PublishedResult(
      id: '',
      rollNo: roll,
      subjectCode: subject,
      exam: exam,
      student: 'Priya',
      paperTitle: 'Internet of Things',
      fileName: '21CS045_answers.pdf',
      publishedAt: DateTime(2026, 9, 26, 10),
      total: 5 + q3,
      maximum: 14,
      percentage: (5 + q3) / 14 * 100,
      totalRounding: rounding,
      sections: const <PublishedSection>[
        PublishedSection(sectionId: 'A', title: 'Section A', marks: 0, maximum: 4),
        PublishedSection(sectionId: 'B', title: 'Section B', marks: 0, maximum: 10),
      ],
      questions: <PublishedQuestion>[
        const PublishedQuestion(questionId: 'Q1', number: '1', section: 'A', marks: 2, maximum: 2, explanation: 'Right.'),
        const PublishedQuestion(questionId: 'Q2', number: '2', section: 'A', marks: 1.5, maximum: 2),
        PublishedQuestion(questionId: 'Q3', number: '3', section: 'B', marks: q3, maximum: 5, explanation: 'Missed the unit.'),
        const PublishedQuestion(questionId: 'Q4', number: '4', section: 'B', marks: 1.5, maximum: 5),
        const PublishedQuestion(questionId: 'Q5', number: '5', section: 'B', marks: 4, maximum: 5, counted: false),
      ],
    );

void main() {
  late SqliteResultsRepository db;
  setUp(() => db = SqliteResultsRepository.inMemory());
  tearDown(() => db.close());

  test('a result is stored under roll number, subject and exam, and found by them', () async {
    final PublishedResult saved = await db.publish(result());
    expect(saved.id, isNotEmpty);
    expect(saved.questions, hasLength(5));
    expect(saved.sections.first.marks, 3.5);
    // The uncounted alternative is not in its section's marks.
    expect(saved.sections.last.marks, 3.5);

    await db.publish(result(subject: 'CS3401', exam: 'CAT 1'));
    await db.publish(result(roll: '21CS046'));

    expect(await db.resultsFor(rollNo: '21cs045', subjectCode: 'ccs 356'), hasLength(1));
    expect(await db.resultsFor(rollNo: '21CS045'), hasLength(2));
    expect(await db.resultsFor(rollNo: '21CS099'), isEmpty);
  });

  test('publishing again replaces the result and keeps its requests', () async {
    final PublishedResult first = await db.publish(result());
    await db.requestCorrection(resultId: first.id, questionId: 'Q3', message: 'I wrote the unit on page 2.');

    final PublishedResult again = await db.publish(result(q3: 3));
    expect(again.id, first.id);
    expect(again.questions[2].marks, 3);
    expect(await db.all(), hasLength(1));
    expect(await db.requests(resultId: again.id), hasLength(1));
  });

  test('a request is raised once, then accepted: the mark and every total change', () async {
    final PublishedResult saved = await db.publish(result(rounding: TotalRounding.up));
    final CorrectionRequest request =
        await db.requestCorrection(resultId: saved.id, questionId: 'Q3', message: 'The unit is on page 2.');
    expect(request.status, RequestStatus.open);
    expect(request.questionNumber, '3');
    expect(request.currentMarks, 2);
    expect(request.explanation, 'Missed the unit.');
    expect(await db.openRequestCount(), 1);

    await expectLater(
      db.requestCorrection(resultId: saved.id, questionId: 'Q3', message: 'Again'),
      throwsA(isA<ResultsException>()),
    );
    await expectLater(
      db.acceptRequest(request.id, marks: 6, reply: 'x'),
      throwsA(isA<ResultsException>()),
    );

    final PublishedResult changed = await db.acceptRequest(request.id, marks: 3.5, reply: 'Agreed — the unit is there.');
    // 2 + 1.5 + 3.5 + 1.5 = 8.5, rounded up by the college rule.
    expect(changed.total, 9);
    expect(changed.questions[2].marks, 3.5);
    expect(changed.sections.last.marks, 5);

    final CorrectionRequest answered = (await db.requests(rollNo: '21CS045')).single;
    expect(answered.status, RequestStatus.accepted);
    expect(answered.oldMarks, 2);
    expect(answered.newMarks, 3.5);
    expect(answered.reply, 'Agreed — the unit is there.');
    expect(await db.openRequestCount(), 0);

    // Now answered, the question can be asked about again.
    await db.requestCorrection(resultId: saved.id, questionId: 'Q3', message: 'One more thing.');
  });

  test('a declined request needs a reason, and leaves the mark alone', () async {
    final PublishedResult saved = await db.publish(result());
    final CorrectionRequest request =
        await db.requestCorrection(resultId: saved.id, questionId: 'Q4', message: 'Please check.');

    await expectLater(db.declineRequest(request.id, reply: ' '), throwsA(isA<ResultsException>()));
    await db.declineRequest(request.id, reply: 'The definition is incomplete.');

    expect((await db.result(saved.id))!.questions[3].marks, 1.5);
    final CorrectionRequest declined = (await db.requests(subjectCode: 'CCS356')).single;
    expect(declined.status, RequestStatus.declined);
    expect(await db.requests(openOnly: true), isEmpty);
  });

  test('publishing needs a roll number and a subject', () async {
    await expectLater(db.publish(result(roll: '')), throwsA(isA<ResultsException>()));
    await expectLater(db.publish(result(subject: '')), throwsA(isA<ResultsException>()));
  });

  test("a paper remembers the subject and exam it was published under", () async {
    expect(await db.paperDefaults('paper'), isNull);
    await db.savePaperDefaults('paper', subjectCode: 'ccs356', exam: 'CAT 1');
    expect(await db.paperDefaults('paper'), (subjectCode: 'CCS356', exam: 'CAT 1'));
  });

  test('results published as files before are brought in, once', () async {
    final Directory dir = await Directory.systemTemp.createTemp('import');
    addTearDown(() => dir.delete(recursive: true));
    final Directory folder = Directory('${dir.path}/published')..createSync();
    File('${folder.path}/a.json').writeAsStringSync(jsonEncode(PublishedResult(
      id: 'old',
      student: 'Priya',
      paperTitle: 'IoT',
      fileName: '21CS045_answers.pdf',
      publishedAt: DateTime(2026, 9, 20),
      total: 5,
      maximum: 10,
      percentage: 50,
    ).toJson()));

    expect(await db.importFolder(folder), 1);
    expect((await db.resultsFor(rollNo: '21CS045')).single.exam, 'IoT');
    expect(folder.existsSync(), isFalse);
    expect(Directory('${folder.path}-imported').existsSync(), isTrue);
  });

  test('a roll number is found in a file name, or left for the teacher', () {
    expect(PublishedResult.rollFromFileName('21CS045_answers.pdf'), '21CS045');
    expect(PublishedResult.rollFromFileName('answers 2021cse045.pdf'), '2021CSE045');
    expect(PublishedResult.rollFromFileName('311521104045.pdf'), '311521104045');
    expect(PublishedResult.rollFromFileName('scan_7.pdf'), isNull);
    expect(PublishedResult.rollFromFileName('DocScanner 02-Sep-2026.pdf'), isNull);
  });

  test('the database file survives being closed and opened again', () async {
    final Directory dir = await Directory.systemTemp.createTemp('db');
    addTearDown(() => dir.delete(recursive: true));
    final File file = File('${dir.path}/exam_corrector.db');
    final SqliteResultsRepository first = SqliteResultsRepository.open(file);
    await first.publish(result());
    first.close();
    final SqliteResultsRepository second = SqliteResultsRepository.open(file);
    expect(await second.resultsFor(rollNo: '21CS045'), hasLength(1));
    second.close();
  });

  group('the answer sheet', () {
    // A real 1×1 PNG.
    final List<int> png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );

    test('is copied out of the cache, kept with each answer, and removed with the result', () async {
      final Directory dir = await Directory.systemTemp.createTemp('sheets');
      addTearDown(() => dir.delete(recursive: true));
      final File cached = File('${dir.path}/cache/page_1.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png);
      final SqliteResultsRepository repo =
          SqliteResultsRepository.inMemory(answerSheets: Directory('${dir.path}/answer-sheets'));
      addTearDown(repo.close);

      final PublishedResult withSheet = PublishedResult(
        id: '',
        rollNo: '21CS045',
        subjectCode: 'CCS356',
        exam: 'CAT 1',
        student: '',
        paperTitle: 'IoT',
        fileName: 'a.pdf',
        publishedAt: DateTime(2026, 9, 26),
        total: 2,
        maximum: 5,
        percentage: 40,
        questions: const <PublishedQuestion>[
          PublishedQuestion(
            questionId: 'Q1',
            number: '1',
            marks: 2,
            maximum: 5,
            questionText: 'Define an embedded system.',
            answerText: 'A computer inside a device for one job.',
            answerBoxes: <AnswerBox>[AnswerBox(page: 1, x: 0.1, y: 0.2, width: 0.8, height: 0.1)],
          ),
        ],
        pages: <PublishedPage>[PublishedPage(number: 1, imagePath: cached.path, width: 1000, height: 1400)],
      );

      final PublishedResult saved = await repo.publish(withSheet);
      final PublishedPage page = saved.pages.single;
      expect(page.imagePath, startsWith('${dir.path}/answer-sheets/${saved.id}/'));
      // Clearing the cache does not touch it.
      cached.deleteSync();
      expect(File(page.imagePath).existsSync(), isTrue);

      final PublishedQuestion q = saved.questions.single;
      expect(q.questionText, 'Define an embedded system.');
      expect(q.answerText, 'A computer inside a device for one job.');
      expect(q.answerBoxes.single.y, 0.2);
      expect(q.answerPages, <int>[1]);

      await repo.unpublish(saved.id);
      expect(Directory('${dir.path}/answer-sheets/${saved.id}').existsSync(), isFalse);
    });

    test('a database from before answer sheets were kept is brought up to date', () async {
      final Directory dir = await Directory.systemTemp.createTemp('v1');
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}/exam_corrector.db');
      // Version 1: results and questions without the answer columns.
      final Database old = sqlite3.open(file.path);
      old.execute("""
        CREATE TABLE results (id INTEGER PRIMARY KEY AUTOINCREMENT, roll_no TEXT NOT NULL,
          student_name TEXT NOT NULL DEFAULT '', subject_code TEXT NOT NULL, exam TEXT NOT NULL DEFAULT '',
          paper_title TEXT NOT NULL DEFAULT '', file_name TEXT NOT NULL DEFAULT '', paper_hash TEXT NOT NULL DEFAULT '',
          script_hash TEXT NOT NULL DEFAULT '', total REAL NOT NULL, maximum REAL NOT NULL, percentage REAL NOT NULL,
          total_rounding TEXT NOT NULL DEFAULT 'none', standard TEXT NOT NULL DEFAULT '', published_at TEXT NOT NULL,
          updated_at TEXT NOT NULL, UNIQUE (roll_no, subject_code, exam));
        CREATE TABLE result_sections (result_id INTEGER NOT NULL, position INTEGER NOT NULL, section_id TEXT,
          title TEXT NOT NULL, maximum REAL NOT NULL);
        CREATE TABLE result_questions (result_id INTEGER NOT NULL, position INTEGER NOT NULL, question_id TEXT NOT NULL,
          number TEXT NOT NULL, section_id TEXT, marks REAL NOT NULL, maximum REAL NOT NULL, ai_marks REAL,
          explanation TEXT NOT NULL DEFAULT '', comment TEXT NOT NULL DEFAULT '', counted INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE correction_requests (id INTEGER PRIMARY KEY AUTOINCREMENT, result_id INTEGER NOT NULL,
          question_id TEXT NOT NULL, roll_no TEXT NOT NULL, subject_code TEXT NOT NULL, message TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'open', reply TEXT NOT NULL DEFAULT '', old_marks REAL, new_marks REAL,
          created_at TEXT NOT NULL, resolved_at TEXT);
        CREATE TABLE paper_defaults (paper_hash TEXT PRIMARY KEY, subject_code TEXT NOT NULL, exam TEXT NOT NULL);
        INSERT INTO results (roll_no, subject_code, exam, total, maximum, percentage, published_at, updated_at)
          VALUES ('21CS045', 'CCS356', 'CAT 1', 3, 5, 60, '2026-09-20T00:00:00Z', '2026-09-20T00:00:00Z');
        INSERT INTO result_questions (result_id, position, question_id, number, marks, maximum)
          VALUES (1, 0, 'Q1', '1', 3, 5);
      """);
      old.userVersion = 1;
      old.close();

      final SqliteResultsRepository repo = SqliteResultsRepository.open(file);
      addTearDown(repo.close);
      final PublishedResult kept = (await repo.resultsFor(rollNo: '21CS045')).single;
      expect(kept.total, 3);
      expect(kept.questions.single.answerText, isEmpty);
      expect(kept.questions.single.badge, SyllabusBadge.none);
      expect(kept.pages, isEmpty);
    });
  });

  test('syllabus badges are kept, and counted in the overview', () async {
    final PublishedResult base = result();
    final PublishedResult withBadges = PublishedResult(
      id: '',
      rollNo: base.rollNo,
      subjectCode: base.subjectCode,
      exam: base.exam,
      student: base.student,
      paperTitle: base.paperTitle,
      fileName: base.fileName,
      publishedAt: base.publishedAt,
      total: base.total,
      maximum: base.maximum,
      percentage: base.percentage,
      sections: base.sections,
      questions: <PublishedQuestion>[
        const PublishedQuestion(questionId: 'Q1', number: '1', section: 'A', marks: 2, maximum: 2,
            badge: SyllabusBadge.exact, bonus: 0.5),
        const PublishedQuestion(questionId: 'Q2', number: '2', section: 'A', marks: 1.5, maximum: 2,
            badge: SyllabusBadge.almost),
        // The alternative that does not count earns no badge in the count.
        const PublishedQuestion(questionId: 'Q5', number: '5', section: 'B', marks: 4, maximum: 5,
            counted: false, badge: SyllabusBadge.exact),
      ],
    );
    final PublishedResult saved = await db.publish(withBadges);
    expect(saved.questions.first.badge, SyllabusBadge.exact);
    expect(saved.questions.first.bonus, 0.5);
    expect(saved.questions[1].badge, SyllabusBadge.almost);
    expect((await db.overview()).single.badges, 2);
    expect(PublishedQuestion.fromJson(saved.questions.first.toJson())!.badge, SyllabusBadge.exact);
  });

  group('seen and verified', () {
    test('seen is kept from the first time, and each view counted', () async {
      final PublishedResult saved = await db.publish(result());
      expect(saved.isSeen, isFalse);
      await db.markSeen(saved.id);
      final DateTime first = (await db.result(saved.id))!.firstSeenAt!;
      await db.markSeen(saved.id);
      final PublishedResult seen = (await db.result(saved.id))!;
      expect(seen.firstSeenAt, first);
      expect(seen.seenCount, 2);
    });

    test('verifying needs the result seen and no request open, and is final', () async {
      final PublishedResult saved = await db.publish(result());
      await expectLater(db.verify(saved.id), throwsA(isA<ResultsException>()));

      await db.markSeen(saved.id);
      final CorrectionRequest request =
          await db.requestCorrection(resultId: saved.id, questionId: 'Q3', message: 'Please check.');
      await expectLater(
        db.verify(saved.id),
        throwsA(isA<ResultsException>().having((ResultsException e) => e.message, 'message', contains('Wait'))),
      );

      await db.declineRequest(request.id, reply: 'It stands.');
      final PublishedResult verified = await db.verify(saved.id);
      expect(verified.isVerified, isTrue);
      await expectLater(db.verify(saved.id), throwsA(isA<ResultsException>()));
      // No more requests once verified.
      await expectLater(
        db.requestCorrection(resultId: saved.id, questionId: 'Q4', message: 'One more.'),
        throwsA(isA<ResultsException>()),
      );
    });

    test('publishing changed marks again must be seen and verified afresh; the same marks keep them', () async {
      final PublishedResult saved = await db.publish(result());
      await db.markSeen(saved.id);
      await db.verify(saved.id);

      final PublishedResult same = await db.publish(result());
      expect(same.isVerified, isTrue);
      expect(same.isSeen, isTrue);

      final PublishedResult changed = await db.publish(result(q3: 4));
      expect(changed.isVerified, isFalse);
      expect(changed.isSeen, isFalse);
      expect(changed.seenCount, 0);
    });

    test('the overview says where each student stands, by subject and exam', () async {
      final PublishedResult a = await db.publish(result(roll: '21CS001'));
      final PublishedResult b = await db.publish(result(roll: '21CS002'));
      final PublishedResult c = await db.publish(result(roll: '21CS003'));
      await db.publish(result(roll: '21CS004'));
      await db.publish(result(roll: '21CS001', subject: 'CS3401', exam: 'Model'));

      await db.markSeen(a.id);
      await db.markSeen(b.id);
      await db.verify(b.id);
      await db.markSeen(c.id);
      await db.requestCorrection(resultId: c.id, questionId: 'Q3', message: 'Check.');

      final List<StudentStatus> rows = await db.overview(subjectCode: 'ccs356', exam: 'CAT 1');
      expect(rows.map((StudentStatus r) => r.rollNo), <String>['21CS001', '21CS002', '21CS003', '21CS004']);
      expect(rows.map((StudentStatus r) => r.stage), <StudentStage>[
        StudentStage.seen,
        StudentStage.verified,
        StudentStage.requested,
        StudentStage.notSeen,
      ]);
      expect(rows[2].openRequests, 1);
      expect(await db.overview(), hasLength(5));
      expect(await db.subjects(), <String>['CCS356', 'CS3401']);
      expect(await db.exams(subjectCode: 'CCS356'), <String>['CAT 1']);
    });
  });
}

