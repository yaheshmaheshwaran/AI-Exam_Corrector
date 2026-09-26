import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/models/question_result.dart';

/// A validated correction, ready to display.
///
/// This is the contract between the marking engine, the validation layer and
/// the UI. Nothing in here knows about a model provider, PDFs or Flutter.
/// Instances only ever come from validation, so the totals are locally
/// computed and awarded marks are guaranteed not to exceed the maxima.
///
/// It is the AI's result and stays that way: a teacher's override is recorded
/// beside it as a TeacherReview, never written into it.
class CorrectionResult {
  const CorrectionResult({
    required this.questions,
    required this.totalMarks,
    required this.maximumTotalMarks,
    required this.percentage,
    this.model = '',
    this.warnings = const <String>[],
  });

  /// Builds a result from per-question marks, computing the totals locally.
  /// A question left out of a choice (see [QuestionResult.counted]) is in
  /// neither total.
  factory CorrectionResult.fromQuestions(
    List<QuestionResult> questions, {
    String model = '',
    List<String> warnings = const <String>[],
  }) {
    final Iterable<QuestionResult> counted =
        questions.where((QuestionResult q) => q.counted);
    final double total = counted.fold<double>(
      0,
      (double sum, QuestionResult q) => sum + q.awardedMarks,
    );
    final double maximum = counted.fold<double>(
      0,
      (double sum, QuestionResult q) => sum + q.maximumMarks,
    );
    return CorrectionResult(
      questions: questions,
      totalMarks: total,
      maximumTotalMarks: maximum,
      percentage: maximum > 0 ? total / maximum * 100 : 0,
      model: model,
      warnings: warnings,
    );
  }

  final List<QuestionResult> questions;
  final double totalMarks;
  final double maximumTotalMarks;
  final double percentage;

  /// The model that produced these marks. Shown with the result, because a
  /// paper marked after a quota fallback was marked by a different model from
  /// the one at the top of the chain.
  final String model;

  /// Adjustments the validation layer had to make, shown to the teacher above
  /// the result so marks are never quietly changed.
  final List<String> warnings;

  bool get hasQuestions => questions.isNotEmpty;

  int get needsReviewCount =>
      questions.where((QuestionResult q) => q.counted && q.needsReview).length;

  QuestionResult? question(String questionId) {
    for (final QuestionResult question in questions) {
      if (question.questionId == questionId) return question;
    }
    return null;
  }

  /// True when no answer was found for any question — almost always the wrong
  /// file in step 1 (a mark scheme or a blank question paper) rather than a
  /// student who wrote nothing at all.
  bool get foundNoAnswers =>
      hasQuestions &&
      totalMarks == 0 &&
      questions.every((QuestionResult question) =>
          question.studentAnswer.toLowerCase().contains('no answer found'));

  JsonMap toJson() => <String, Object?>{
        'model': model,
        'warnings': warnings,
        'questions': <JsonMap>[
          for (final QuestionResult question in questions) question.toJson(),
        ],
      };

  static CorrectionResult fromJson(JsonMap json) => CorrectionResult.fromQuestions(
        readObjects(json['questions'], QuestionResult.fromJson),
        model: readString(json['model']) ?? '',
        warnings: readStringList(json['warnings']),
      );
}
