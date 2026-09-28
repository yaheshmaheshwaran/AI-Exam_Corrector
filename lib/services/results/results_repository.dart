import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/models/correction_request.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/models/student_status.dart';

/// The results students see and the corrections they ask for.
///
/// The screens and the controller use only this, so the database on this
/// computer can later give way to a shared server without changing them.
abstract class ResultsRepository {
  /// Saves [result] under its roll number, subject and exam, replacing an
  /// earlier copy — whose correction requests stay attached.
  Future<PublishedResult> publish(PublishedResult result);

  Future<PublishedResult?> result(String id);

  /// A student's results: for one subject, or every subject.
  Future<List<PublishedResult>> resultsFor({required String rollNo, String? subjectCode});

  Future<List<PublishedResult>> all();

  Future<void> unpublish(String id);

  /// Asks the teacher to look again at one question's mark. One open request
  /// per question at a time.
  Future<CorrectionRequest> requestCorrection({
    required String resultId,
    required String questionId,
    required String message,
  });

  Future<List<CorrectionRequest>> requests({
    String? rollNo,
    String? subjectCode,
    String? resultId,
    bool openOnly = false,
  });

  Future<int> openRequestCount();

  /// Accepts a request: the question's mark becomes [marks], every total is
  /// worked out again, and the student sees [reply].
  Future<PublishedResult> acceptRequest(int id, {required double marks, required String reply});

  Future<void> declineRequest(int id, {required String reply});

  /// The student opened [resultId]: the first time is kept, and each view
  /// counted.
  Future<void> markSeen(String resultId);

  /// The student confirms they agree with the marks. Refused before they
  /// have seen it, while a request is open, or when already verified.
  Future<PublishedResult> verify(String resultId);

  /// Every published result with what its student has done: seen, verified,
  /// requests — for the teacher's table.
  Future<List<StudentStatus>> overview({String? subjectCode, String? exam});

  /// The subjects results were published under.
  Future<List<String>> subjects();

  /// The exams published for [subjectCode], or for every subject.
  Future<List<String>> exams({String? subjectCode});

  /// The subject and exam a paper was last published under, to prefill.
  Future<({String subjectCode, String exam})?> paperDefaults(String paperHash);

  Future<void> savePaperDefaults(String paperHash, {required String subjectCode, required String exam});

  void close();
}

/// Knows which roll numbers belong to students who have signed up — the
/// college server does; a database on this computer does not.
abstract interface class StudentDirectory {
  Future<Set<String>> registeredRolls();
}

/// Whether republishing [b] over [a] leaves every mark as it was — when it
/// does, what the student has seen and agreed to still stands.
bool sameMarks(PublishedResult a, PublishedResult b) {
  if ((a.total - b.total).abs() > 1e-9) return false;
  final Map<String, double> marks = <String, double>{
    for (final PublishedQuestion q in a.questions) q.questionId: q.marks,
  };
  return b.questions.length == a.questions.length &&
      b.questions.every((PublishedQuestion q) =>
          marks.containsKey(q.questionId) && (marks[q.questionId]! - q.marks).abs() < 1e-9);
}

/// The results database: SQLite, in one file on this computer.
class SqliteResultsRepository implements ResultsRepository {
  SqliteResultsRepository._(this._db, this._answerSheets) {
    _migrate();
  }

  /// Opens (and creates, or brings up to date) the database at [file];
  /// answer sheets are kept in a folder beside it.
  factory SqliteResultsRepository.open(File file, {Directory? answerSheets}) {
    file.parent.createSync(recursive: true);
    return SqliteResultsRepository._(
      sqlite3.open(file.path),
      answerSheets ?? Directory('${file.parent.path}${Platform.pathSeparator}answer-sheets'),
    );
  }

  /// For tests: nothing on disk unless [answerSheets] is given.
  factory SqliteResultsRepository.inMemory({Directory? answerSheets}) =>
      SqliteResultsRepository._(sqlite3.openInMemory(), answerSheets);

  final Database _db;

  /// Where published answer sheets are copied, out of reach of the cache;
  /// null keeps the pages where they are.
  final Directory? _answerSheets;

  static const int schemaVersion = 4;

  void _migrate() {
    _db.execute('PRAGMA foreign_keys = ON');
    if (_db.userVersion < 1) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS results (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          roll_no TEXT NOT NULL,
          student_name TEXT NOT NULL DEFAULT '',
          subject_code TEXT NOT NULL,
          exam TEXT NOT NULL DEFAULT '',
          paper_title TEXT NOT NULL DEFAULT '',
          file_name TEXT NOT NULL DEFAULT '',
          paper_hash TEXT NOT NULL DEFAULT '',
          script_hash TEXT NOT NULL DEFAULT '',
          total REAL NOT NULL,
          maximum REAL NOT NULL,
          percentage REAL NOT NULL,
          total_rounding TEXT NOT NULL DEFAULT 'none',
          standard TEXT NOT NULL DEFAULT '',
          published_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE (roll_no, subject_code, exam)
        );
        CREATE TABLE IF NOT EXISTS result_sections (
          result_id INTEGER NOT NULL REFERENCES results(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          section_id TEXT,
          title TEXT NOT NULL,
          maximum REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS result_questions (
          result_id INTEGER NOT NULL REFERENCES results(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          question_id TEXT NOT NULL,
          number TEXT NOT NULL,
          section_id TEXT,
          marks REAL NOT NULL,
          maximum REAL NOT NULL,
          ai_marks REAL,
          explanation TEXT NOT NULL DEFAULT '',
          comment TEXT NOT NULL DEFAULT '',
          counted INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS correction_requests (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          result_id INTEGER NOT NULL REFERENCES results(id) ON DELETE CASCADE,
          question_id TEXT NOT NULL,
          roll_no TEXT NOT NULL,
          subject_code TEXT NOT NULL,
          message TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'open',
          reply TEXT NOT NULL DEFAULT '',
          old_marks REAL,
          new_marks REAL,
          created_at TEXT NOT NULL,
          resolved_at TEXT
        );
        CREATE TABLE IF NOT EXISTS paper_defaults (
          paper_hash TEXT PRIMARY KEY,
          subject_code TEXT NOT NULL,
          exam TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS results_by_student ON results(roll_no, subject_code);
        CREATE INDEX IF NOT EXISTS requests_by_status ON correction_requests(status);
      ''');
      _db.userVersion = 1;
    }
    if (_db.userVersion < 2) {
      // The answer sheet goes with the result: what each question asked, the
      // answer as read, where it is written, and the pages themselves.
      _db.execute('''
        ALTER TABLE result_questions ADD COLUMN question_text TEXT NOT NULL DEFAULT '';
        ALTER TABLE result_questions ADD COLUMN answer_text TEXT NOT NULL DEFAULT '';
        ALTER TABLE result_questions ADD COLUMN answer_boxes TEXT NOT NULL DEFAULT '[]';
        CREATE TABLE IF NOT EXISTS result_pages (
          result_id INTEGER NOT NULL REFERENCES results(id) ON DELETE CASCADE,
          page_number INTEGER NOT NULL,
          image_path TEXT NOT NULL,
          width INTEGER NOT NULL,
          height INTEGER NOT NULL
        );
      ''');
      _db.userVersion = 2;
    }
    if (_db.userVersion < 3) {
      // What the student has done with each result.
      _db.execute('''
        ALTER TABLE results ADD COLUMN first_seen_at TEXT;
        ALTER TABLE results ADD COLUMN last_seen_at TEXT;
        ALTER TABLE results ADD COLUMN seen_count INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE results ADD COLUMN verified_at TEXT;
      ''');
      _db.userVersion = 3;
    }
    if (_db.userVersion < 4) {
      // The syllabus badge each answer earned, and its bonus mark.
      _db.execute('''
        ALTER TABLE result_questions ADD COLUMN badge TEXT NOT NULL DEFAULT 'none';
        ALTER TABLE result_questions ADD COLUMN bonus REAL NOT NULL DEFAULT 0;
      ''');
      _db.userVersion = 4;
    }
  }

  Directory? _sheetFolder(int id) =>
      _answerSheets == null ? null : Directory('${_answerSheets.path}${Platform.pathSeparator}$id');

  /// Copies [pages] out of the cache into this result's folder, replacing
  /// what was there. A page whose image is gone is left out.
  Future<List<PublishedPage>> _keepPages(int id, List<PublishedPage> pages) async {
    final Directory? folder = _sheetFolder(id);
    if (folder == null) return pages;
    if (await folder.exists()) await folder.delete(recursive: true);
    if (pages.isEmpty) return pages;
    await folder.create(recursive: true);
    final List<PublishedPage> kept = <PublishedPage>[];
    for (final PublishedPage page in pages) {
      final File source = File(page.imagePath);
      if (!await source.exists()) continue;
      final String extension = page.imagePath.split('.').last.toLowerCase();
      final File target = File('${folder.path}${Platform.pathSeparator}page_${page.number}.$extension');
      if (source.absolute.path != target.absolute.path) await source.copy(target.path);
      kept.add(PublishedPage(number: page.number, imagePath: target.path, width: page.width, height: page.height));
    }
    return kept;
  }

  String _now() => DateTime.now().toUtc().toIso8601String();

  T _transaction<T>(T Function() body) {
    _db.execute('BEGIN');
    try {
      final T result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // --------------------------------------------------------------------------
  // Results
  // --------------------------------------------------------------------------

  @override
  Future<PublishedResult> publish(PublishedResult result) async {
    if (result.rollNo.isEmpty) {
      throw const ResultsException('A roll number is needed to publish a result.');
    }
    if (result.subjectCode.isEmpty) {
      throw const ResultsException('A subject code is needed to publish a result.');
    }
    // Marks that changed must be seen, and agreed to, afresh.
    final ResultSet earlier = _db.select(
      'SELECT id FROM results WHERE roll_no = ? AND subject_code = ? AND exam = ?',
      <Object?>[result.rollNo, result.subjectCode, result.exam],
    );
    final PublishedResult? before = earlier.isEmpty ? null : await this.result('${earlier.first['id']}');
    final bool unchanged = before != null && sameMarks(before, result);

    final int id = _transaction(() {
      final ResultSet existing = _db.select(
        'SELECT id FROM results WHERE roll_no = ? AND subject_code = ? AND exam = ?',
        <Object?>[result.rollNo, result.subjectCode, result.exam],
      );
      final List<Object?> values = <Object?>[
        result.student,
        result.paperTitle,
        result.fileName,
        result.paperHash,
        result.scriptHash,
        result.total,
        result.maximum,
        result.percentage,
        result.totalRounding.name,
        result.standard,
        _now(),
      ];
      int id;
      if (existing.isEmpty) {
        _db.execute(
          'INSERT INTO results (roll_no, subject_code, exam, student_name, paper_title, file_name, '
          'paper_hash, script_hash, total, maximum, percentage, total_rounding, standard, '
          'updated_at, published_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[result.rollNo, result.subjectCode, result.exam, ...values, result.publishedAt.toUtc().toIso8601String()],
        );
        id = _db.lastInsertRowId;
      } else {
        id = existing.first['id'] as int;
        _db.execute(
          'UPDATE results SET student_name = ?, paper_title = ?, file_name = ?, paper_hash = ?, '
          'script_hash = ?, total = ?, maximum = ?, percentage = ?, total_rounding = ?, standard = ?, '
          'updated_at = ?, published_at = ? WHERE id = ?',
          <Object?>[...values, result.publishedAt.toUtc().toIso8601String(), id],
        );
        _db.execute('DELETE FROM result_sections WHERE result_id = ?', <Object?>[id]);
        _db.execute('DELETE FROM result_questions WHERE result_id = ?', <Object?>[id]);
        if (!unchanged) {
          _db.execute(
            'UPDATE results SET first_seen_at = NULL, last_seen_at = NULL, seen_count = 0, '
            'verified_at = NULL WHERE id = ?',
            <Object?>[id],
          );
        }
      }
      for (int i = 0; i < result.sections.length; i++) {
        final PublishedSection s = result.sections[i];
        _db.execute(
          'INSERT INTO result_sections (result_id, position, section_id, title, maximum) VALUES (?, ?, ?, ?, ?)',
          <Object?>[id, i, s.sectionId, s.title, s.maximum],
        );
      }
      for (int i = 0; i < result.questions.length; i++) {
        final PublishedQuestion q = result.questions[i];
        _db.execute(
          'INSERT INTO result_questions (result_id, position, question_id, number, section_id, marks, '
          'maximum, ai_marks, explanation, comment, counted, question_text, answer_text, answer_boxes, '
          'badge, bonus) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            id, i, q.questionId, q.number, q.section, q.marks, q.maximum, q.aiMarks, q.explanation,
            q.comment, q.counted ? 1 : 0, q.questionText, q.answerText,
            jsonEncode(<JsonMap>[for (final AnswerBox b in q.answerBoxes) b.toJson()]),
            q.badge.name, q.bonus,
          ],
        );
      }
      return id;
    });

    // The answer sheet, copied where clearing the cache cannot reach it.
    final List<PublishedPage> pages = await _keepPages(id, result.pages);
    _transaction(() {
      _db.execute('DELETE FROM result_pages WHERE result_id = ?', <Object?>[id]);
      for (final PublishedPage page in pages) {
        _db.execute(
          'INSERT INTO result_pages (result_id, page_number, image_path, width, height) VALUES (?, ?, ?, ?, ?)',
          <Object?>[id, page.number, page.imagePath, page.width, page.height],
        );
      }
    });
    return (await this.result('$id'))!;
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;

  PublishedResult _load(Row row) {
    final int id = row['id'] as int;
    final List<PublishedQuestion> questions = <PublishedQuestion>[
      for (final Row q in _db.select(
        'SELECT * FROM result_questions WHERE result_id = ? ORDER BY position',
        <Object?>[id],
      ))
        PublishedQuestion(
          questionId: q['question_id'] as String,
          number: q['number'] as String,
          section: q['section_id'] as String?,
          marks: (q['marks'] as num).toDouble(),
          maximum: (q['maximum'] as num).toDouble(),
          aiMarks: (q['ai_marks'] as num?)?.toDouble(),
          explanation: q['explanation'] as String,
          comment: q['comment'] as String,
          counted: (q['counted'] as int) == 1,
          questionText: q['question_text'] as String,
          answerText: q['answer_text'] as String,
          answerBoxes: <AnswerBox>[
            for (final Object? box in (jsonDecode(q['answer_boxes'] as String) as List<Object?>))
              if (readMap(box) case final JsonMap json)
                if (AnswerBox.fromJson(json) case final AnswerBox parsed) parsed,
          ],
          badge: readEnum(SyllabusBadge.values, q['badge'], SyllabusBadge.none),
          bonus: (q['bonus'] as num).toDouble(),
        ),
    ];
    return PublishedResult(
      id: '$id',
      rollNo: row['roll_no'] as String,
      subjectCode: row['subject_code'] as String,
      exam: row['exam'] as String,
      student: row['student_name'] as String,
      paperTitle: row['paper_title'] as String,
      fileName: row['file_name'] as String,
      paperHash: row['paper_hash'] as String,
      scriptHash: row['script_hash'] as String,
      total: (row['total'] as num).toDouble(),
      maximum: (row['maximum'] as num).toDouble(),
      percentage: (row['percentage'] as num).toDouble(),
      totalRounding: readEnum(TotalRounding.values, row['total_rounding'], TotalRounding.none),
      standard: row['standard'] as String,
      publishedAt: DateTime.parse(row['published_at'] as String).toLocal(),
      firstSeenAt: _date(row['first_seen_at']),
      lastSeenAt: _date(row['last_seen_at']),
      seenCount: (row['seen_count'] as int?) ?? 0,
      verifiedAt: _date(row['verified_at']),
      sections: <PublishedSection>[
        for (final Row s in _db.select(
          'SELECT * FROM result_sections WHERE result_id = ? ORDER BY position',
          <Object?>[id],
        ))
          PublishedSection(
            sectionId: s['section_id'] as String?,
            title: s['title'] as String,
            maximum: (s['maximum'] as num).toDouble(),
            marks: questions
                .where((PublishedQuestion q) => q.counted && q.section == s['section_id'])
                .fold<double>(0, (double sum, PublishedQuestion q) => sum + q.marks),
          ),
      ],
      questions: questions,
      pages: <PublishedPage>[
        for (final Row p in _db.select(
          'SELECT * FROM result_pages WHERE result_id = ? ORDER BY page_number',
          <Object?>[id],
        ))
          PublishedPage(
            number: p['page_number'] as int,
            imagePath: p['image_path'] as String,
            width: p['width'] as int,
            height: p['height'] as int,
          ),
      ],
    );
  }

  @override
  Future<PublishedResult?> result(String id) async {
    final ResultSet rows = _db.select('SELECT * FROM results WHERE id = ?', <Object?>[int.tryParse(id) ?? -1]);
    return rows.isEmpty ? null : _load(rows.first);
  }

  @override
  Future<List<PublishedResult>> resultsFor({required String rollNo, String? subjectCode}) async {
    final String roll = PublishedResult.normaliseRoll(rollNo);
    final String? subject =
        subjectCode == null || subjectCode.trim().isEmpty ? null : PublishedResult.normaliseRoll(subjectCode);
    if (roll.isEmpty) return const <PublishedResult>[];
    return <PublishedResult>[
      for (final Row row in _db.select(
        subject == null
            ? 'SELECT * FROM results WHERE roll_no = ? ORDER BY published_at DESC'
            : 'SELECT * FROM results WHERE roll_no = ? AND subject_code = ? ORDER BY published_at DESC',
        <Object?>[roll, ?subject],
      ))
        _load(row),
    ];
  }

  @override
  Future<List<PublishedResult>> all() async => <PublishedResult>[
        for (final Row row in _db.select('SELECT * FROM results ORDER BY published_at DESC')) _load(row),
      ];

  @override
  Future<void> unpublish(String id) async {
    final int key = int.tryParse(id) ?? -1;
    _db.execute('DELETE FROM results WHERE id = ?', <Object?>[key]);
    final Directory? folder = _sheetFolder(key);
    if (folder != null && await folder.exists()) await folder.delete(recursive: true);
  }

  // --------------------------------------------------------------------------
  // Correction requests
  // --------------------------------------------------------------------------

  @override
  Future<CorrectionRequest> requestCorrection({
    required String resultId,
    required String questionId,
    required String message,
  }) async {
    if (message.trim().isEmpty) {
      throw const ResultsException('Say why the mark should be looked at again.');
    }
    final PublishedResult? published = await result(resultId);
    if (published == null) throw const ResultsException('That result is no longer published.');
    if (published.isVerified) {
      throw const ResultsException('You verified these marks, so corrections can no longer be asked for.');
    }
    if (!published.questions.any((PublishedQuestion q) => q.questionId == questionId)) {
      throw const ResultsException('That question is not in this result.');
    }
    final ResultSet open = _db.select(
      "SELECT id FROM correction_requests WHERE result_id = ? AND question_id = ? AND status = 'open'",
      <Object?>[int.parse(resultId), questionId],
    );
    if (open.isNotEmpty) {
      throw const ResultsException('You have already asked about this question; wait for your teacher’s answer.');
    }
    _db.execute(
      'INSERT INTO correction_requests (result_id, question_id, roll_no, subject_code, message, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      <Object?>[int.parse(resultId), questionId, published.rollNo, published.subjectCode, message.trim(), _now()],
    );
    return (await requests(resultId: resultId)).firstWhere((CorrectionRequest r) => r.id == _db.lastInsertRowId);
  }

  @override
  Future<List<CorrectionRequest>> requests({
    String? rollNo,
    String? subjectCode,
    String? resultId,
    bool openOnly = false,
  }) async {
    final List<String> where = <String>[];
    final List<Object?> values = <Object?>[];
    if (rollNo != null) {
      where.add('c.roll_no = ?');
      values.add(PublishedResult.normaliseRoll(rollNo));
    }
    if (subjectCode != null && subjectCode.trim().isNotEmpty) {
      where.add('c.subject_code = ?');
      values.add(PublishedResult.normaliseRoll(subjectCode));
    }
    if (resultId != null) {
      where.add('c.result_id = ?');
      values.add(int.tryParse(resultId) ?? -1);
    }
    if (openOnly) where.add("c.status = 'open'");
    final ResultSet rows = _db.select(
      'SELECT c.*, r.exam, r.student_name, q.number, q.marks, q.maximum, q.explanation '
      'FROM correction_requests c '
      'JOIN results r ON r.id = c.result_id '
      'LEFT JOIN result_questions q ON q.result_id = c.result_id AND q.question_id = c.question_id '
      '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')} '}'
      "ORDER BY CASE c.status WHEN 'open' THEN 0 ELSE 1 END, c.created_at DESC",
      values,
    );
    return <CorrectionRequest>[
      for (final Row row in rows)
        CorrectionRequest(
          id: row['id'] as int,
          resultId: '${row['result_id']}',
          questionId: row['question_id'] as String,
          questionNumber: (row['number'] as String?) ?? (row['question_id'] as String),
          rollNo: row['roll_no'] as String,
          studentName: (row['student_name'] as String?) ?? '',
          subjectCode: row['subject_code'] as String,
          exam: (row['exam'] as String?) ?? '',
          message: row['message'] as String,
          status: readEnum(RequestStatus.values, row['status'], RequestStatus.open),
          reply: row['reply'] as String,
          oldMarks: (row['old_marks'] as num?)?.toDouble(),
          newMarks: (row['new_marks'] as num?)?.toDouble(),
          currentMarks: (row['marks'] as num?)?.toDouble() ?? 0,
          maximum: (row['maximum'] as num?)?.toDouble() ?? 0,
          explanation: (row['explanation'] as String?) ?? '',
          createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
          resolvedAt: row['resolved_at'] == null ? null : DateTime.parse(row['resolved_at'] as String).toLocal(),
        ),
    ];
  }

  @override
  Future<int> openRequestCount() async =>
      _db.select("SELECT COUNT(*) AS n FROM correction_requests WHERE status = 'open'").first['n'] as int;

  Future<CorrectionRequest> _openRequest(int id) async {
    final CorrectionRequest? request =
        (await requests()).where((CorrectionRequest r) => r.id == id).firstOrNull;
    if (request == null) throw const ResultsException('That request no longer exists.');
    if (!request.isOpen) throw const ResultsException('That request has already been answered.');
    return request;
  }

  @override
  Future<PublishedResult> acceptRequest(int id, {required double marks, required String reply}) async {
    final CorrectionRequest request = await _openRequest(id);
    if (marks < 0 || marks > request.maximum) {
      throw ResultsException('The mark must be between 0 and ${request.maximum}.');
    }
    final PublishedResult current = (await result(request.resultId))!;
    final PublishedResult changed = current.withMark(request.questionId, marks);
    _transaction(() {
      _db.execute(
        'UPDATE result_questions SET marks = ? WHERE result_id = ? AND question_id = ?',
        <Object?>[marks, int.parse(request.resultId), request.questionId],
      );
      _db.execute(
        'UPDATE results SET total = ?, percentage = ?, updated_at = ?, verified_at = NULL WHERE id = ?',
        <Object?>[changed.total, changed.percentage, _now(), int.parse(request.resultId)],
      );
      _db.execute(
        "UPDATE correction_requests SET status = 'accepted', reply = ?, old_marks = ?, new_marks = ?, "
        'resolved_at = ? WHERE id = ?',
        <Object?>[reply.trim(), request.currentMarks, marks, _now(), id],
      );
    });
    return (await result(request.resultId))!;
  }

  @override
  Future<void> declineRequest(int id, {required String reply}) async {
    if (reply.trim().isEmpty) {
      throw const ResultsException('Tell the student why the mark stays as it is.');
    }
    final CorrectionRequest request = await _openRequest(id);
    _db.execute(
      "UPDATE correction_requests SET status = 'declined', reply = ?, old_marks = ?, resolved_at = ? WHERE id = ?",
      <Object?>[reply.trim(), request.currentMarks, _now(), id],
    );
  }

  // --------------------------------------------------------------------------
  // Seen and verified
  // --------------------------------------------------------------------------

  @override
  Future<void> markSeen(String resultId) async {
    final String now = _now();
    _db.execute(
      'UPDATE results SET first_seen_at = COALESCE(first_seen_at, ?), last_seen_at = ?, '
      'seen_count = seen_count + 1 WHERE id = ?',
      <Object?>[now, now, int.tryParse(resultId) ?? -1],
    );
  }

  @override
  Future<PublishedResult> verify(String resultId) async {
    final PublishedResult? published = await result(resultId);
    if (published == null) throw const ResultsException('That result is no longer published.');
    if (published.isVerified) throw const ResultsException('These marks are already verified.');
    if (!published.isSeen) throw const ResultsException('Open and look at the result before verifying it.');
    final int open = _db.select(
      "SELECT COUNT(*) AS n FROM correction_requests WHERE result_id = ? AND status = 'open'",
      <Object?>[int.parse(resultId)],
    ).first['n'] as int;
    if (open > 0) {
      throw const ResultsException('Wait for your teacher’s reply to your request before verifying.');
    }
    _db.execute('UPDATE results SET verified_at = ? WHERE id = ?', <Object?>[_now(), int.parse(resultId)]);
    return (await result(resultId))!;
  }

  @override
  Future<List<StudentStatus>> overview({String? subjectCode, String? exam}) async {
    final List<String> where = <String>[];
    final List<Object?> values = <Object?>[];
    if (subjectCode != null && subjectCode.trim().isNotEmpty) {
      where.add('r.subject_code = ?');
      values.add(PublishedResult.normaliseRoll(subjectCode));
    }
    if (exam != null) {
      where.add('r.exam = ?');
      values.add(exam);
    }
    final ResultSet rows = _db.select(
      'SELECT r.*, '
      "(SELECT COUNT(*) FROM correction_requests c WHERE c.result_id = r.id AND c.status = 'open') AS open_requests, "
      "(SELECT COUNT(*) FROM correction_requests c WHERE c.result_id = r.id AND c.status = 'accepted') AS accepted_requests, "
      "(SELECT COUNT(*) FROM correction_requests c WHERE c.result_id = r.id AND c.status = 'declined') AS declined_requests, "
      "(SELECT COUNT(*) FROM result_questions q WHERE q.result_id = r.id AND q.counted = 1 AND q.badge != 'none') AS badges "
      'FROM results r ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')} '}'
      'ORDER BY r.subject_code, r.exam, r.roll_no',
      values,
    );
    return <StudentStatus>[
      for (final Row row in rows)
        StudentStatus(
          resultId: '${row['id']}',
          rollNo: row['roll_no'] as String,
          studentName: row['student_name'] as String,
          subjectCode: row['subject_code'] as String,
          exam: row['exam'] as String,
          total: (row['total'] as num).toDouble(),
          maximum: (row['maximum'] as num).toDouble(),
          percentage: (row['percentage'] as num).toDouble(),
          publishedAt: DateTime.parse(row['published_at'] as String).toLocal(),
          firstSeenAt: _date(row['first_seen_at']),
          lastSeenAt: _date(row['last_seen_at']),
          seenCount: (row['seen_count'] as int?) ?? 0,
          verifiedAt: _date(row['verified_at']),
          openRequests: row['open_requests'] as int,
          acceptedRequests: row['accepted_requests'] as int,
          declinedRequests: row['declined_requests'] as int,
          badges: row['badges'] as int,
        ),
    ];
  }

  @override
  Future<List<String>> subjects() async => <String>[
        for (final Row row in _db.select('SELECT DISTINCT subject_code FROM results ORDER BY subject_code'))
          row['subject_code'] as String,
      ];

  @override
  Future<List<String>> exams({String? subjectCode}) async {
    final bool one = subjectCode != null && subjectCode.trim().isNotEmpty;
    return <String>[
      for (final Row row in _db.select(
        one
            ? 'SELECT DISTINCT exam FROM results WHERE subject_code = ? ORDER BY exam'
            : 'SELECT DISTINCT exam FROM results ORDER BY exam',
        <Object?>[if (one) PublishedResult.normaliseRoll(subjectCode)],
      ))
        row['exam'] as String,
    ];
  }

  // --------------------------------------------------------------------------
  // What a paper was last published under
  // --------------------------------------------------------------------------

  @override
  Future<({String subjectCode, String exam})?> paperDefaults(String paperHash) async {
    final ResultSet rows =
        _db.select('SELECT subject_code, exam FROM paper_defaults WHERE paper_hash = ?', <Object?>[paperHash]);
    if (rows.isEmpty) return null;
    return (subjectCode: rows.first['subject_code'] as String, exam: rows.first['exam'] as String);
  }

  @override
  Future<void> savePaperDefaults(String paperHash, {required String subjectCode, required String exam}) async {
    _db.execute(
      'INSERT INTO paper_defaults (paper_hash, subject_code, exam) VALUES (?, ?, ?) '
      'ON CONFLICT(paper_hash) DO UPDATE SET subject_code = excluded.subject_code, exam = excluded.exam',
      <Object?>[paperHash, PublishedResult.normaliseRoll(subjectCode), exam.trim()],
    );
  }

  /// Brings results published as files, before there was a database, into
  /// it — the name they were published under becoming the roll number — and
  /// sets the folder aside. Returns how many came in.
  Future<int> importFolder(Directory folder) async {
    if (!await folder.exists()) return 0;
    int imported = 0;
    await for (final FileSystemEntity entity in folder.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final JsonMap? json = readMap(jsonDecode(await entity.readAsString()));
        final PublishedResult? old = json == null ? null : PublishedResult.fromJson(json);
        if (old == null) continue;
        final String roll = PublishedResult.normaliseRoll(
          old.rollNo.isNotEmpty ? old.rollNo : (PublishedResult.rollFromFileName(old.fileName) ?? old.student),
        );
        if (roll.isEmpty) continue;
        await publish(PublishedResult(
          id: '',
          rollNo: roll,
          subjectCode: old.subjectCode.isNotEmpty ? old.subjectCode : 'UNSET',
          exam: old.exam.isNotEmpty ? old.exam : old.paperTitle,
          student: old.student,
          paperTitle: old.paperTitle,
          fileName: old.fileName,
          publishedAt: old.publishedAt,
          total: old.total,
          maximum: old.maximum,
          percentage: old.percentage,
          standard: old.standard,
          sections: old.sections,
          questions: old.questions,
        ));
        imported++;
      } on FormatException {
        continue;
      } on ResultsException {
        continue;
      }
    }
    await folder.rename('${folder.path}-imported');
    return imported;
  }

  @override
  void close() => _db.close();
}
