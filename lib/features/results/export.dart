import 'dart:async';


import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/services/export/report_exporter.dart';
import 'package:exam_corrector/state/marked_script.dart';
import 'package:exam_corrector/features/workspace.dart';

/// Reports and gradebooks, saved where the teacher chooses.
mixin ExportFeature on Workspace {
  // --------------------------------------------------------------------------
  // Export
  // --------------------------------------------------------------------------

  /// Writes the current script's marks out; returns the saved path, or null.
  Future<String?> exportReport(ReportFormat format) async {
    final ExamAssessment? marked = assessment;
    if (marked == null || marked.result == null) return null;

    final String? path = await picker.pickSaveLocation(
      suggestedName: reportExporter.suggestedName(marked, format),
      extension: format.extension,
    );
    if (path == null) return null;
    return writeFile(path, reportExporter.export(marked, reviews, format));
  }

  /// Writes the whole class's marks as one CSV for a gradebook.
  Future<String?> exportClass() async {
    final List<ClassReportRow> rows = <ClassReportRow>[
      for (final MarkedScript script in scriptList)
        ClassReportRow(
          fileName: script.document.fileName,
          result: script.result,
          reviews: script.reviews,
          paper: script.assessment?.questionPaper,
          elapsed: script.result == null ? null : script.assessment?.job.elapsed,
        ),
    ];
    if (rows.every((ClassReportRow row) => row.result == null)) return null;

    final String? path = await picker.pickSaveLocation(
      suggestedName: 'class marks.csv',
      extension: 'csv',
    );
    if (path == null) return null;
    return writeFile(path, reportExporter.exportClass(rows));
  }

}
