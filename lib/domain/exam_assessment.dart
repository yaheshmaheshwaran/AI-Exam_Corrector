import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/correction_result.dart';

/// Everything one correction produced: the understood answer sheet, the
/// question structure, the mapping between them, the reconstructed answers,
/// and the marks.
///
/// [result] can be null while every other field is complete. When marking
/// fails — no quota, no network — the extracted answers are still worth
/// keeping, and a later attempt starts from them.
class ExamAssessment {
  const ExamAssessment({
    required this.job,
    required this.answerSheet,
    required this.questionPaper,
    required this.evidence,
    required this.alignment,
    required this.answers,
    this.result,
    this.warnings = const <String>[],
  });

  final ProcessingJob job;
  final ExamDocument answerSheet;
  final QuestionPaper questionPaper;
  final EvidenceSet evidence;
  final AlignmentResult alignment;

  /// Keyed by question ID; one per markable question, answered or not.
  final Map<String, StudentAnswer> answers;

  final CorrectionResult? result;
  final List<String> warnings;

  bool get isMarked => result != null;

  StudentAnswer? answerFor(String questionId) => answers[questionId];

  PageRegion? region(String regionId) => answerSheet.region(regionId);

  ExamPage? pageOf(String regionId) {
    final PageRegion? region = this.region(regionId);
    return region == null ? null : answerSheet.page(region.pageId);
  }

  ExamAssessment copyWith({
    ProcessingJob? job,
    ExamDocument? answerSheet,
    EvidenceSet? evidence,
    Map<String, StudentAnswer>? answers,
    CorrectionResult? Function()? result,
    List<String>? warnings,
  }) {
    return ExamAssessment(
      job: job ?? this.job,
      answerSheet: answerSheet ?? this.answerSheet,
      questionPaper: questionPaper,
      evidence: evidence ?? this.evidence,
      alignment: alignment,
      answers: answers ?? this.answers,
      result: result == null ? this.result : result(),
      warnings: warnings ?? this.warnings,
    );
  }
}
