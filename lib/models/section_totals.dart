import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';

/// One section of a marked paper and what it scored.
///
/// Worked out the same way as the paper's total, so the sections always add
/// up to it: the teacher's mark wherever it replaced the AI's, and nothing
/// from the alternative of an OR that does not count.
class SectionTotal {
  const SectionTotal({
    required this.sectionId,
    required this.title,
    required this.awarded,
    required this.aiAwarded,
    required this.maximum,
    required this.questionIds,
    this.instructions = '',
    this.statedMarks,
    this.toReview = 0,
  });

  /// As printed: `A`. Null for questions the paper puts in no section.
  final String? sectionId;

  /// How the section is named on screen: "Section A", "Section A · Short
  /// answer", "Part B".
  final String title;
  final String instructions;

  /// The final marks, with the teacher's overrides.
  final double awarded;
  final double aiAwarded;
  final double maximum;

  /// What the paper prints the section is worth, when it does.
  final double? statedMarks;

  /// Every question in the section, in paper order — counted or not.
  final List<String> questionIds;

  /// Questions still flagged for review that the teacher has not settled.
  final int toReview;

  /// For a compact breakdown: `A`, or `Other`.
  String get shortName => sectionId ?? 'Other';

  double get fraction => maximum > 0 ? (awarded / maximum).clamp(0.0, 1.0) : 0;

  /// The marked paper, section by section. Empty when the paper has no
  /// sections, so there is nothing to group.
  static List<SectionTotal> of(
    CorrectionResult result,
    TeacherReviewBook reviews,
    QuestionPaper paper,
  ) {
    if (!hasSections(paper, result.questions.map((QuestionResult q) => q.section))) {
      return const <SectionTotal>[];
    }
    final Map<String?, List<QuestionResult>> groups = <String?, List<QuestionResult>>{
      for (final String? id in _order(paper, result.questions.map((QuestionResult q) => q.section)))
        id: <QuestionResult>[],
    };
    for (final QuestionResult question in result.questions) {
      groups[question.section]!.add(question);
    }

    return <SectionTotal>[
      for (final MapEntry<String?, List<QuestionResult>> group in groups.entries)
        () {
          final Iterable<QuestionResult> counted =
              group.value.where((QuestionResult q) => q.counted);
          final QuestionSection? section = paper.section(group.key);
          return SectionTotal(
            sectionId: group.key,
            title: titleFor(group.key, section),
            instructions: section?.instructions ?? '',
            statedMarks: section?.statedMarks,
            awarded: counted.fold<double>(0, (double sum, QuestionResult q) => sum + reviews.finalMarks(q)),
            aiAwarded: counted.fold<double>(0, (double sum, QuestionResult q) => sum + q.awardedMarks),
            maximum: counted.fold<double>(0, (double sum, QuestionResult q) => sum + q.maximumMarks),
            questionIds: <String>[for (final QuestionResult q in group.value) q.questionId],
            toReview: counted
                .where((QuestionResult q) =>
                    q.needsReview &&
                    (reviews[q.questionId]?.status ?? ReviewStatus.pending) == ReviewStatus.pending)
                .length,
          );
        }(),
    ];
  }

  /// The paper's sections before marking, with what each is worth.
  static List<SectionTotal> ofPaper(QuestionPaper paper) {
    final List<Question> markable = paper.markable;
    if (!hasSections(paper, markable.map((Question q) => q.sectionId))) {
      return const <SectionTotal>[];
    }
    return <SectionTotal>[
      for (final String? id in _order(paper, markable.map((Question q) => q.sectionId)))
        SectionTotal(
          sectionId: id,
          title: titleFor(id, paper.section(id)),
          instructions: paper.section(id)?.instructions ?? '',
          statedMarks: paper.section(id)?.statedMarks,
          awarded: 0,
          aiAwarded: 0,
          maximum: paper.worthOf(<Question>[
            for (final Question q in paper.questions)
              if (q.sectionId == id) q,
          ]),
          questionIds: <String>[
            for (final Question q in markable)
              if (q.sectionId == id) q.questionId,
          ],
        ),
    ];
  }

  /// Whether there is any grouping to show.
  static bool hasSections(QuestionPaper paper, Iterable<String?> sectionIds) =>
      paper.sections.isNotEmpty || sectionIds.any((String? id) => id != null);

  /// Section IDs in the paper's order, then any it did not list, then none.
  static List<String?> _order(QuestionPaper paper, Iterable<String?> used) {
    final List<String?> order = <String?>[
      for (final QuestionSection section in paper.sections)
        if (used.contains(section.sectionId)) section.sectionId,
    ];
    for (final String? id in used) {
      if (id != null && !order.contains(id)) order.add(id);
    }
    if (used.contains(null)) order.add(null);
    return order;
  }

  /// "Section A"; "Section A · Short answer"; "Part B" when the paper calls
  /// its sections parts; "Other questions" for those in none.
  static String titleFor(String? id, QuestionSection? section) {
    if (id == null) return 'Other questions';
    final String title = section?.title.trim() ?? '';
    if (title.isEmpty) return 'Section $id';
    final RegExpMatch? named =
        RegExp(r'^(section|part)\s*[-–—:.]?\s*(\S+)$', caseSensitive: false).firstMatch(title);
    if (named != null && named.group(2)!.toLowerCase() == id.toLowerCase()) {
      final String word = named.group(1)!.toLowerCase();
      return '${word[0].toUpperCase()}${word.substring(1)} $id';
    }
    return 'Section $id · $title';
  }
}
