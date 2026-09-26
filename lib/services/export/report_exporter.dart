import 'dart:convert';

import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/models/section_totals.dart';

/// One student's line in a class report.
class ClassReportRow {
  const ClassReportRow({
    required this.fileName,
    required this.result,
    required this.reviews,
    this.paper,
  });

  final String fileName;

  /// Null when the script has not been marked.
  final CorrectionResult? result;
  final TeacherReviewBook reviews;

  /// The question paper it was marked against, for its sections.
  final QuestionPaper? paper;

  List<SectionTotal> get sections {
    final CorrectionResult? marked = result;
    final QuestionPaper? against = paper;
    if (marked == null || against == null) return const <SectionTotal>[];
    return SectionTotal.of(marked, reviews, against);
  }
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

  /// The class as a gradebook: one row per student, one column per question
  /// and per section, the marks that count — the teacher's wherever they
  /// changed one.
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

    // The whole class sits one paper: its sections come from any marked row.
    final List<SectionTotal> template = rows
            .map((ClassReportRow row) => row.sections)
            .where((List<SectionTotal> sections) => sections.isNotEmpty)
            .firstOrNull ??
        const <SectionTotal>[];
    final List<String?> sectionIds = <String?>[for (final SectionTotal t in template) t.sectionId];
    String sectionCell(ClassReportRow row, String? id) =>
        switch (row.sections.where((SectionTotal t) => t.sectionId == id).firstOrNull) {
          final SectionTotal t => formatMarks(t.awarded),
          null => '',
        };

    final StringBuffer out = StringBuffer()
      ..writeln(<String>[
        'Student',
        for (final String id in ids) headings[id]!,
        for (final SectionTotal t in template)
          t.sectionId == null ? 'Other questions' : 'Section ${t.sectionId} (/${formatMarks(t.maximum)})',
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
          for (int i = 0; i < sectionIds.length; i++) '',
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
        for (final String? id in sectionIds) sectionCell(row, id),
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
        'Adjustments',
        'Syllabus badge',
      ].map(_cell).join(','));

    void question(QuestionResult q) {
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
        q.adjustments.join(' | '),
        switch (q.syllabusAward) {
          final SyllabusAward a when a.hasBadge =>
            '${a.badge.label} (${a.percent}%)${a.bonus > 0 ? ' +${formatMarks(a.bonus)}' : ''}',
          _ => '',
        },
      ].map(_cell).join(','));
    }

    final List<SectionTotal> sections =
        SectionTotal.of(result, reviews, assessment.questionPaper);
    if (sections.isEmpty) {
      result.questions.forEach(question);
    } else {
      // Each section's questions, then its subtotal.
      for (final SectionTotal section in sections) {
        for (final String id in section.questionIds) {
          if (result.question(id) case final QuestionResult q) question(q);
        }
        out.writeln(<String>[
          assessment.answerSheet.fileName,
          'SUBTOTAL',
          section.sectionId ?? '',
          formatMarks(section.maximum),
          formatMarks(section.aiAwarded),
          '',
          formatMarks(section.awarded),
          '',
          '',
          '',
          '',
          '',
          section.title,
          '',
          '',
        ].map(_cell).join(','));
      }
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
      result.standard.isEmpty ? '' : 'Marked to: ${result.standard}',
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
      'sections': <Object?>[
        for (final SectionTotal section
            in SectionTotal.of(result, reviews, assessment.questionPaper))
          <String, Object?>{
            'id': section.sectionId,
            'title': section.title,
            'awarded': section.awarded,
            'aiAwarded': section.aiAwarded,
            'maximum': section.maximum,
            'questions': section.questionIds,
          },
      ],
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
    final List<SectionTotal> sections =
        SectionTotal.of(result, reviews, assessment.questionPaper);
    final Map<String, SectionTotal> opens = <String, SectionTotal>{
      for (final SectionTotal section in sections)
        if (section.questionIds.isNotEmpty) section.questionIds.first: section,
    };
    for (final QuestionResult q in result.questions) {
      if (opens[q.questionId] case final SectionTotal section) {
        rows.writeln('<tr class="section"><td colspan="4">${e(section.title)}</td>'
            '<td class="n">${formatMarks(section.awarded)} / ${formatMarks(section.maximum)}</td></tr>');
      }
      final TeacherReview? review = reviews[q.questionId];
      final bool overridden = review?.isOverride ?? false;
      final SyllabusAward? award = q.syllabusAward;
      final String badge = award == null || !award.hasBadge
          ? ''
          : ' <span class="tag gold">★ ${e(award.badge.label)}${award.bonus > 0 ? ' +${formatMarks(award.bonus)}' : ''}</span>';
      rows.writeln('<tr>'
          '<td>${e(q.questionNumber)}</td>'
          '<td class="n">${formatMarks(reviews.finalMarks(q))} / ${formatMarks(q.maximumMarks)}</td>'
          '<td class="n">${formatMarks(q.awardedMarks)}'
          '$badge'
          '${overridden ? ' <span class="tag">changed by teacher</span>' : ''}</td>'
          '<td class="n">${(q.confidence * 100).round()}%${q.needsReview ? ' <span class="tag">review</span>' : ''}</td>'
          '<td>${q.counted ? '' : '<p><span class="tag">not counted</span> ${e(q.choiceNote)}</p>'}${e(q.evaluation)}'
          '${q.adjustments.isEmpty ? '' : '<p class="comment">${q.adjustments.map(e).join('<br>')}</p>'}'
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
.gold{background:#fff3cc;color:#b07d00;font-weight:600}
.comment{color:#0067c0;margin:6px 0 0}.total{font-size:18px;margin-top:16px}
tr.section td{background:#f0f6fc;font-weight:600}p.sections{color:#5d5d5d;margin:4px 0 0}
</style></head><body>
<h1>${e(assessment.answerSheet.fileName)}</h1>
<p class="meta">Marked against ${e(assessment.questionPaper.title.isEmpty ? 'the question paper' : assessment.questionPaper.title)} · ${now.toLocal().toString().substring(0, 16)} · ${e(result.model)}${result.standard.isEmpty ? '' : ' · marked to ${e(result.standard)}'}</p>
<table><thead><tr><th>Question</th><th>Final</th><th>AI mark</th><th>AI confidence</th><th>Reasoning</th></tr></thead>
<tbody>
$rows</tbody></table>
<p class="total"><strong>Total: ${formatMarks(reviews.finalTotal(result))} / ${formatMarks(result.maximumTotalMarks)} (${formatPercentage(reviews.finalPercentage(result))})</strong>${reviews.overrideCount > 0 ? ' — ${reviews.overrideCount} mark(s) changed by the teacher; AI total ${formatMarks(result.totalMarks)}' : ''}</p>
${sections.isEmpty ? '' : '<p class="sections">${sections.map((SectionTotal t) => '${e(t.title)}: ${formatMarks(t.awarded)} / ${formatMarks(t.maximum)}').join(' · ')}</p>'}
</body></html>
''';
  }
}
