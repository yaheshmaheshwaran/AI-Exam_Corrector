import 'package:exam_corrector/models/question_result.dart';

/// A validated correction, ready to display.
///
/// This is the contract between the AI layer, the validation layer and the UI.
/// Nothing in here knows about Anthropic, PDFs or Flutter. Instances only ever
/// come from the validation service, so the totals are locally computed and
/// awarded marks are guaranteed not to exceed the maxima.
class CorrectionResult {
  const CorrectionResult({
    required this.questions,
    required this.totalMarks,
    required this.maximumTotalMarks,
    required this.percentage,
    this.model = '',
    this.warnings = const <String>[],
  });

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

  /// True when no answer was found for any question — almost always the wrong
  /// file in step 1 (a mark scheme or a blank question paper) rather than a
  /// student who wrote nothing at all.
  bool get foundNoAnswers =>
      hasQuestions &&
      totalMarks == 0 &&
      questions.every((QuestionResult question) =>
          question.studentAnswer.toLowerCase().contains('no answer found'));
}
