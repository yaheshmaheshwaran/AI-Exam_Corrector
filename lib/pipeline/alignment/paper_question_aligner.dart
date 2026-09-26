import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/pipeline/engines.dart';

/// Maps answer segments onto the question paper.
///
/// The question paper is the authority: a segment is assigned only to a
/// question the paper contains. Everything else is reported, never dropped —
/// a label the paper does not have, and content before the first label.
class PaperQuestionAligner implements QuestionAligner {
  const PaperQuestionAligner();

  @override
  AlignmentResult align(List<AnswerSegment> segments, QuestionPaper paper) {
    final Map<String, _Building> building = <String, _Building>{};
    final List<String> unassigned = <String>[];
    final List<String> preamble = <String>[];
    bool labelled = false;
    final List<UnmatchedLabel> unmatched = <UnmatchedLabel>[];
    final List<String> warnings = <String>[];
    final List<Question> markable = paper.markable;

    List<String>? previous;

    void assign(
      List<Question> questions,
      AnswerSegment segment,
      double confidence,
      AlignmentMethod method, [
      String? note,
    ]) {
      for (final Question question in questions) {
        building
            .putIfAbsent(question.questionId, () => _Building(question.questionId))
            .add(segment.segmentId, confidence, method, note);
      }
      previous = questions.map((Question q) => q.questionId).toList();
    }

    for (final AnswerSegment segment in segments) {
      final String? key = segment.labelKey;
      if (key != null) labelled = true;

      if (key == null) {
        final List<String>? before = previous;
        if (segment.continuesPrevious && before != null) {
          assign(
            <Question>[for (final String id in before) paper.byId(id)!],
            segment,
            segment.confidence,
            AlignmentMethod.continuation,
            'Continued onto page ${segment.pageNumbers.first} without a label.',
          );
        } else if (markable.length == 1) {
          assign(
            markable,
            segment,
            0.8,
            AlignmentMethod.soleQuestion,
            'No label, but the paper has only this question.',
          );
        } else if (!labelled) {
          preamble.addAll(segment.regionIds);
        } else {
          unassigned.addAll(segment.regionIds);
        }
        continue;
      }

      final QuestionLabel label = QuestionLabel.fromKey(key);
      final Question? exact = paper.byLabel(label);

      if (exact != null && exact.isLeaf) {
        assign(<Question>[exact], segment, segment.confidence, AlignmentMethod.label);
      } else if (exact != null) {
        // "2" written above an answer to a question with parts. Every part may
        // be answered in it, so every part sees it — and says so.
        assign(
          exact.leaves,
          segment,
          segment.confidence * 0.7,
          AlignmentMethod.parentLabel,
          'Labelled ${exact.displayNumber} rather than a specific part.',
        );
      } else {
        final Question? ancestor = _nearestLeafAncestor(label, paper);
        if (ancestor != null) {
          assign(
            <Question>[ancestor],
            segment,
            segment.confidence * 0.8,
            AlignmentMethod.label,
            'Labelled ${label.display}, but the paper has no such part; taken '
                'as ${ancestor.displayNumber}.',
          );
        } else {
          unmatched.add(
            UnmatchedLabel(label: segment.label ?? label.display, segmentId: segment.segmentId),
          );
          unassigned.addAll(segment.regionIds);
          previous = null;
        }
      }
    }

    if (unmatched.isNotEmpty) {
      warnings.add(
        'The answer sheet has ${unmatched.length} answer(s) labelled with a '
        'question the paper does not contain '
        '(${unmatched.map((UnmatchedLabel u) => u.label).join(', ')}). They '
        'were not marked — check that both documents are from the same exam.',
      );
    }

    return AlignmentResult(
      segments: segments,
      alignments: <String, QuestionAlignment>{
        for (final _Building b in building.values) b.questionId: b.build(),
      },
      unassignedRegionIds: unassigned,
      preambleRegionIds: preamble,
      unmatchedLabels: unmatched,
      warnings: warnings,
    );
  }

  Question? _nearestLeafAncestor(QuestionLabel label, QuestionPaper paper) {
    QuestionLabel? ancestor = label.parent;
    while (ancestor != null) {
      final Question? question = paper.byLabel(ancestor);
      if (question != null) return question.isLeaf ? question : null;
      ancestor = ancestor.parent;
    }
    return null;
  }
}

class _Building {
  _Building(this.questionId);

  final String questionId;
  final List<String> segmentIds = <String>[];
  final List<AlignmentMethod> methods = <AlignmentMethod>[];
  final List<String> notes = <String>[];
  double confidence = 1;

  void add(String segmentId, double value, AlignmentMethod method, String? note) {
    segmentIds.add(segmentId);
    methods.add(method);
    if (note != null && !notes.contains(note)) notes.add(note);
    if (value < confidence) confidence = value;
  }

  QuestionAlignment build() => QuestionAlignment(
        questionId: questionId,
        segmentIds: segmentIds,
        confidence: confidence,
        methods: methods,
        notes: notes,
      );
}
