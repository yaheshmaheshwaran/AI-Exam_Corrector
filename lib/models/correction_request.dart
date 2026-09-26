/// Where a student's request to correct a mark has got to.
enum RequestStatus {
  open('Waiting for your teacher'),
  accepted('Accepted'),
  declined('Declined');

  const RequestStatus(this.label);

  final String label;
}

/// A student's request to look again at the mark for one question — the
/// re-evaluation request every college has — and the teacher's answer.
class CorrectionRequest {
  const CorrectionRequest({
    required this.id,
    required this.resultId,
    required this.questionId,
    required this.questionNumber,
    required this.rollNo,
    required this.subjectCode,
    required this.exam,
    required this.message,
    required this.status,
    required this.createdAt,
    this.studentName = '',
    this.reply = '',
    this.oldMarks,
    this.newMarks,
    this.currentMarks = 0,
    this.maximum = 0,
    this.explanation = '',
    this.resolvedAt,
  });

  final int id;
  final String resultId;
  final String questionId;

  /// As the paper prints it: `3`, `11(a)`.
  final String questionNumber;
  final String rollNo;
  final String studentName;
  final String subjectCode;
  final String exam;

  /// The student's reason.
  final String message;
  final RequestStatus status;

  /// The teacher's answer.
  final String reply;

  /// The mark before and after an accepted request.
  final double? oldMarks;
  final double? newMarks;

  /// The question's mark now, its maximum and why it was given — for the
  /// teacher deciding.
  final double currentMarks;
  final double maximum;
  final String explanation;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  bool get isOpen => status == RequestStatus.open;
}
