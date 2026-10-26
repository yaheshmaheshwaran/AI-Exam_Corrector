import 'dart:async';
import 'dart:io';


import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/moderation.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/services/review/teacher_work_store.dart';
import 'package:exam_corrector/state/marked_script.dart';
import 'package:exam_corrector/features/workspace.dart';

/// Moderation: bringing the AI's marks to the teacher's standard, worked out
/// from the questions the teacher marked themselves.
mixin ModerationFeature on Workspace {
  /// The teacher's own marks on this paper's scripts, script by script,
  /// against the AI's — what moderation is worked out from.
  Map<String, List<ModerationSample>> moderationSamples = <String, List<ModerationSample>>{};


  /// What the teacher's marks so far suggest; null until there are enough.
  Moderation? get suggestedModeration => Moderation.from(moderationSamples);

  /// Whether the teacher's marks suggest a moderation other than the one in
  /// force.
  bool get moderationOutdated {
    final Moderation? suggested = suggestedModeration;
    return suggested != null && suggested.differsFrom(appliedModeration);
  }

  /// How far the AI is from the teacher on the questions they marked — as
  /// marked, and moderated as it is (or would be); null before they mark any.
  ({double before, double after, int questions})? get agreement => Moderation.agreement(
        moderationSamples,
        appliedModeration.isActive ? appliedModeration : (suggestedModeration ?? Moderation.none),
      );

  /// How many questions the teacher has marked on this paper's scripts.
  int get moderationSampleCount => moderationSamples.values
      .fold<int>(0, (int sum, List<ModerationSample> s) => sum + s.length);

  /// A class whose marks are higher than real classes get, with nothing
  /// moderating them.
  bool get classMarksLookHigh {
    final List<double> percentages = <double>[
      for (final MarkedScript script in scriptList)
        if (script.finalPercentage case final double p) p,
    ];
    if (percentages.length < 3 || appliedModeration.isActive) return false;
    final double average = percentages.reduce((double a, double b) => a + b) / percentages.length;
    return average > Moderation.classHighAverage;
  }

  // --------------------------------------------------------------------------
  // Moderation
  // --------------------------------------------------------------------------

  @override
  Future<void> loadModeration() async {
    moderationSamples = <String, List<ModerationSample>>{};
    appliedModeration = Moderation.none;
    final SelectedDocument? paper = chosenPaper;
    if (paper == null) return;
    try {
      final JsonMap? saved = await TeacherWorkStore(pipelineOf().store).moderation(paper.contentHash);
      if (saved == null) return;
      appliedModeration = Moderation.fromJson(saved['applied']);
      final JsonMap samples = readMap(saved['samples']) ?? const <String, Object?>{};
      moderationSamples = <String, List<ModerationSample>>{
        for (final MapEntry<String, Object?> entry in samples.entries)
          entry.key: readObjects(entry.value, ModerationSample.fromJson),
      };
    } on IOException {
      // Moderation is the teacher's own record; without it marks stand as marked.
    }
  }

  Future<void> _saveModeration() async {
    final SelectedDocument? paper = chosenPaper;
    if (paper == null) return;
    try {
      await TeacherWorkStore(pipelineOf().store).saveModeration(paper.contentHash, <String, Object?>{
        'applied': appliedModeration.toJson(),
        'samples': <String, Object?>{
          for (final MapEntry<String, List<ModerationSample>> entry in moderationSamples.entries)
            entry.key: <JsonMap>[for (final ModerationSample s in entry.value) s.toJson()],
        },
      });
    } on IOException catch (error) {
      fail('Moderation could not be saved.', '$error');
    }
  }

  /// Each question the teacher accepted or changed on [script], beside the
  /// AI's mark before moderation.
  @override
  Future<void> recordSamples(MarkedScript script) async {
    final CorrectionResult? marked = script.result;
    if (marked == null) return;
    final List<ModerationSample> samples = <ModerationSample>[
      for (final QuestionResult q in marked.questions)
        if (script.reviews[q.questionId] case final TeacherReview review when q.counted)
          ModerationSample(
            questionId: q.questionId,
            ai: q.moderatedFrom ?? q.awardedMarks,
            teacher: review.isOverride ? review.teacherMarks! : review.aiMarks,
            maximum: q.maximumMarks,
            section: q.section,
          ),
    ];
    final String hash = script.document.contentHash;
    if (samples.isEmpty) {
      moderationSamples.remove(hash);
    } else {
      moderationSamples[hash] = samples;
    }
    await _saveModeration();
  }

  /// Brings every script's marks to the teacher's own marking, as their
  /// marks so far suggest — instantly, from the cache.
  Future<void> applyModeration() async {
    final Moderation? suggested = suggestedModeration;
    if (isBusy || suggested == null) return;
    appliedModeration = suggested;
    await _saveModeration();
    await rerunFromCache('Moderated to your marking ${suggested.factors} (${suggested.basis}).');
  }

  /// Marks as the AI and the standard make them, unmoderated.
  Future<void> removeModeration() async {
    if (isBusy || !appliedModeration.isActive) return;
    appliedModeration = Moderation.none;
    await _saveModeration();
    await rerunFromCache('Moderation removed — marks are as the AI and the standard make them.');
  }
}
