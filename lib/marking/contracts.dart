import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/question_result.dart';

/// Reports progress within a stage: a message for the teacher and how far
/// through the stage it is, 0..1.
typedef StageProgress = void Function(String message, double fraction);

/// What a question paper can be read from.
class QuestionPaperSourceData {
  const QuestionPaperSourceData({
    required this.document,
    this.text,
    this.pages = const <ExamPage>[],
  });

  final SelectedDocument document;

  /// The text layer, when the paper has one.
  final String? text;

  /// Rendered pages, when it does not.
  final List<ExamPage> pages;
}

/// Normalises a question paper into sections, questions, parts and marks.
abstract class QuestionPaperExtractor {
  String get fingerprint;

  Future<QuestionPaper> extract(
    QuestionPaperSourceData source, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}

/// The answer sheet split into logical answer blocks.
class BoundaryResult {
  const BoundaryResult({
    required this.document,
    required this.evidence,
    required this.segments,
    this.warnings = const <String>[],
  });

  /// The document, with any block that held two answers split at the label.
  final ExamDocument document;
  final EvidenceSet evidence;
  final List<AnswerSegment> segments;

  /// Numbers that looked like labels but were read as part of an answer.
  final List<String> warnings;
}

/// Finds where each answer starts and ends, across regions and pages.
abstract class AnswerBoundaryDetector {
  BoundaryResult detect(
    ExamDocument document,
    EvidenceSet evidence,
    QuestionPaper paper,
  );
}

/// Maps answer blocks onto the question paper's questions.
abstract class QuestionAligner {
  AlignmentResult align(List<AnswerSegment> segments, QuestionPaper paper);
}

/// Assembles each question's complete answer from its regions and evidence.
abstract class AnswerReconstructor {
  Map<String, StudentAnswer> reconstruct({
    required ExamDocument document,
    required EvidenceSet evidence,
    required AlignmentResult alignment,
    required QuestionPaper paper,
  });
}

/// Where a question's key comes from.
enum AnswerKeySource {
  /// Prepared by the AI from the question alone.
  ai,

  /// The teacher's: their own answer key, or their correction of a line.
  teacher,
}

/// One question to mark, with everything the marker should see.
class MarkingTask {
  const MarkingTask({
    required this.question,
    required this.answer,
    this.section,
    this.images = const <MarkingImage>[],
    this.markScheme = '',
    this.paperGuidance = '',
    this.choice = '',
    this.syllabus = '',
    this.syllabusLabel = '',
    this.syllabusFocus = '',
    this.syllabusCourse = '',
    this.standard = const MarkingStandard(),
    this.answerKey = '',
    this.answerKeySource = AnswerKeySource.ai,
    this.keyOption,
    this.expectedWords,
  });

  final Question question;
  final QuestionSection? section;
  final StudentAnswer answer;
  final List<MarkingImage> images;

  /// The mark scheme the question paper printed for this question, its
  /// parent's included. Empty when the paper prints none.
  final String markScheme;

  /// General marking instructions printed with the paper's scheme.
  final String paperGuidance;

  /// The choice this question is an option of, as it reads: "11(a) or
  /// 11(b)". Empty when it is not one.
  final String choice;

  /// The part of the course syllabus the question falls under: its unit and
  /// topics. Empty when no syllabus is used or no unit matched.
  final String syllabus;

  /// That unit's name, for display: "Unit III — Communication".
  final String syllabusLabel;

  /// The syllabus topics the question touches: what the syllabus bonus
  /// measures an answer against. Not sent to the AI.
  final String syllabusFocus;

  /// The course the syllabus belongs to, when one is used.
  final String syllabusCourse;

  /// How strictly to judge, and the college's written rules.
  final MarkingStandard standard;

  /// The answer key fixed for the question before any script was read.
  /// Empty when the paper prints a mark scheme for it, or no key was made.
  final String answerKey;

  /// Whose key [answerKey] is: the AI's, or the teacher's own.
  final AnswerKeySource answerKeySource;

  /// The right option when the teacher's key gives one for a multiple-choice
  /// question: `b`.
  final String? keyOption;

  /// About how long a full answer is, from the answer key.
  final int? expectedWords;
}

/// An image of part of the student's answer, tied to its region.
class MarkingImage {
  const MarkingImage({
    required this.regionId,
    required this.path,
    required this.reason,
  });

  final String regionId;
  final String path;

  /// Why it is attached: a diagram, an uncertain reading…
  final String reason;
}

/// Marks answers against their questions, with evidence for every mark.
abstract class MarkingEngine {
  String get fingerprint;

  /// Marks [tasks], returning one validated result per task, in order.
  ///
  /// [judge], when given, is the only model that may mark: the one that
  /// marked the rest of this script. A script's marks never come from two
  /// models — each marks to its own standard — so when the judge has no
  /// quota left, marking stops rather than moving to another model.
  ///
  /// [models], when given, replaces the marking models — the backup the
  /// teacher chose to mark with while those are out of quota.
  Future<List<QuestionResult>> mark(
    List<MarkingTask> tasks, {
    required String guidance,
    required bool typedAnswerSheet,
    String? judge,
    List<String>? models,
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}
