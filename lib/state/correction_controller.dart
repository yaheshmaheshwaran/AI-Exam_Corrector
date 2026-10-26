import 'dart:async';

import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/features/workspace.dart';
import 'package:exam_corrector/features/exam_setup/inputs.dart';
import 'package:exam_corrector/features/exam_setup/answer_key.dart';
import 'package:exam_corrector/features/syllabus/syllabus.dart';
import 'package:exam_corrector/features/accounts/publishing.dart';
import 'package:exam_corrector/features/marking_style/standard.dart';
import 'package:exam_corrector/features/marking_style/moderation.dart';
import 'package:exam_corrector/features/marking_run/marking_run.dart';
import 'package:exam_corrector/features/results/review.dart';
import 'package:exam_corrector/features/results/export.dart';
import 'package:exam_corrector/features/settings/settings.dart';

export 'package:exam_corrector/state/marked_script.dart';

/// Owns the workflow: student scripts — one, or a class set — a question
/// paper and optional guidance in; understood and marked scripts out; then
/// the teacher's review.
///
/// Holds no marking logic of its own. It is the shared [Workspace] with every
/// feature mixed in; each feature lives in its own file under `lib/features/`.
class CorrectionController extends Workspace
    with
        InputsFeature,
        AnswerKeyFeature,
        SyllabusFeature,
        PublishingFeature,
        StandardFeature,
        ModerationFeature,
        MarkingRunFeature,
        ReviewFeature,
        ExportFeature,
        SettingsFeature {
  CorrectionController({
    required super.config,
    required super.ai,
    required super.pipeline,
    super.inspector,
    super.filePicker,
    super.settings,
    super.pdfService,
    super.keyReader,
    super.exporter,
    super.syllabusLibrary,
    super.usage,
    super.health,
    super.standards,
    super.results,
    super.modelCheck,
    super.aiLoader,
    super.clock,
    super.signals,
  }) {
    if (syllabusStore != null) unawaited(reloadSyllabi());
  }
}

/// Convenience for widgets: a question's region pages, for the evidence list.
extension RegionPages on ExamAssessment {
  List<int> pagesOf(Iterable<String> regionIds) => <int>{
        for (final String id in regionIds)
          if (region(id) case final region?) region.pageNumber,
      }.toList()
        ..sort();
}
