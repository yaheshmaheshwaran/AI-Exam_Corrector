import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';

/// Validation of the AI's structured response before it is shown as marks.
///
/// Nothing reaches the UI without passing through here. Structural problems
/// throw [ResultValidationException]; recoverable inconsistencies are corrected
/// and reported as warnings so the teacher knows the marks were adjusted.
///
/// The invariant this service enforces: awarded marks can never exceed the
/// maximum marks, and displayed totals are always recomputed from the
/// per-question marks.
class CorrectionValidationService {
  const CorrectionValidationService();

  /// Turns a raw decoded AI response into a [CorrectionResult].
  ///
  /// [model] is recorded on the result: this is the only place a
  /// [CorrectionResult] is built, so the attribution cannot be forgotten.
  CorrectionResult validate(Object? payload, {String model = ''}) {
    final List<String> warnings = <String>[];

    if (payload is! Map<String, dynamic>) {
      throw const ResultValidationException(
        'The AI response was not a JSON object.',
      );
    }

    final Object? rawQuestions = payload['questions'];
    if (rawQuestions is! List) {
      throw const ResultValidationException(
        'The AI response contained no list of questions.',
      );
    }
    if (rawQuestions.isEmpty) {
      throw const ResultValidationException(
        'The AI returned no questions. Check that the question paper and the '
        'answer sheet belong to the same exam.',
      );
    }

    final List<QuestionResult> questions = <QuestionResult>[
      for (int index = 0; index < rawQuestions.length; index++)
        _validateQuestion(rawQuestions[index], index + 1, warnings),
    ];

    _noteUnmatchedAnswers(payload['unmatched_answers'], warnings);

    // Totals are always recomputed locally — the model's arithmetic is never
    // the source of truth for what the teacher sees.
    final double total = questions.fold<double>(
      0,
      (double sum, QuestionResult q) => sum + q.awardedMarks,
    );
    final double maximumTotal = questions.fold<double>(
      0,
      (double sum, QuestionResult q) => sum + q.maximumMarks,
    );

    _noteIfDifferent(
      warnings,
      payload['total_marks'],
      total,
      'Reported total marks did not match the per-question marks; the total '
      'was recalculated.',
    );
    _noteIfDifferent(
      warnings,
      payload['maximum_total_marks'],
      maximumTotal,
      'Reported maximum total did not match the per-question maxima; the '
      'maximum was recalculated.',
    );

    final double percentage = maximumTotal > 0 ? total / maximumTotal * 100 : 0;

    return CorrectionResult(
      questions: questions,
      totalMarks: total,
      maximumTotalMarks: maximumTotal,
      percentage: percentage,
      model: model,
      warnings: warnings,
    );
  }

  QuestionResult _validateQuestion(
    Object? raw,
    int index,
    List<String> warnings,
  ) {
    final String where = 'Question #$index';
    if (raw is! Map<String, dynamic>) {
      throw ResultValidationException('$where was not a JSON object.');
    }

    final String number = _requireText(
      raw['question_number'],
      '$where question number',
    );
    final String label = 'Question $number';

    final double maximum = _requireNumber(
      raw['maximum_marks'],
      '$label maximum marks',
    );
    if (maximum < 0) {
      throw ResultValidationException(
        '$label has a negative maximum (${formatMarks(maximum)}).',
      );
    }

    // A maximum the question paper never printed was invented by the model, and
    // it silently changes the total the student is marked out of. The teacher
    // is told which question, so they can check the paper.
    if (raw['marks_stated_in_paper'] == false) {
      warnings.add(
        '$label: the question paper did not state its marks, so a maximum of '
        '${formatMarks(maximum)} was inferred from the question.',
      );
    }

    double awarded = _requireNumber(raw['awarded_marks'], '$label awarded marks');
    if (awarded < 0) {
      warnings.add('$label: awarded marks were negative and were raised to 0.');
      awarded = 0;
    }
    if (awarded > maximum) {
      warnings.add(
        '$label: awarded marks (${formatMarks(awarded)}) exceeded the maximum '
        '(${formatMarks(maximum)}) and were capped.',
      );
      awarded = maximum;
    }

    return QuestionResult(
      questionNumber: number,
      maximumMarks: maximum,
      awardedMarks: awarded,
      studentAnswer: _optionalText(raw['student_answer']) ?? 'No answer found',
      evaluation: _optionalText(raw['evaluation']) ?? 'No evaluation provided.',
      markingPoints: _validateMarkingPoints(raw['marking_points'], label),
    );
  }

  List<MarkingPoint> _validateMarkingPoints(Object? rawPoints, String label) {
    if (rawPoints == null) return const <MarkingPoint>[];
    if (rawPoints is! List) {
      throw ResultValidationException(
        '$label: the marking points were not a list.',
      );
    }

    final List<MarkingPoint> points = <MarkingPoint>[];
    for (int index = 0; index < rawPoints.length; index++) {
      final String where = '$label marking point ${index + 1}';
      final Object? raw = rawPoints[index];
      if (raw is! Map<String, dynamic>) {
        throw ResultValidationException('$where was not a JSON object.');
      }

      final String criterion = _requireText(raw['criterion'], '$where criterion');

      final Object? satisfied = raw['satisfied'];
      if (satisfied is! bool) {
        throw ResultValidationException(
          '$where: "satisfied" must be true or false.',
        );
      }

      double marks = _requireNumber(raw['marks'], '$where marks');
      if (marks < 0) marks = 0;
      if (!satisfied) marks = 0;

      points.add(
        MarkingPoint(
          criterion: criterion,
          satisfied: satisfied,
          marks: marks,
        ),
      );
    }

    return points;
  }

  /// Reports answers the student wrote that no question in the paper claims.
  ///
  /// Usually one of two things, and both matter: the student mislabelled an
  /// answer, or the wrong question paper was chosen. Either way the work exists
  /// and scored nothing, so it is never dropped silently.
  void _noteUnmatchedAnswers(Object? raw, List<String> warnings) {
    if (raw is! List || raw.isEmpty) return;

    final List<String> numbers = <String>[];
    for (final Object? entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      final Object? number = entry['question_number'];
      if (number is String && number.trim().isNotEmpty) {
        numbers.add(number.trim());
      }
    }

    if (numbers.isEmpty) return;

    warnings.add(
      'The answer sheet has ${numbers.length} answer(s) whose question number '
      'is not in the question paper (${numbers.join(', ')}). They were not '
      'marked — check that both documents are from the same exam.',
    );
  }

  double _requireNumber(Object? value, String where) {
    if (value is! num || value is bool) {
      throw ResultValidationException('$where must be a number.');
    }
    final double number = value.toDouble();
    if (!number.isFinite) {
      throw ResultValidationException('$where was not a finite number.');
    }
    return number;
  }

  String _requireText(Object? value, String where) {
    if (value is! String || value.trim().isEmpty) {
      throw ResultValidationException('$where must be a non-empty string.');
    }
    return value.trim();
  }

  String? _optionalText(Object? value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _noteIfDifferent(
    List<String> warnings,
    Object? reported,
    double computed,
    String message,
  ) {
    if (reported is num && reported is! bool) {
      if ((reported.toDouble() - computed).abs() > 0.01) warnings.add(message);
    }
  }
}
