/// Where a student stands with one published result.
enum StudentStage {
  notSeen('Not seen'),
  seen('Seen · not verified'),
  requested('Request open'),
  verified('Verified');

  const StudentStage(this.label);

  final String label;
}

/// One row of the teacher's table: a published result and what the student
/// has done with it.
class StudentStatus {
  const StudentStatus({
    required this.resultId,
    required this.rollNo,
    required this.subjectCode,
    required this.exam,
    required this.total,
    required this.maximum,
    required this.percentage,
    required this.publishedAt,
    this.studentName = '',
    this.firstSeenAt,
    this.lastSeenAt,
    this.seenCount = 0,
    this.verifiedAt,
    this.openRequests = 0,
    this.acceptedRequests = 0,
    this.declinedRequests = 0,
    this.badges = 0,
  });

  final String resultId;
  final String rollNo;
  final String studentName;
  final String subjectCode;
  final String exam;
  final double total;
  final double maximum;
  final double percentage;
  final DateTime publishedAt;
  final DateTime? firstSeenAt;
  final DateTime? lastSeenAt;

  /// How many times the student opened it.
  final int seenCount;
  final DateTime? verifiedAt;
  final int openRequests;
  final int acceptedRequests;
  final int declinedRequests;

  /// Answers that earned a syllabus badge.
  final int badges;

  int get answeredRequests => acceptedRequests + declinedRequests;

  StudentStage get stage {
    if (verifiedAt != null) return StudentStage.verified;
    if (openRequests > 0) return StudentStage.requested;
    if (firstSeenAt != null) return StudentStage.seen;
    return StudentStage.notSeen;
  }
}
