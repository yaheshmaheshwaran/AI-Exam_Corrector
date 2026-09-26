import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/section_totals.dart';

/// Where one student's script has got to.
enum ScriptStatus {
  waiting('Not marked'),
  processing('Marking…'),
  failed('Stopped'),
  reviewRequired('To review'),
  marked('Marked');

  const ScriptStatus(this.label);

  final String label;
}

/// One student's script within a class set, and everything decided about it.
///
/// Each script keeps its own understanding, its own teacher reviews and its
/// own transcription corrections; the question paper and the guidance are
/// shared by the whole class.
class MarkedScript {
  MarkedScript(this.document);

  final SelectedDocument document;

  ExamAssessment? assessment;
  TeacherReviewBook reviews = const TeacherReviewBook();
  Map<String, String> transcriptions = const <String, String>{};

  /// Writing the teacher chose as a question's answer: region ID to question
  /// ID, for the chosen question paper.
  Map<String, String> assignments = const <String, String>{};

  /// Transcriptions were corrected since the script was last marked.
  bool correctionsPending = false;

  /// Why the last attempt stopped, when it did.
  String? error;

  bool processing = false;

  CorrectionResult? get result => assessment?.result;

  /// Still needs a run: never marked, stopped, or corrected since.
  bool get needsWork => result == null || correctionsPending;

  ScriptStatus get status {
    if (processing) return ScriptStatus.processing;
    final CorrectionResult? marked = result;
    if (marked == null) {
      return error == null ? ScriptStatus.waiting : ScriptStatus.failed;
    }
    return reviews.outstanding(marked) > 0
        ? ScriptStatus.reviewRequired
        : ScriptStatus.marked;
  }

  /// The mark that counts, with the teacher's overrides applied.
  double? get finalTotal {
    final CorrectionResult? marked = result;
    return marked == null ? null : reviews.finalTotal(marked);
  }

  /// Each section's marks, with the teacher's overrides; empty before
  /// marking, or on a paper without sections.
  List<SectionTotal> get sectionTotals {
    final ExamAssessment? marked = assessment;
    final CorrectionResult? result = marked?.result;
    if (marked == null || result == null) return const <SectionTotal>[];
    return SectionTotal.of(result, reviews, marked.questionPaper);
  }

  double? get finalPercentage {
    final CorrectionResult? marked = result;
    return marked == null ? null : reviews.finalPercentage(marked);
  }
}
