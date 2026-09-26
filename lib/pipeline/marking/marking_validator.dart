import 'dart:math' as math;

import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';

/// Turns the model's marking of one question into a [QuestionResult] that can
/// be trusted to display.
///
/// Every rule is enforced here rather than trusted to the prompt:
/// - the maximum comes from the question paper whenever the paper printed one;
/// - a point never awards more than it is worth, and marks are never negative;
/// - the question's mark is the sum of its points, capped at the maximum,
///   whatever total the model reported;
/// - evidence must name regions that are actually part of this answer —
///   anything else is dropped, and a mark left with no evidence is flagged;
/// - confidence combines the model's own with how well the answer could be
///   read and mapped, and anything below the threshold goes to the teacher.
class MarkingValidator {
  const MarkingValidator({required this.reviewThreshold});

  final double reviewThreshold;

  QuestionResult validate({
    required MarkingTask task,
    required JsonMap? raw,
    required Map<String, String> aliasToRegion,
    required String model,
  }) {
    final StudentAnswer answer = task.answer;
    final List<String> reasons = <String>[];

    if (raw == null) {
      return QuestionResult(
        questionNumber: task.question.displayNumber,
        questionId: task.question.questionId,
        questionText: task.question.questionText,
        section: task.question.sectionId,
        maximumMarks: task.question.maximumMarks ?? 0,
        awardedMarks: 0,
        studentAnswer: answer.text.isEmpty ? 'No answer found' : answer.text,
        evaluation: 'The marking engine returned no result for this question.',
        confidence: 0,
        needsReview: true,
        reviewReasons: const <String>[
          'Not marked by the AI — mark this question yourself.',
        ],
        evidenceRegionIds: answer.regionIds,
        answerPages: answer.pages,
        model: model,
      );
    }

    // The paper's maximum wins. Only an unprinted maximum comes from the model.
    final double? printed = task.question.maximumMarks;
    final double reported = math.max(0, readDouble(raw['maximum_marks']) ?? 0);
    final double maximum = printed ?? reported;
    if (printed == null) {
      reasons.add(
        'The question paper prints no marks for this question; a maximum of '
        '${formatMarks(maximum)} was inferred.',
      );
    } else if ((reported - printed).abs() > 0.001 && reported > 0) {
      reasons.add(
        'The AI worked to a maximum of ${formatMarks(reported)}; the paper\'s '
        '${formatMarks(printed)} was used.',
      );
    }

    final Set<String> allowed = answer.regionIds.toSet();
    bool unsupported = false;
    bool uncertainAward = false;
    int dropped = 0;

    final List<MarkingPoint> points = <MarkingPoint>[];
    final List<JsonMap> rawPoints = readObjects(raw['marking_points'], (JsonMap m) => m);
    for (int index = 0; index < rawPoints.length; index++) {
      final JsonMap point = rawPoints[index];
      final String? description = readString(point['description']);
      if (description == null) continue;

      final double available = math.max(0, readDouble(point['marks_available']) ?? 0);
      final double awarded =
          (readDouble(point['marks_awarded']) ?? 0).clamp(0.0, available).toDouble();

      final List<String> evidence = <String>[];
      for (final String cited in readStringList(point['evidence'])) {
        final String id = aliasToRegion[_alias(cited)] ?? cited;
        if (allowed.contains(id)) {
          if (!evidence.contains(id)) evidence.add(id);
        } else {
          dropped++;
        }
      }

      EvidenceBasis basis = EvidenceBasis.fromWire(point['basis']);
      String note = readRawString(point['note']) ?? '';
      if (awarded > 0 && evidence.isEmpty) {
        unsupported = true;
        basis = EvidenceBasis.uncertain;
        note = note.isEmpty
            ? 'No evidence region was cited for this mark.'
            : '$note (No evidence region was cited for this mark.)';
      }
      if (awarded > 0 && basis == EvidenceBasis.uncertain) uncertainAward = true;

      points.add(
        MarkingPoint(
          id: readString(point['id']) ?? 'MP${index + 1}',
          criterion: description,
          satisfied: awarded > 0,
          marks: awarded,
          marksAvailable: available,
          evidenceRegionIds: evidence,
          basis: basis,
          source: MarkingPointSource.fromWire(point['source']),
          note: note,
        ),
      );
    }

    final double available = points.fold<double>(
      0,
      (double sum, MarkingPoint p) => sum + p.marksAvailable,
    );
    if (available > maximum + 0.001) {
      reasons.add(
        'The marking points are worth ${formatMarks(available)} in total, '
        'more than the ${formatMarks(maximum)} available; the mark was capped.',
      );
    }

    final double summed = points.fold<double>(
      0,
      (double sum, MarkingPoint p) => sum + p.marks,
    );
    final double awarded = math.min(summed, maximum);
    final double? stated = readDouble(raw['awarded_marks']);
    if (stated != null && (stated - awarded).abs() > 0.001 && points.isNotEmpty) {
      reasons.add(
        'The AI reported ${formatMarks(stated)} marks but its marking points '
        'add up to ${formatMarks(awarded)}; the points were used.',
      );
    }

    if (unsupported) reasons.add('A mark was awarded without citing evidence.');
    if (uncertainAward) {
      reasons.add('A mark rests on evidence the AI marked as uncertain.');
    }
    if (dropped > 0) {
      reasons.add('$dropped evidence reference(s) did not belong to this answer '
          'and were removed.');
    }

    final double modelConfidence = readConfidence(raw['confidence'], orElse: 0.5);
    final double confidence = <double>[
      modelConfidence,
      answer.isEmpty ? 1 : answer.answerConfidence,
      answer.isEmpty ? 1 : answer.alignmentConfidence,
    ].reduce(math.min);

    final bool modelWantsReview = readBool(raw['needs_review']) ?? false;
    final List<String> modelReasons = readStringList(raw['review_reasons']);
    final bool needsReview = modelWantsReview ||
        confidence < reviewThreshold ||
        unsupported ||
        uncertainAward ||
        available > maximum + 0.001 ||
        printed == null;

    return QuestionResult(
      questionNumber: task.question.displayNumber,
      questionId: task.question.questionId,
      questionText: task.question.questionText,
      section: task.question.sectionId,
      maximumMarks: maximum,
      awardedMarks: awarded,
      studentAnswer: answer.isEmpty
          ? 'No answer found'
          : readString(raw['student_answer']) ?? answer.text,
      evaluation: readString(raw['explanation']) ?? 'No explanation was given.',
      markingPoints: points,
      confidence: confidence,
      needsReview: needsReview,
      reviewReasons: <String>[
        ...modelReasons,
        ...reasons,
        if (confidence < reviewThreshold)
          'Confidence ${(confidence * 100).round()}% is below the review '
              'threshold of ${(reviewThreshold * 100).round()}%.',
        if (needsReview) ...answer.flags,
      ],
      evidenceRegionIds: answer.regionIds,
      answerPages: answer.pages,
      interpretedReadings: <InterpretedReading>[
        for (final JsonMap reading
            in readObjects(raw['interpreted_readings'], (JsonMap m) => m))
          if (readString(reading['interpreted']) case final String interpreted)
            InterpretedReading(
              regionId: aliasToRegion[_alias(readString(reading['region']) ?? '')] ?? '',
              raw: readRawString(reading['raw']) ?? '',
              interpreted: interpreted,
              basis: EvidenceBasis.fromWire(reading['basis']),
            ),
      ],
      markingPointsSource: _pointsSource(raw['marking_points_source'], points),
      model: model,
      qualityBand: QualityBand.fromWire(raw['quality_band']),
      bandReason: readRawString(raw['band_reason'])?.trim() ?? '',
    );
  }

  /// A question with no answer at all is zero without asking a model — there
  /// is nothing to judge, and no request should be spent finding that out.
  QuestionResult unanswered(MarkingTask task) {
    final List<String> flags = task.answer.flags;
    return QuestionResult(
      questionNumber: task.question.displayNumber,
      questionId: task.question.questionId,
      questionText: task.question.questionText,
      section: task.question.sectionId,
      maximumMarks: task.question.maximumMarks ?? 0,
      awardedMarks: 0,
      studentAnswer: 'No answer found',
      evaluation: 'No answer to this question was found on the answer sheet.',
      confidence: flags.isEmpty ? 0.9 : 0.5,
      needsReview: flags.isNotEmpty || task.question.maximumMarks == null,
      reviewReasons: <String>[
        ...flags,
        if (task.question.maximumMarks == null)
          'The question paper prints no marks for this question.',
      ],
    );
  }

  static String _alias(String cited) =>
      cited.trim().replaceAll(RegExp(r'^\[|\]$'), '').toUpperCase();

  static MarkingPointSource _pointsSource(Object? raw, List<MarkingPoint> points) {
    if (raw == 'teacher') return MarkingPointSource.teacherGuidance;
    if (raw == 'paper') return MarkingPointSource.markScheme;
    if (raw == 'key') return MarkingPointSource.answerKey;
    if (raw == 'mixed') {
      // Named for whichever supplied source most of the points came from.
      int count(MarkingPointSource source) =>
          points.where((MarkingPoint p) => p.source == source).length;
      final int teacher = count(MarkingPointSource.teacherGuidance);
      final int paper = count(MarkingPointSource.markScheme);
      final int key = count(MarkingPointSource.answerKey);
      if (teacher > 0 && teacher >= paper && teacher >= key) return MarkingPointSource.teacherGuidance;
      if (paper > 0 && paper >= key) return MarkingPointSource.markScheme;
      if (key > 0) return MarkingPointSource.answerKey;
    }
    return MarkingPointSource.inferred;
  }
}
