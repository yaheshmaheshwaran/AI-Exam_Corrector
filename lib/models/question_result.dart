import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/json_read.dart';

/// Where a marking point came from.
enum MarkingPointSource {
  /// Taken from the teacher's marking guidance.
  teacherGuidance,

  /// Taken from the mark scheme printed on the question paper.
  markScheme,

  /// Decided by the marking model from the question and its subject
  /// knowledge, because nothing more specific was supplied.
  inferred;

  static MarkingPointSource fromWire(Object? name) => switch (name) {
        'teacher' || 'teacher_guidance' || 'teacherGuidance' =>
          MarkingPointSource.teacherGuidance,
        'paper' || 'mark_scheme' || 'markScheme' => MarkingPointSource.markScheme,
        _ => MarkingPointSource.inferred,
      };

  String get wireName => switch (this) {
        teacherGuidance => 'teacher',
        markScheme => 'paper',
        inferred => 'inferred',
      };
}

/// One marking point, and whether the answer earned it.
///
/// A point that awards marks must say which regions of the student's paper it
/// was awarded for. That is what makes a mark auditable: the teacher can click
/// the evidence and see the ink.
class MarkingPoint {
  const MarkingPoint({
    required this.criterion,
    required this.satisfied,
    required this.marks,
    this.id = '',
    double? marksAvailable,
    this.evidenceRegionIds = const <String>[],
    this.basis = EvidenceBasis.observed,
    this.source = MarkingPointSource.inferred,
    this.note = '',
  }) : marksAvailable = marksAvailable ?? marks;

  /// `MP1`, `MP2`…
  final String id;
  final String criterion;
  final bool satisfied;

  /// Marks awarded for this point.
  final double marks;

  /// Marks this point is worth.
  final double marksAvailable;

  /// The regions of the answer sheet this point was judged on.
  final List<String> evidenceRegionIds;

  /// Whether the judgement rests on what is plainly written, on a contextual
  /// reading, or on something that could not be established.
  final EvidenceBasis basis;

  final MarkingPointSource source;

  /// Anything the teacher should know about this point in particular.
  final String note;

  MarkingPoint copyWith({
    double? marks,
    bool? satisfied,
    List<String>? evidenceRegionIds,
    EvidenceBasis? basis,
    String? note,
  }) {
    return MarkingPoint(
      id: id,
      criterion: criterion,
      satisfied: satisfied ?? this.satisfied,
      marks: marks ?? this.marks,
      marksAvailable: marksAvailable,
      evidenceRegionIds: evidenceRegionIds ?? this.evidenceRegionIds,
      basis: basis ?? this.basis,
      source: source,
      note: note ?? this.note,
    );
  }

  JsonMap toJson() => <String, Object?>{
        'id': id,
        'criterion': criterion,
        'satisfied': satisfied,
        'marks': marks,
        'marksAvailable': marksAvailable,
        'evidenceRegionIds': evidenceRegionIds,
        'basis': basis.name,
        'source': source.wireName,
        'note': note,
      };

  static MarkingPoint? fromJson(JsonMap json) {
    final String? criterion = readString(json['criterion']);
    if (criterion == null) return null;
    return MarkingPoint(
      id: readString(json['id']) ?? '',
      criterion: criterion,
      satisfied: readBool(json['satisfied']) ?? false,
      marks: readDouble(json['marks']) ?? 0,
      marksAvailable: readDouble(json['marksAvailable']),
      evidenceRegionIds: readStringList(json['evidenceRegionIds']),
      basis: EvidenceBasis.fromWire(json['basis']),
      source: MarkingPointSource.fromWire(json['source']),
      note: readRawString(json['note']) ?? '',
    );
  }
}

/// A contextual reading the marking model relied on.
///
/// Kept beside the raw transcription, never in place of it: "chloroplost" in
/// an answer about chloroplasts may well mean chloroplast, but the teacher
/// should see that it was read that way.
class InterpretedReading {
  const InterpretedReading({
    required this.regionId,
    required this.raw,
    required this.interpreted,
    required this.basis,
  });

  final String regionId;
  final String raw;
  final String interpreted;
  final EvidenceBasis basis;

  JsonMap toJson() => <String, Object?>{
        'regionId': regionId,
        'raw': raw,
        'interpreted': interpreted,
        'basis': basis.name,
      };

  static InterpretedReading? fromJson(JsonMap json) {
    final String? interpreted = readString(json['interpreted']);
    if (interpreted == null) return null;
    return InterpretedReading(
      regionId: readString(json['regionId']) ?? '',
      raw: readRawString(json['raw']) ?? '',
      interpreted: interpreted,
      basis: EvidenceBasis.fromWire(json['basis']),
    );
  }
}

/// The marking result for a single question.
///
/// This is the per-question MarkingResult: marks, the marking points behind
/// them, the evidence each rests on, and how sure the engine is. Instances are
/// only built by validation, so awarded marks never exceed the maximum.
class QuestionResult {
  const QuestionResult({
    required this.questionNumber,
    required this.maximumMarks,
    required this.awardedMarks,
    required this.studentAnswer,
    required this.evaluation,
    this.markingPoints = const <MarkingPoint>[],
    this.questionId = '',
    this.questionText = '',
    this.section,
    this.confidence = 1,
    this.needsReview = false,
    this.reviewReasons = const <String>[],
    this.evidenceRegionIds = const <String>[],
    this.answerPages = const <int>[],
    this.interpretedReadings = const <InterpretedReading>[],
    this.markingPointsSource = MarkingPointSource.inferred,
    this.model = '',
    this.counted = true,
    this.choiceNote = '',
  });

  /// As the question paper prints it.
  final String questionNumber;
  final double maximumMarks;
  final double awardedMarks;

  /// The student's answer as marked, or "No answer found".
  final String studentAnswer;

  /// Why these marks were awarded.
  final String evaluation;
  final List<MarkingPoint> markingPoints;

  final String questionId;
  final String questionText;
  final String? section;

  /// How sure the marking is, 0..1 — combining the model's own confidence
  /// with how well the answer could be read and mapped.
  final double confidence;

  /// Below the review threshold, or flagged for a specific reason.
  final bool needsReview;
  final List<String> reviewReasons;

  /// Every region the answer was assembled from.
  final List<String> evidenceRegionIds;
  final List<int> answerPages;

  final List<InterpretedReading> interpretedReadings;

  final MarkingPointSource markingPointsSource;

  /// The model that marked this question.
  final String model;

  /// Whether the marks count towards the total. False for an option of an
  /// OR (or "answer any N") choice other than the one that counts: it is
  /// still marked and shown, but left out of every total.
  final bool counted;

  /// Which option of a choice counts, and why, when the question is one.
  final String choiceNote;

  String get explanation => evaluation;

  QuestionResult copyWith({
    double? awardedMarks,
    double? confidence,
    bool? needsReview,
    List<String>? reviewReasons,
    List<MarkingPoint>? markingPoints,
    bool? counted,
    String? choiceNote,
  }) {
    return QuestionResult(
      questionNumber: questionNumber,
      maximumMarks: maximumMarks,
      awardedMarks: awardedMarks ?? this.awardedMarks,
      studentAnswer: studentAnswer,
      evaluation: evaluation,
      markingPoints: markingPoints ?? this.markingPoints,
      questionId: questionId,
      questionText: questionText,
      section: section,
      confidence: confidence ?? this.confidence,
      needsReview: needsReview ?? this.needsReview,
      reviewReasons: reviewReasons ?? this.reviewReasons,
      evidenceRegionIds: evidenceRegionIds,
      answerPages: answerPages,
      interpretedReadings: interpretedReadings,
      markingPointsSource: markingPointsSource,
      model: model,
      counted: counted ?? this.counted,
      choiceNote: choiceNote ?? this.choiceNote,
    );
  }

  JsonMap toJson() => <String, Object?>{
        'questionNumber': questionNumber,
        'questionId': questionId,
        'questionText': questionText,
        'section': ?section,
        'maximumMarks': maximumMarks,
        'awardedMarks': awardedMarks,
        'studentAnswer': studentAnswer,
        'evaluation': evaluation,
        'confidence': confidence,
        'needsReview': needsReview,
        'reviewReasons': reviewReasons,
        'evidenceRegionIds': evidenceRegionIds,
        'answerPages': answerPages,
        'markingPointsSource': markingPointsSource.wireName,
        'model': model,
        if (!counted) 'counted': false,
        if (choiceNote.isNotEmpty) 'choiceNote': choiceNote,
        'markingPoints': <JsonMap>[
          for (final MarkingPoint point in markingPoints) point.toJson(),
        ],
        'interpretedReadings': <JsonMap>[
          for (final InterpretedReading reading in interpretedReadings)
            reading.toJson(),
        ],
      };

  static QuestionResult? fromJson(JsonMap json) {
    final String? number = readString(json['questionNumber']);
    final double? maximum = readDouble(json['maximumMarks']);
    final double? awarded = readDouble(json['awardedMarks']);
    if (number == null || maximum == null || awarded == null) return null;
    return QuestionResult(
      questionNumber: number,
      questionId: readString(json['questionId']) ?? '',
      questionText: readRawString(json['questionText']) ?? '',
      section: readString(json['section']),
      maximumMarks: maximum,
      awardedMarks: awarded,
      studentAnswer: readRawString(json['studentAnswer']) ?? '',
      evaluation: readRawString(json['evaluation']) ?? '',
      confidence: readConfidence(json['confidence'], orElse: 1),
      needsReview: readBool(json['needsReview']) ?? false,
      reviewReasons: readStringList(json['reviewReasons']),
      evidenceRegionIds: readStringList(json['evidenceRegionIds']),
      answerPages: <int>[
        for (final Object? page in readList(json['answerPages']))
          if (readInt(page) case final int value) value,
      ],
      markingPointsSource:
          MarkingPointSource.fromWire(json['markingPointsSource']),
      model: readString(json['model']) ?? '',
      counted: readBool(json['counted']) ?? true,
      choiceNote: readRawString(json['choiceNote']) ?? '',
      markingPoints: readObjects(json['markingPoints'], MarkingPoint.fromJson),
      interpretedReadings:
          readObjects(json['interpretedReadings'], InterpretedReading.fromJson),
    );
  }
}
