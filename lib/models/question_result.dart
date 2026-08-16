/// One criterion from the mark scheme and whether the answer satisfied it.
class MarkingPoint {
  const MarkingPoint({
    required this.criterion,
    required this.satisfied,
    required this.marks,
  });

  final String criterion;
  final bool satisfied;
  final double marks;
}

/// The marks and reasoning for a single question.
class QuestionResult {
  const QuestionResult({
    required this.questionNumber,
    required this.maximumMarks,
    required this.awardedMarks,
    required this.studentAnswer,
    required this.evaluation,
    this.markingPoints = const <MarkingPoint>[],
  });

  final String questionNumber;
  final double maximumMarks;
  final double awardedMarks;
  final String studentAnswer;
  final String evaluation;
  final List<MarkingPoint> markingPoints;
}
