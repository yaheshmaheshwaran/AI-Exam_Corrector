import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/marking_rules.dart';

/// Marks a multiple-choice question straight from the teacher's key — the
/// way a teacher ticks an MCQ against the key, without asking anyone.
///
/// Only when there is no doubt: the key gives the option, the student chose
/// exactly one option, nothing is crossed out, and the writing was read and
/// placed with confidence. Anything else goes to the AI as usual.
class KeyedMcqMarker {
  const KeyedMcqMarker({required this.reviewThreshold, this.standard = const MarkingStandard()});

  final double reviewThreshold;
  final MarkingStandard standard;

  static const String markedBy = 'your answer key';

  /// `b`, `(b)`, `b)`, `Ans: B`, `Option (c)`, `(b) mitochondrion`, and the
  /// question label in front of any of them: `3. (b)`.
  static final RegExp _chosen = RegExp(
    r'^\s*(?:q(?:uestion)?\s*\.?\s*)?(?:\d{1,3}\s*[.):\-]?\s*)?'
    r'(?:(?:ans(?:wer)?|option|opt)\s*[:.\-]?\s*)?'
    r'\(?\s*([a-e])\s*\)?(?:[.):\s]\s*(.*))?$',
    caseSensitive: false,
  );

  /// The student's one chosen option, or null when it is not clear.
  static String? chosenOption(String answer) {
    final String text = answer.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty || text.length > 120) return null;
    final RegExpMatch? m = _chosen.firstMatch(text);
    if (m == null) return null;
    // "(b) mitochondrion" is fine; "(b) or (c)" is two choices.
    final String rest = m.group(2) ?? '';
    if (RegExp(r'(?:^|\s|\()[a-e]\)', caseSensitive: false).hasMatch(rest)) return null;
    return m.group(1)!.toLowerCase();
  }

  /// The result, or null when the question must go to the AI.
  QuestionResult? mark(MarkingTask task) {
    final String? key = task.keyOption;
    final double? maximum = task.question.maximumMarks;
    if (key == null || maximum == null || task.answerKeySource != AnswerKeySource.teacher) return null;
    if (!MarkingRules.isMcqQuestion(task.question, standard)) return null;
    final StudentAnswer answer = task.answer;
    if (answer.isEmpty || answer.crossedOut.isNotEmpty || answer.visualRegionIds.isNotEmpty) return null;
    final double confidence = answer.answerConfidence < answer.alignmentConfidence
        ? answer.answerConfidence
        : answer.alignmentConfidence;
    if (confidence < reviewThreshold || answer.alignmentConfidence < 0.8) return null;
    final String? chosen = chosenOption(answer.text);
    if (chosen == null) return null;

    final bool right = chosen == key;
    return QuestionResult(
      questionNumber: task.question.displayNumber,
      questionId: task.question.questionId,
      questionText: task.question.questionText,
      section: task.question.sectionId,
      maximumMarks: maximum,
      awardedMarks: right ? maximum : 0,
      studentAnswer: '($chosen)',
      evaluation: right
          ? 'Chose ($chosen), the answer in your key.'
          : 'Chose ($chosen); your key gives ($key).',
      markingPoints: <MarkingPoint>[
        MarkingPoint(
          id: 'MP1',
          criterion: 'Chooses option ($key)',
          satisfied: right,
          marks: right ? maximum : 0,
          marksAvailable: maximum,
          evidenceRegionIds: answer.regionIds,
          basis: EvidenceBasis.observed,
          source: MarkingPointSource.teacherKey,
          note: 'Marked directly against your answer key.',
        ),
      ],
      confidence: confidence,
      evidenceRegionIds: answer.regionIds,
      answerPages: answer.pages,
      markingPointsSource: MarkingPointSource.teacherKey,
      model: markedBy,
      keyMatch: right ? KeyMatch.matches : KeyMatch.differs,
    );
  }
}
