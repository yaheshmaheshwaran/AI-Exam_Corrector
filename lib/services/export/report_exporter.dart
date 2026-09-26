import 'dart:convert';

import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';

/// One student's line in a class report.
class ClassReportRow {
  const ClassReportRow({
    required this.fileName,
    required this.result,
    required this.reviews,
  });

  final String fileName;

  /// Null when the script has not been marked.
  final CorrectionResult? result;
  final TeacherReviewBook reviews;
}

enum ReportFormat {
  csv('CSV — for a gradebook', 'csv'),
  html('HTML — a printable report', 'html'),
  json('JSON — the full record, with evidence', 'json');

  const ReportFormat(this.label, this.extension);

  final String label;
  final String extension;
}

/// Writes a marked paper out as a report.
///
/// Every format carries both marks for every question — the AI's and the
/// teacher's — and which one counts, so a report never hides that a mark was
/// changed. The JSON form also carries the evidence behind each mark.
class ReportExporter {
  const ReportExporter();

  String export(
    ExamAssessment assessment,
    TeacherReviewBook reviews,
    ReportFormat format, {
    DateTime? now,
  }) {
    final CorrectionResult? result = assessment.result;
    if (result == null) {
      throw StateError('The paper has not been marked yet.');
    }
    return switch (format) {
      ReportFormat.csv => _csv(assessment, result, reviews),
      ReportFormat.json => _json(assessment, result, reviews, now ?? DateTime.now()),
      ReportFormat.html => _html(assessment, result, reviews, now ?? DateTime.now()),
    };
  }

  /// The class as a gradebook: one row per student, one column per question,
  /// the marks that count — the teacher's wherever they changed one.
  String exportClass(List<ClassReportRow> rows) {
    final List<QuestionResult> columns = <QuestionResult>[
      for (final ClassReportRow row in rows)
        if (row.result != null) ...row.result!.questions,
    ];
    final List<String> ids = <String>[];
    final Map<String, String> headings = <String, String>{};
    for (final QuestionResult q in columns) {
      if (!ids.contains(q.questionId)) {
        ids.add(q.questionId);
        headings[q.questionId] = 'Q${q.questionNumber}';
      }
    }

    final StringBuffer out = StringBuffer()
      ..writeln(<String>[
        'Student',
        for (final String id in ids) headings[id]!,
        'Total',
        'Maximum',
        'Percentage',
        'To review',
        'Changed by teacher',
        'Status',
      ].map(_cell).join(','));

    for (final ClassReportRow row in rows) {
      final CorrectionResult? result = row.result;
      if (result == null) {
        out.writeln(<String>[
          row.fileName,
          for (int i = 0; i < ids.length; i++) '',
          '', '', '', '', '',
          'not marked',
        ].map(_cell).join(','));
        continue;
      }
      out.writeln(<String>[
        row.fileName,
        for (final String id in ids)
          switch (result.question(id)) {
            // The other option of an OR is not part of the grade.
            final QuestionResult q when q.counted => formatMarks(row.reviews.finalMarks(q)),
            _ => '',
          },
        formatMarks(row.reviews.finalTotal(result)),
        formatMarks(result.maximumTotalMarks),
        formatPercentage(row.reviews.finalPercentage(result)),
        '${row.reviews.outstanding(result)}',
        '${row.reviews.overrideCount}',
        'marked',
      ].map(_cell).join(','));
    }
    return out.toString();
  }

  String suggestedName(ExamAssessment assessment, ReportFormat format) {
    final String base = assessment.answerSheet.fileName
        .replaceAll(RegExp(r'\.[^.]+$'), '')
        .replaceAll(RegExp(r'[^\w\- ]'), '_');
    return '$base - marks.${format.extension}';
  }

  String _csv(ExamAssessment assessment, CorrectionResult result, TeacherReviewBook reviews) {
    final StringBuffer out = StringBuffer()
      ..writeln(<String>[
        'Student',
        'Question',
        'Section',
        'Maximum',
        'AI mark',
        'Teacher mark',
        'Final mark',
        'AI confidence',
        'Needs review',
        'Review status',
        'Teacher comment',
        'Answer pages',
        'Explanation',
        'Counted',
      ].map(_cell).join(','));

    for (final QuestionResult q in result.questions) {
      final TeacherReview? review = reviews[q.questionId];
      out.writeln(<String>[
        assessment.answerSheet.fileName,
        q.questionNumber,
        q.section ?? '',
        formatMarks(q.maximumMarks),
        formatMarks(q.awardedMarks),
        review?.isOverride ?? false ? formatMarks(review!.teacherMarks!) : '',
        formatMarks(reviews.finalMarks(q)),
        '${(q.confidence * 100).round()}%',
        q.needsReview ? 'yes' : 'no',
        (review?.status ?? ReviewStatus.pending).name,
        review?.comment ?? '',
        q.answerPages.join(' '),
        q.evaluation,
        q.counted ? 'yes' : 'no — ${q.choiceNote}',
      ].map(_cell).join(','));
    }

    out.writeln(<String>[
      assessment.answerSheet.fileName,
      'TOTAL',
      '',
      formatMarks(result.maximumTotalMarks),
      formatMarks(result.totalMarks),
      '',
      formatMarks(reviews.finalTotal(result)),
      '',
      '',
      '',
      '',
      '',
      formatPercentage(reviews.finalPercentage(result)),
      '',
    ].map(_cell).join(','));
    return out.toString();
  }

  static String _cell(String value) {
    final String escaped = value.replaceAll('"', '""').replaceAll('\n', ' ');
    return RegExp(r'[",\n]').hasMatch(value) || value.contains(',') ? '"$escaped"' : escaped;
  }

  String _json(
    ExamAssessment assessment,
    CorrectionResult result,
    TeacherReviewBook reviews,
    DateTime now,
  ) {
    String? locate(String regionId) {
      final PageRegion? region = assessment.region(regionId);
      return region == null ? null : 'page ${region.pageNumber}';
    }

    return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'generatedAt': now.toUtc().toIso8601String(),
      'student': assessment.answerSheet.fileName,
      'answerSheetId': assessment.answerSheet.documentId,
      'questionPaperId': assessment.questionPaper.documentId,
      'totalMarks': reviews.finalTotal(result),
      'aiTotalMarks': result.totalMarks,
      'maximumMarks': result.maximumTotalMarks,
      'percentage': reviews.finalPercentage(result),
      'models': result.model,
      'questions': <Object?>[
        for (final QuestionResult q in result.questions)
          <String, Object?>{
            ...q.toJson(),
            'finalMarks': reviews.finalMarks(q),
            'teacherReview': reviews[q.questionId]?.toJson(),
            'evidenceLocations': <String, String?>{
              for (final String id in q.evidenceRegionIds) id: locate(id),
            },
          },
      ],
      'warnings': assessment.warnings,
    });
  }

  String _html(
    ExamAssessment assessment,
    CorrectionResult result,
    TeacherReviewBook reviews,
    DateTime now,
  ) {
    String e(String text) => const HtmlEscape().convert(text);
    final StringBuffer rows = StringBuffer();
    for (final QuestionResult q in result.questions) {
      final TeacherReview? review = reviews[q.questionId];
      final bool overridden = review?.isOverride ?? false;
      rows.writeln('<tr>'
          '<td>${e(q.questionNumber)}</td>'
          '<td class="n">${formatMarks(reviews.finalMarks(q))} / ${formatMarks(q.maximumMarks)}</td>'
          '<td class="n">${formatMarks(q.awardedMarks)}${overridden ? ' <span class="tag">changed by teacher</span>' : ''}</td>'
          '<td class="n">${(q.confidence * 100).round()}%${q.needsReview ? ' <span class="tag">review</span>' : ''}</td>'
          '<td>${q.counted ? '' : '<p><span class="tag">not counted</span> ${e(q.choiceNote)}</p>'}${e(q.evaluation)}'
          '${q.markingPoints.isEmpty ? '' : '<ul>${q.markingPoints.map((MarkingPoint p) => '<li>${p.satisfied ? '✓' : '✗'} ${e(p.criterion)} (${formatMarks(p.marks)}/${formatMarks(p.marksAvailable)})${p.evidenceRegionIds.isEmpty ? '' : ' — page ${p.evidenceRegionIds.map((String id) => assessment.region(id)?.pageNumber ?? '?').toSet().join(', ')}'}</li>').join()}</ul>'}'
          '${review != null && review.comment.isNotEmpty ? '<p class="comment">Teacher: ${e(review.comment)}</p>' : ''}'
          '</td></tr>');
    }

    return '''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>${e(assessment.answerSheet.fileName)} — marks</title>
<style>
body{font-family:"Segoe UI",system-ui,sans-serif;color:#1b1b1b;margin:32px;max-width:1000px}
h1{font-size:20px;margin:0 0 4px}p.meta{color:#5d5d5d;margin:0 0 20px}
table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid #e5e5e5;padding:8px;text-align:left;vertical-align:top;font-size:13px}
th{background:#fafafa}td.n{white-space:nowrap}ul{margin:6px 0 0;padding-left:18px}
.tag{font-size:11px;background:#fff4ce;color:#9d5d00;border-radius:3px;padding:1px 5px}
.comment{color:#0067c0;margin:6px 0 0}.total{font-size:18px;margin-top:16px}
</style></head><body>
<h1>${e(assessment.answerSheet.fileName)}</h1>
<p class="meta">Marked against ${e(assessment.questionPaper.title.isEmpty ? 'the question paper' : assessment.questionPaper.title)} · ${now.toLocal().toString().substring(0, 16)} · ${e(result.model)}</p>
<table><thead><tr><th>Question</th><th>Final</th><th>AI mark</th><th>AI confidence</th><th>Reasoning</th></tr></thead>
<tbody>
$rows</tbody></table>
<p class="total"><strong>Total: ${formatMarks(reviews.finalTotal(result))} / ${formatMarks(result.maximumTotalMarks)} (${formatPercentage(reviews.finalPercentage(result))})</strong>${reviews.overrideCount > 0 ? ' — ${reviews.overrideCount} mark(s) changed by the teacher; AI total ${formatMarks(result.totalMarks)}' : ''}</p>
</body></html>
''';
  }
}
