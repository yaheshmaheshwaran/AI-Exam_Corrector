import 'dart:async';


import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/models/student_status.dart';
import 'package:exam_corrector/models/correction_request.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/results/session_results.dart';
import 'package:exam_corrector/state/marked_script.dart';
import 'package:exam_corrector/features/workspace.dart';

/// Publishing marked scripts to students, and the students' correction
/// requests.
mixin PublishingFeature on Workspace {
  /// Whether results can be published to students at all.
  bool get canPublish => resultsStore != null;

  int _openRequests = 0;

  /// Students' correction requests still waiting for an answer.
  int get openRequestCount => _openRequests;

  // --------------------------------------------------------------------------
  // Publishing to students
  // --------------------------------------------------------------------------

  /// The name a student would look a script up by: its file name, without
  /// the extension.
  static String studentNameFor(MarkedScript script) =>
      script.document.fileName.replaceAll(RegExp(r'\.[^.]+$'), '');

  /// Why [script] cannot be published yet, or null when it can.
  String? publishBlocker(MarkedScript script) {
    final CorrectionResult? result = script.result;
    if (result == null) return 'It has not been marked yet.';
    final int outstanding = script.reviews.outstanding(result);
    if (outstanding > 0) {
      return '$outstanding question${outstanding == 1 ? ' still needs' : 's still need'} '
          'your review.';
    }
    return null;
  }

  /// What the publish dialog starts from for [script]: a roll number from
  /// its file name, and the subject and exam this paper was last published
  /// under — or the matched syllabus's course code and the paper's title.
  Future<({String rollNo, String subjectCode, String exam})> publishDefaults(MarkedScript script) async {
    final ExamAssessment? marked = script.assessment;
    final String paperHash = marked?.questionPaper.documentId ?? '';
    ({String subjectCode, String exam})? saved;
    try {
      saved = paperHash.isEmpty ? null : await resultsStore?.paperDefaults(paperHash);
    } on Exception {
      saved = null;
    }
    String code = saved?.subjectCode ?? '';
    if (code.isEmpty) {
      final String? usedId = marked?.syllabus?.id ?? chosenSyllabus;
      code = savedSyllabi.where((Syllabus s) => s.id == usedId).firstOrNull?.courseCode ?? '';
    }
    final String title = marked?.questionPaper.title.trim() ?? '';
    return (
      rollNo: PublishedResult.rollFromFileName(script.document.fileName) ?? '',
      subjectCode: code,
      exam: saved?.exam ?? title,
    );
  }

  /// Publishes the script on screen to the results database, under the
  /// student's roll number and the subject and exam.
  Future<bool> publishCurrent({
    required String rollNo,
    String student = '',
    required String subjectCode,
    required String exam,
  }) async {
    final MarkedScript? script = currentScript;
    final ResultsRepository? results = resultsStore;
    if (script == null || results == null || isBusy) return false;
    final String? blocker = publishBlocker(script);
    if (blocker != null) {
      raiseError('This script cannot be published yet: $blocker');
      return false;
    }
    try {
      final PublishedResult saved = await results.publish(PublishedResult.of(
        script.assessment!,
        script.reviews,
        student: student,
        rollNo: rollNo,
        subjectCode: subjectCode,
        exam: exam,
      ));
      await results.savePaperDefaults(saved.paperHash, subjectCode: subjectCode, exam: exam);
      setStatus('Published for ${saved.rollNo} in ${saved.subjectCode}'
          '${saved.exam.isEmpty ? '' : ' (${saved.exam})'} — the student signs in with '
          'that roll number and subject.');
      return true;
    } on AppException catch (error) {
      fail('The result could not be published.', error.message);
    } on Exception catch (error) {
      fail('The result could not be published.', '$error');
    }
    return false;
  }

  /// Publishes every ready script in the class under the same subject and
  /// exam; [rollNos] gives each script's roll number by its index. Scripts
  /// without one, or still with questions to review, are held back and named.
  Future<int> publishClass({
    required String subjectCode,
    required String exam,
    required Map<int, String> rollNos,
  }) async {
    final ResultsRepository? results = resultsStore;
    if (results == null || isBusy) return 0;
    int published = 0;
    final List<String> held = <String>[];
    for (int i = 0; i < scriptList.length; i++) {
      final MarkedScript script = scriptList[i];
      if (script.result == null) continue;
      final String roll = rollNos[i]?.trim() ?? '';
      final String? blocker = roll.isEmpty ? 'it has no roll number.' : publishBlocker(script);
      if (blocker != null) {
        held.add('${script.document.fileName}: $blocker');
        continue;
      }
      try {
        final PublishedResult saved = await results.publish(PublishedResult.of(
          script.assessment!,
          script.reviews,
          student: '',
          rollNo: roll,
          subjectCode: subjectCode,
          exam: exam,
        ));
        await results.savePaperDefaults(saved.paperHash, subjectCode: subjectCode, exam: exam);
        published++;
      } on AppException catch (error) {
        held.add('${script.document.fileName}: ${error.message}');
      }
    }
    if (held.isEmpty) {
      setStatus('Published $published result${published == 1 ? '' : 's'} in '
          '${PublishedResult.normaliseRoll(subjectCode)}.');
    } else {
      fail(
        'Published $published; ${held.length} held back.',
        'These were not published:\n${held.join('\n')}',
      );
    }
    return published;
  }

  // --------------------------------------------------------------------------
  // Students' correction requests
  // --------------------------------------------------------------------------

  /// Reads how many requests are waiting, for the badge.
  Future<void> refreshRequests() async {
    final ResultsRepository? results = resultsStore;
    if (results == null) return;
    final int open = await results.openRequestCount();
    if (open != _openRequests) {
      _openRequests = open;
      notifyListeners();
    }
  }

  /// The roll numbers of students who have signed up to the college, so
  /// publishing can say when a roll has no account yet; null when that
  /// cannot be known.
  Future<Set<String>?> registeredRolls() async {
    final ResultsRepository? results = resultsStore;
    return results is SessionResults ? results.registeredRolls() : null;
  }

  /// Where every student stands with their published results: seen,
  /// verified, requests.
  Future<List<StudentStatus>> studentOverview({String? subjectCode, String? exam}) async =>
      await resultsStore?.overview(subjectCode: subjectCode, exam: exam) ?? const <StudentStatus>[];

  Future<List<String>> publishedSubjects() async => await resultsStore?.subjects() ?? const <String>[];

  Future<List<String>> examsFor(String? subjectCode) async =>
      await resultsStore?.exams(subjectCode: subjectCode) ?? const <String>[];

  /// The students table as CSV, for the college's records.
  static String overviewCsv(List<StudentStatus> rows) {
    String cell(String value) =>
        RegExp(r'[",\n]').hasMatch(value) ? '"${value.replaceAll('"', '""')}"' : value;
    String date(DateTime? d) => d == null ? '' : d.toIso8601String().substring(0, 16).replaceFirst('T', ' ');
    final StringBuffer out = StringBuffer()
      ..writeln(<String>[
        'Roll no', 'Name', 'Subject', 'Exam', 'Marks', 'Maximum', 'Percentage', 'Published',
        'First seen', 'Times seen', 'Verified', 'Open requests', 'Answered requests', 'Status',
        'Syllabus badges',
      ].join(','));
    for (final StudentStatus r in rows) {
      out.writeln(<String>[
        r.rollNo, r.studentName, r.subjectCode, r.exam, formatMarks(r.total), formatMarks(r.maximum),
        formatPercentage(r.percentage), date(r.publishedAt), date(r.firstSeenAt), '${r.seenCount}',
        date(r.verifiedAt), '${r.openRequests}', '${r.answeredRequests}', r.stage.label,
        '${r.badges}',
      ].map(cell).join(','));
    }
    return out.toString();
  }

  /// Saves the table as shown, filters applied.
  Future<String?> exportOverview(List<StudentStatus> rows, {String name = 'student status'}) async {
    if (rows.isEmpty) return null;
    final String? path = await picker.pickSaveLocation(suggestedName: '$name.csv', extension: 'csv');
    if (path == null) return null;
    return writeFile(path, overviewCsv(rows));
  }

  /// A published result, with its answer sheet — for looking at the answer
  /// a request is about.
  Future<PublishedResult?> publishedResult(String id) async => resultsStore?.result(id);

  Future<List<CorrectionRequest>> correctionRequests({
    bool openOnly = false,
    String? subjectCode,
    String? rollNo,
  }) async =>
      await resultsStore?.requests(openOnly: openOnly, subjectCode: subjectCode, rollNo: rollNo) ??
      const <CorrectionRequest>[];

  /// Accepts a request: the student's mark becomes [marks] and every total
  /// changes. If that script is open here, the change is recorded as the
  /// teacher's override too, so this screen and its exports agree.
  Future<bool> acceptRequest(CorrectionRequest request, double marks, String reply) async {
    final ResultsRepository? results = resultsStore;
    if (results == null) return false;
    try {
      final PublishedResult changed = await results.acceptRequest(request.id, marks: marks, reply: reply);
      for (final MarkedScript script in scriptList) {
        final ExamAssessment? marked = script.assessment;
        final QuestionResult? question = marked?.result?.question(request.questionId);
        if (marked == null ||
            question == null ||
            marked.answerSheet.documentId != changed.scriptHash ||
            marked.questionPaper.documentId != changed.paperHash) {
          continue;
        }
        script.reviews = script.reviews.withReview(TeacherReview(
          questionId: request.questionId,
          status: ReviewStatus.overridden,
          aiMarks: question.awardedMarks,
          teacherMarks: marks,
          comment: 'Correction request from ${request.rollNo}: $reply',
          timestamp: DateTime.now(),
        ));
        await persistReviews(script);
      }
      await refreshRequests();
      setStatus('Accepted: question ${request.questionNumber} for ${request.rollNo} is now '
          '${formatMarks(marks)} — total ${formatMarks(changed.total)}.');
      return true;
    } on AppException catch (error) {
      raiseError(error.message);
      return false;
    }
  }

  Future<bool> declineRequest(CorrectionRequest request, String reply) async {
    final ResultsRepository? results = resultsStore;
    if (results == null) return false;
    try {
      await results.declineRequest(request.id, reply: reply);
      await refreshRequests();
      setStatus('Declined: question ${request.questionNumber} for ${request.rollNo}.');
      return true;
    } on AppException catch (error) {
      raiseError(error.message);
      return false;
    }
  }
}
