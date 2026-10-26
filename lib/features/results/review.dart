import 'dart:async';
import 'dart:io';


import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/services/review/teacher_work_store.dart';
import 'package:exam_corrector/state/marked_script.dart';
import 'package:exam_corrector/features/workspace.dart';

/// The teacher's review of the script on screen: corrected readings, answers
/// moved to another question, accepted and overridden marks.
mixin ReviewFeature on Workspace {
  // --------------------------------------------------------------------------
  // Teacher review — always of the script on screen
  // --------------------------------------------------------------------------

  /// Records the teacher's own reading of a region. The machine readings are
  /// kept; this is what marking reads the next time the paper is marked.
  Future<void> correctTranscription(String regionId, String text) async {
    final MarkedScript? script = currentScript;
    if (script == null) return;
    script.transcriptions = <String, String>{...script.transcriptions, regionId: text};
    script.correctionsPending = true;
    await _saveTranscriptions(script);
    setStatus('Transcription corrected. Re-mark to apply it.');
  }

  Future<void> revertTranscription(String regionId) async {
    final MarkedScript? script = currentScript;
    if (script == null || !script.transcriptions.containsKey(regionId)) return;
    script.transcriptions = Map<String, String>.of(script.transcriptions)..remove(regionId);
    script.correctionsPending = true;
    await _saveTranscriptions(script);
    setStatus('Correction removed. Re-mark to apply it.');
  }

  Future<void> _saveTranscriptions(MarkedScript script) async {
    try {
      await TeacherWorkStore(pipelineOf().store)
          .saveTranscriptions(script.document.contentHash, script.transcriptions);
    } on IOException catch (error) {
      fail('The correction could not be saved.', '$error');
    }
  }

  /// Writing the teacher chose as questions' answers, for the script on
  /// screen: region ID to question ID.
  Map<String, String> get assignments =>
      currentScript?.assignments ?? const <String, String>{};

  /// Makes [regionIds] the writing the teacher chose for [questionId] —
  /// replacing any chosen for it before, and taking each region away from
  /// any other question it was chosen for. Applied at the next re-mark.
  Future<void> assignRegions(String questionId, List<String> regionIds) async {
    final MarkedScript? script = currentScript;
    if (script == null || isBusy) return;
    script.assignments = <String, String>{
      for (final MapEntry<String, String> entry in script.assignments.entries)
        if (entry.value != questionId && !regionIds.contains(entry.key)) entry.key: entry.value,
      for (final String id in regionIds) id: questionId,
    };
    script.correctionsPending = true;
    await _saveAssignments(script);
    final String name =
        assessment?.questionPaper.byId(questionId)?.displayNumber ?? questionId;
    setStatus(regionIds.isEmpty
        ? 'Your choice for question $name was removed. Re-mark to apply it.'
        : 'Answer chosen for question $name. Re-mark to apply it.');
  }

  /// Drops the teacher's choice of answer for [questionId].
  Future<void> clearAssignments(String questionId) => assignRegions(questionId, const <String>[]);

  Future<void> _saveAssignments(MarkedScript script) async {
    final SelectedDocument? paper = chosenPaper;
    if (paper == null) return;
    try {
      await TeacherWorkStore(pipelineOf().store)
          .saveAssignments(script.document.contentHash, paper.contentHash, script.assignments);
    } on IOException catch (error) {
      fail('Your choice could not be saved.', '$error');
    }
  }

  /// The teacher agrees with the AI's mark.
  Future<void> acceptMark(String questionId, {String comment = ''}) async {
    final QuestionResult? question = result?.question(questionId);
    if (question == null) return;
    await _review(TeacherReview(
      questionId: questionId,
      status: ReviewStatus.accepted,
      aiMarks: question.awardedMarks,
      comment: comment,
      timestamp: DateTime.now(),
    ));
  }

  /// The teacher's mark replaces the AI's in every total — and the AI's is
  /// still recorded beside it.
  Future<void> overrideMark(
    String questionId,
    double marks, {
    String comment = '',
  }) async {
    final QuestionResult? question = result?.question(questionId);
    if (question == null) return;
    if (marks < 0 || marks > question.maximumMarks) {
      raiseError(
        'A mark for question ${question.questionNumber} must be between 0 and '
        '${formatMarks(question.maximumMarks)}.',
      );
      return;
    }
    await _review(TeacherReview(
      questionId: questionId,
      status: ReviewStatus.overridden,
      aiMarks: question.awardedMarks,
      teacherMarks: marks,
      comment: comment,
      timestamp: DateTime.now(),
    ));
  }

  Future<void> clearReview(String questionId) async {
    final MarkedScript? script = currentScript;
    if (script == null || script.reviews[questionId] == null) return;
    script.reviews = script.reviews.without(questionId);
    await persistReviews(script);
    notifyListeners();
  }

  Future<void> _review(TeacherReview review) async {
    final MarkedScript? script = currentScript;
    if (script == null) return;
    script.reviews = script.reviews.withReview(review);
    await persistReviews(script);
    setStatus(review.isOverride
        ? 'Mark changed to ${formatMarks(review.teacherMarks!)}. The AI\'s mark is kept for reference.'
        : 'Mark accepted.');
  }

  @override
  Future<void> persistReviews(MarkedScript script) async {
    final SelectedDocument? paper = chosenPaper;
    if (paper == null) return;
    try {
      await TeacherWorkStore(pipelineOf().store)
          .saveReviews(script.document.contentHash, paper.contentHash, script.reviews);
    } on IOException catch (error) {
      fail('The review could not be saved.', '$error');
    }
    await recordSamples(script);
  }

  double get finalTotal => currentScript?.finalTotal ?? 0;

  double get finalPercentage => currentScript?.finalPercentage ?? 0;
}
