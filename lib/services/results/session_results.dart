import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/correction_request.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/models/student_status.dart';
import 'package:exam_corrector/services/results/results_repository.dart';

/// The results of whoever is signed in: the college's, on its server, once
/// someone signs in to it — or this computer's own, for a teacher working
/// without an account.
///
/// The controller and screens hold this one object for the life of the app;
/// signing in and out only changes what it passes the calls on to.
class SessionResults implements ResultsRepository {
  SessionResults({ResultsRepository? active}) : _active = active;

  ResultsRepository? _active;

  /// Where results go now; null while no one may publish or read them.
  ResultsRepository? get active => _active;

  void use(ResultsRepository? active) => _active = active;

  /// The roll numbers of students who have signed up, where results go to
  /// the college server; null when that cannot be known.
  Future<Set<String>?> registeredRolls() async {
    final ResultsRepository? active = _active;
    if (active is! StudentDirectory) return null;
    try {
      return await (active as StudentDirectory).registeredRolls();
    } on AppException {
      return null;
    }
  }

  ResultsRepository get _to =>
      _active ?? (throw const ResultsException('Sign in to your college to publish and see results.'));

  @override
  Future<PublishedResult> publish(PublishedResult result) async => _to.publish(result);

  @override
  Future<PublishedResult?> result(String id) async => _to.result(id);

  @override
  Future<List<PublishedResult>> resultsFor({required String rollNo, String? subjectCode}) async =>
      _to.resultsFor(rollNo: rollNo, subjectCode: subjectCode);

  @override
  Future<List<PublishedResult>> all() async => _to.all();

  @override
  Future<void> unpublish(String id) async => _to.unpublish(id);

  @override
  Future<CorrectionRequest> requestCorrection({
    required String resultId,
    required String questionId,
    required String message,
  }) async => _to.requestCorrection(resultId: resultId, questionId: questionId, message: message);

  @override
  Future<List<CorrectionRequest>> requests({
    String? rollNo,
    String? subjectCode,
    String? resultId,
    bool openOnly = false,
  }) async {
    // Nothing to show is not a failure: the badge and lists stay empty.
    final ResultsRepository? active = _active;
    if (active == null) return const <CorrectionRequest>[];
    return active.requests(rollNo: rollNo, subjectCode: subjectCode, resultId: resultId, openOnly: openOnly);
  }

  @override
  Future<int> openRequestCount() async {
    final ResultsRepository? active = _active;
    if (active == null) return 0;
    // Only a badge: a server out of reach shows none rather than failing.
    try {
      return await active.openRequestCount();
    } on AppException {
      return 0;
    }
  }

  @override
  Future<PublishedResult> acceptRequest(int id, {required double marks, required String reply}) async =>
      _to.acceptRequest(id, marks: marks, reply: reply);

  @override
  Future<void> declineRequest(int id, {required String reply}) async => _to.declineRequest(id, reply: reply);

  @override
  Future<void> markSeen(String resultId) async => _to.markSeen(resultId);

  @override
  Future<PublishedResult> verify(String resultId) async => _to.verify(resultId);

  @override
  Future<List<StudentStatus>> overview({String? subjectCode, String? exam}) async =>
      await _active?.overview(subjectCode: subjectCode, exam: exam) ?? const <StudentStatus>[];

  @override
  Future<List<String>> subjects() async => await _active?.subjects() ?? const <String>[];

  @override
  Future<List<String>> exams({String? subjectCode}) async =>
      await _active?.exams(subjectCode: subjectCode) ?? const <String>[];

  @override
  Future<({String subjectCode, String exam})?> paperDefaults(String paperHash) async =>
      _active?.paperDefaults(paperHash);

  @override
  Future<void> savePaperDefaults(String paperHash, {required String subjectCode, required String exam}) async =>
      _active?.savePaperDefaults(paperHash, subjectCode: subjectCode, exam: exam);

  @override
  void close() => _active?.close();
}
