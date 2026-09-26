import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';

/// Applies the teacher's own decisions about which writing answers which
/// question, on top of what the app found.
///
/// A chosen region is taken out of wherever the app put it — another
/// question, the writing before the first label, or nowhere — and becomes
/// part of the answer to the question the teacher chose, in reading order.
/// The app's mapping of everything else is left exactly as it was.
class TeacherAssignments {
  const TeacherAssignments();

  static const String note = 'You chose writing on the page as part of this answer.';

  AlignmentResult apply(
    AlignmentResult alignment,
    Map<String, String> assignments,
    ExamDocument document,
    QuestionPaper paper,
  ) {
    // Only regions that exist, chosen for questions that are marked.
    final Set<String> markable = <String>{
      for (final Question question in paper.markable) question.questionId,
    };
    final Map<String, String> chosen = <String, String>{
      for (final MapEntry<String, String> entry in assignments.entries)
        if (markable.contains(entry.value) && document.region(entry.key) != null)
          entry.key: entry.value,
    };
    if (chosen.isEmpty) return alignment;

    int order(String regionId) {
      final PageRegion region = document.region(regionId)!;
      return region.pageNumber * 100000 + region.readingOrder;
    }

    // Every segment, without the chosen regions; a segment left empty goes.
    final List<AnswerSegment> segments = <AnswerSegment>[];
    for (final AnswerSegment segment in alignment.segments) {
      final List<String> kept = <String>[
        for (final String id in segment.regionIds)
          if (!chosen.containsKey(id)) id,
      ];
      if (kept.isEmpty) continue;
      segments.add(kept.length == segment.regionIds.length
          ? segment
          : AnswerSegment(
              segmentId: segment.segmentId,
              regionIds: kept,
              pageNumbers: <int>{for (final String id in kept) document.region(id)!.pageNumber}.toList(),
              label: segment.label,
              labelKey: segment.labelKey,
              labelRegionId: chosen.containsKey(segment.labelRegionId) ? null : segment.labelRegionId,
              continuesPrevious: segment.continuesPrevious,
              confidence: segment.confidence,
            ));
    }
    final Set<String> surviving = <String>{for (final AnswerSegment s in segments) s.segmentId};

    // One segment per question, holding the writing chosen for it.
    final Map<String, List<String>> byQuestion = <String, List<String>>{};
    for (final MapEntry<String, String> entry in chosen.entries) {
      byQuestion.putIfAbsent(entry.value, () => <String>[]).add(entry.key);
    }
    final Map<String, String> added = <String, String>{};
    for (final MapEntry<String, List<String>> entry in byQuestion.entries) {
      final List<String> regions = entry.value..sort((String a, String b) => order(a).compareTo(order(b)));
      final String id = 'teacher-${entry.key}';
      segments.add(AnswerSegment(
        segmentId: id,
        regionIds: regions,
        pageNumbers: <int>{for (final String r in regions) document.region(r)!.pageNumber}.toList(),
      ));
      added[entry.key] = id;
    }

    int segmentOrder(String segmentId) {
      final AnswerSegment? segment =
          segments.where((AnswerSegment s) => s.segmentId == segmentId).firstOrNull;
      return segment == null || segment.regionIds.isEmpty ? 0 : order(segment.regionIds.first);
    }

    final Map<String, QuestionAlignment> alignments = <String, QuestionAlignment>{};
    for (final String questionId in <String>{...alignment.alignments.keys, ...added.keys}) {
      final QuestionAlignment? existing = alignment.alignments[questionId];
      final List<String> segmentIds = <String>[
        ...?existing?.segmentIds.where(surviving.contains),
        ?added[questionId],
      ]..sort((String a, String b) => segmentOrder(a).compareTo(segmentOrder(b)));
      if (segmentIds.isEmpty) continue;
      final bool teacher = added.containsKey(questionId);
      final bool onlyTeacher = teacher && segmentIds.length == 1;
      alignments[questionId] = QuestionAlignment(
        questionId: questionId,
        segmentIds: segmentIds,
        confidence: onlyTeacher ? 1 : existing?.confidence ?? 1,
        methods: <AlignmentMethod>[
          ...?existing?.methods,
          if (teacher) AlignmentMethod.teacher,
        ],
        notes: <String>[...?existing?.notes, if (teacher) note],
      );
    }

    return AlignmentResult(
      segments: segments,
      alignments: alignments,
      unassignedRegionIds: <String>[
        for (final String id in alignment.unassignedRegionIds)
          if (!chosen.containsKey(id)) id,
      ],
      preambleRegionIds: <String>[
        for (final String id in alignment.preambleRegionIds)
          if (!chosen.containsKey(id)) id,
      ],
      unmatchedLabels: alignment.unmatchedLabels,
      warnings: alignment.warnings,
    );
  }
}
