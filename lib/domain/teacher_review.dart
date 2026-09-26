import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';

enum ReviewStatus {
  /// The teacher has not looked at this question yet.
  pending,

  /// The teacher agreed with the AI's mark.
  accepted,

  /// The teacher set a different mark.
  overridden,
}

/// A teacher's decision on one question.
///
/// Teacher corrections are authoritative, but they are recorded beside the AI
/// result rather than written into it: both marks, the comment and the time
/// are kept, so it is always visible what the AI proposed and what the
/// teacher decided.
class TeacherReview {
  const TeacherReview({
    required this.questionId,
    required this.status,
    required this.aiMarks,
    required this.timestamp,
    this.teacherMarks,
    this.comment = '',
  });

  final String questionId;
  final ReviewStatus status;

  /// The AI's mark at the time of the review.
  final double aiMarks;

  /// Set only when the teacher overrode the mark.
  final double? teacherMarks;
  final String comment;
  final DateTime timestamp;

  bool get isOverride => status == ReviewStatus.overridden && teacherMarks != null;

  JsonMap toJson() => <String, Object?>{
        'questionId': questionId,
        'status': status.name,
        'aiMarks': aiMarks,
        'teacherMarks': ?teacherMarks,
        'comment': comment,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  static TeacherReview? fromJson(JsonMap json) {
    final String? id = readString(json['questionId']);
    if (id == null) return null;
    return TeacherReview(
      questionId: id,
      status: readEnum(ReviewStatus.values, json['status'], ReviewStatus.pending),
      aiMarks: readDouble(json['aiMarks']) ?? 0,
      teacherMarks: readDouble(json['teacherMarks']),
      comment: readRawString(json['comment']) ?? '',
      timestamp: DateTime.tryParse(readString(json['timestamp']) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// Every review for one answer sheet marked against one question paper.
class TeacherReviewBook {
  const TeacherReviewBook([this.reviews = const <String, TeacherReview>{}]);

  final Map<String, TeacherReview> reviews;

  TeacherReview? operator [](String questionId) => reviews[questionId];

  TeacherReviewBook withReview(TeacherReview review) =>
      TeacherReviewBook(<String, TeacherReview>{
        ...reviews,
        review.questionId: review,
      });

  TeacherReviewBook without(String questionId) => TeacherReviewBook(
        Map<String, TeacherReview>.of(reviews)..remove(questionId),
      );

  /// The mark that counts: the teacher's when they overrode it.
  double finalMarks(QuestionResult question) {
    final TeacherReview? review = reviews[question.questionId];
    if (review != null && review.isOverride) return review.teacherMarks!;
    return question.awardedMarks;
  }

  /// Leaves out a question that is not counted — the other option of an OR —
  /// whatever the teacher gave it.
  double finalTotal(CorrectionResult result) => result.questions
      .where((QuestionResult q) => q.counted)
      .fold<double>(0, (double sum, QuestionResult q) => sum + finalMarks(q));

  double finalPercentage(CorrectionResult result) =>
      result.maximumTotalMarks > 0
          ? finalTotal(result) / result.maximumTotalMarks * 100
          : 0;

  int get overrideCount =>
      reviews.values.where((TeacherReview review) => review.isOverride).length;

  /// Questions still flagged for review that the teacher has not settled.
  int outstanding(CorrectionResult result) => result.questions
      .where((QuestionResult q) =>
          q.counted &&
          q.needsReview &&
          (reviews[q.questionId]?.status ?? ReviewStatus.pending) ==
              ReviewStatus.pending)
      .length;

  JsonMap toJson() => <String, Object?>{
        'reviews': <JsonMap>[
          for (final TeacherReview review in reviews.values) review.toJson(),
        ],
      };

  static TeacherReviewBook fromJson(JsonMap json) => TeacherReviewBook(
        <String, TeacherReview>{
          for (final TeacherReview review
              in readObjects(json['reviews'], TeacherReview.fromJson))
            review.questionId: review,
        },
      );
}
