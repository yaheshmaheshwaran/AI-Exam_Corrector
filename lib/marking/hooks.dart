import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/marking/contracts.dart';

/// A step that may add to what the marker is told, just before marking.
///
/// The extension point for features that sit beside the pipeline rather than
/// in it — the memory of a teacher's past corrections, first. A hook returns
/// the tasks with whatever it adds; it must never take anything away, and it
/// must never give the marker a mark to copy.
abstract class MarkingHook {
  /// Changes whenever what the hook adds would change, so marks given with
  /// its additions are cached apart from marks given without them.
  String get fingerprint;

  Future<List<MarkingTask>> beforeMarking(List<MarkingTask> tasks, ExamAssessment assessment);
}
