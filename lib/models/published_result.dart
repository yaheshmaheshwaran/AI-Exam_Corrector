import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/models/section_totals.dart';

/// Where part of an answer is written: a box on one page, in fractions of
/// the page.
class AnswerBox {
  const AnswerBox({required this.page, required this.x, required this.y, required this.width, required this.height});

  final int page;
  final double x;
  final double y;
  final double width;
  final double height;

  JsonMap toJson() => <String, Object?>{'page': page, 'x': x, 'y': y, 'w': width, 'h': height};

  static AnswerBox? fromJson(JsonMap json) {
    final int? page = readInt(json['page']);
    if (page == null) return null;
    return AnswerBox(
      page: page,
      x: readDouble(json['x']) ?? 0,
      y: readDouble(json['y']) ?? 0,
      width: readDouble(json['w']) ?? 0,
      height: readDouble(json['h']) ?? 0,
    );
  }
}

/// One page of the student's answer sheet, kept with the published result.
class PublishedPage {
  const PublishedPage({required this.number, required this.imagePath, required this.width, required this.height});

  final int number;

  /// The page image, kept outside the cache so it outlives it.
  final String imagePath;
  final int width;
  final int height;

  JsonMap toJson() => <String, Object?>{'number': number, 'imagePath': imagePath, 'width': width, 'height': height};

  static PublishedPage? fromJson(JsonMap json) {
    final int? number = readInt(json['number']);
    final String? path = readRawString(json['imagePath']);
    if (number == null || path == null) return null;
    return PublishedPage(
      number: number,
      imagePath: path,
      width: readInt(json['width']) ?? 1000,
      height: readInt(json['height']) ?? 1400,
    );
  }
}

/// One question as the student sees it: the mark that counts and why.
class PublishedQuestion {
  const PublishedQuestion({
    required this.number,
    required this.marks,
    required this.maximum,
    this.questionId = '',
    this.aiMarks,
    this.section,
    this.explanation = '',
    this.comment = '',
    this.counted = true,
    this.questionText = '',
    this.answerText = '',
    this.answerBoxes = const <AnswerBox>[],
    this.badge = SyllabusBadge.none,
    this.bonus = 0,
  });

  final String number;

  /// The syllabus badge the answer earned, and the bonus mark that came
  /// with it (already inside [marks]).
  final SyllabusBadge badge;
  final double bonus;

  /// What the paper asked.
  final String questionText;

  /// The answer as it was read, with the teacher's corrections to the
  /// reading.
  final String answerText;

  /// Where the answer is written, page by page.
  final List<AnswerBox> answerBoxes;

  /// The pages the answer is on, in order.
  List<int> get answerPages => <int>{for (final AnswerBox b in answerBoxes) b.page}.toList()..sort();

  /// As the paper knows it: `Q3`, `Q11a`.
  final String questionId;
  final String? section;

  /// The AI's mark, when the teacher's differs.
  final double? aiMarks;

  /// The final mark — the teacher's wherever they changed the AI's.
  final double marks;
  final double maximum;
  final String explanation;

  /// The teacher's own comment, when they wrote one.
  final String comment;

  /// False for the alternative of an OR that does not count.
  final bool counted;

  PublishedQuestion copyWith({double? marks, String? comment}) => PublishedQuestion(
        number: number,
        questionId: questionId,
        section: section,
        marks: marks ?? this.marks,
        maximum: maximum,
        aiMarks: aiMarks,
        explanation: explanation,
        comment: comment ?? this.comment,
        counted: counted,
        questionText: questionText,
        answerText: answerText,
        answerBoxes: answerBoxes,
        badge: badge,
        bonus: bonus,
      );

  JsonMap toJson() => <String, Object?>{
        'number': number,
        if (badge != SyllabusBadge.none) 'badge': badge.name,
        if (bonus > 0) 'bonus': bonus,
        'questionId': questionId,
        'section': ?section,
        'aiMarks': ?aiMarks,
        'marks': marks,
        'maximum': maximum,
        'explanation': explanation,
        if (comment.isNotEmpty) 'comment': comment,
        if (!counted) 'counted': false,
        if (questionText.isNotEmpty) 'questionText': questionText,
        if (answerText.isNotEmpty) 'answerText': answerText,
        if (answerBoxes.isNotEmpty) 'answerBoxes': <JsonMap>[for (final AnswerBox b in answerBoxes) b.toJson()],
      };

  static PublishedQuestion? fromJson(JsonMap json) {
    final String? number = readString(json['number']);
    if (number == null) return null;
    return PublishedQuestion(
      number: number,
      questionId: readString(json['questionId']) ?? 'Q$number',
      section: readString(json['section']),
      aiMarks: readDouble(json['aiMarks']),
      marks: readDouble(json['marks']) ?? 0,
      maximum: readDouble(json['maximum']) ?? 0,
      explanation: readRawString(json['explanation']) ?? '',
      comment: readRawString(json['comment']) ?? '',
      counted: readBool(json['counted']) ?? true,
      questionText: readRawString(json['questionText']) ?? '',
      answerText: readRawString(json['answerText']) ?? '',
      answerBoxes: readObjects(json['answerBoxes'], AnswerBox.fromJson),
      badge: readEnum(SyllabusBadge.values, json['badge'], SyllabusBadge.none),
      bonus: readDouble(json['bonus']) ?? 0,
    );
  }
}

/// A section's marks, as the student sees them.
class PublishedSection {
  const PublishedSection({
    required this.title,
    required this.marks,
    required this.maximum,
    this.sectionId,
  });

  /// As the paper prints it: `A`; null for questions in no section.
  final String? sectionId;
  final String title;
  final double marks;
  final double maximum;

  JsonMap toJson() => <String, Object?>{
        'sectionId': ?sectionId,
        'title': title,
        'marks': marks,
        'maximum': maximum,
      };

  static PublishedSection? fromJson(JsonMap json) {
    final String? title = readRawString(json['title']);
    if (title == null) return null;
    return PublishedSection(
      sectionId: readString(json['sectionId']),
      title: title,
      marks: readDouble(json['marks']) ?? 0,
      maximum: readDouble(json['maximum']) ?? 0,
    );
  }
}

/// A student's marked script as the teacher published it: final marks only,
/// with the teacher's changes applied — nothing a student should not see, and
/// no evidence images.
class PublishedResult {
  const PublishedResult({
    required this.id,
    required this.student,
    required this.paperTitle,
    required this.fileName,
    required this.publishedAt,
    required this.total,
    required this.maximum,
    required this.percentage,
    this.rollNo = '',
    this.subjectCode = '',
    this.exam = '',
    this.totalRounding = TotalRounding.none,
    this.paperHash = '',
    this.scriptHash = '',
    this.standard = '',
    this.sections = const <PublishedSection>[],
    this.questions = const <PublishedQuestion>[],
    this.pages = const <PublishedPage>[],
    this.firstSeenAt,
    this.lastSeenAt,
    this.seenCount = 0,
    this.verifiedAt,
  });

  /// When the student first and last opened it; null until they have.
  final DateTime? firstSeenAt;
  final DateTime? lastSeenAt;
  final int seenCount;

  /// When the student confirmed they agree with the marks; null until then.
  final DateTime? verifiedAt;

  bool get isSeen => firstSeenAt != null;
  bool get isVerified => verifiedAt != null;

  /// The student's answer sheet, page by page; empty when it was not kept.
  final List<PublishedPage> pages;

  /// Its key in the results database.
  final String id;

  /// Who it belongs to: what the student signs in with.
  final String rollNo;

  /// The subject, as the college codes it: `CCS356`.
  final String subjectCode;

  /// Which exam: "CAT 1", "Model exam".
  final String exam;

  /// How the college rounds the total, so it can be worked out again when a
  /// mark changes.
  final TotalRounding totalRounding;
  final String paperHash;
  final String scriptHash;

  /// The student's name, when the teacher gave one.
  final String student;
  final String paperTitle;

  /// The answer sheet it came from.
  final String fileName;
  final DateTime publishedAt;
  final double total;
  final double maximum;
  final double percentage;

  /// The marking standard, in one line.
  final String standard;
  final List<PublishedSection> sections;
  final List<PublishedQuestion> questions;

  /// Built from a marked script, with the teacher's reviews applied.
  static PublishedResult of(
    ExamAssessment assessment,
    TeacherReviewBook reviews, {
    required String student,
    String rollNo = '',
    String subjectCode = '',
    String exam = '',
    DateTime? now,
  }) {
    final CorrectionResult result = assessment.result!;
    final String title = assessment.questionPaper.title.trim();
    return PublishedResult(
      id: '${assessment.answerSheet.documentId}_${assessment.questionPaper.documentId}',
      rollNo: normaliseRoll(rollNo),
      subjectCode: normaliseRoll(subjectCode),
      exam: exam.trim(),
      student: student.trim(),
      paperTitle: title.isEmpty ? 'Question paper' : title,
      fileName: assessment.answerSheet.fileName,
      publishedAt: now ?? DateTime.now(),
      total: reviews.finalTotal(result),
      maximum: result.maximumTotalMarks,
      percentage: reviews.finalPercentage(result),
      totalRounding: result.totalRounding,
      paperHash: assessment.questionPaper.documentId,
      scriptHash: assessment.answerSheet.documentId,
      standard: result.standard,
      sections: <PublishedSection>[
        for (final SectionTotal section in SectionTotal.of(result, reviews, assessment.questionPaper))
          PublishedSection(
            sectionId: section.sectionId,
            title: section.title,
            marks: section.awarded,
            maximum: section.maximum,
          ),
      ],
      questions: <PublishedQuestion>[
        for (final QuestionResult q in result.questions)
          PublishedQuestion(
            number: q.questionNumber,
            questionId: q.questionId,
            section: q.section,
            marks: reviews.finalMarks(q),
            maximum: q.maximumMarks,
            aiMarks: (reviews.finalMarks(q) - q.awardedMarks).abs() > 1e-9 ? q.awardedMarks : null,
            explanation: q.evaluation,
            comment: reviews[q.questionId]?.comment ?? '',
            counted: q.counted,
            badge: q.syllabusBadge,
            bonus: q.syllabusAward?.bonus ?? 0,
            questionText: assessment.questionPaper.byId(q.questionId)?.questionText ?? q.questionText,
            answerText: assessment.answers[q.questionId]?.text ?? '',
            answerBoxes: <AnswerBox>[
              for (final String id in assessment.answers[q.questionId]?.regionIds ?? const <String>[])
                if (assessment.region(id) case final PageRegion region)
                  AnswerBox(
                    page: region.pageNumber,
                    x: region.box.x,
                    y: region.box.y,
                    width: region.box.width,
                    height: region.box.height,
                  ),
            ],
          ),
      ],
      // The page images as rendered; the repository copies them out of the
      // cache when it saves the result.
      pages: <PublishedPage>[
        for (final ExamPage page in assessment.answerSheet.pages)
          if (!page.isBlank && (page.previewImagePath ?? page.imagePath) != null)
            PublishedPage(
              number: page.pageNumber,
              imagePath: (page.previewImagePath ?? page.imagePath)!,
              width: page.width,
              height: page.height,
            ),
      ],
    );
  }

  /// A roll number or subject code as stored: capitals, no spaces —
  /// "21 cs 045" is `21CS045`.
  static String normaliseRoll(String text) => text.toUpperCase().replaceAll(RegExp(r'\s+'), '');

  /// A roll number found in a file name: `21CS045_answers.pdf` → `21CS045`.
  /// Null when nothing looks like one, so the teacher enters it.
  static String? rollFromFileName(String fileName) {
    final String stem = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    final RegExpMatch? coded =
        RegExp(r'(?<![A-Za-z0-9])(\d{2,4}[A-Za-z]{2,4}\d{2,4})(?![A-Za-z0-9])').firstMatch(stem);
    if (coded != null) return coded.group(1)!.toUpperCase();
    final RegExpMatch? digits = RegExp(r'(?<!\d)(\d{6,})(?!\d)').firstMatch(stem);
    return digits?.group(1);
  }

  /// This result with one question's mark changed — by an accepted
  /// correction — and every total worked out again: OR alternatives that do
  /// not count stay out, and the college's rounding applies.
  PublishedResult withMark(String questionId, double marks, {String? comment}) {
    final List<PublishedQuestion> changed = <PublishedQuestion>[
      for (final PublishedQuestion q in questions)
        q.questionId == questionId ? q.copyWith(marks: marks, comment: comment) : q,
    ];
    final Iterable<PublishedQuestion> counted = changed.where((PublishedQuestion q) => q.counted);
    final double total = totalRounding.apply(
      counted.fold<double>(0, (double sum, PublishedQuestion q) => sum + q.marks),
    );
    return PublishedResult(
      id: id,
      rollNo: rollNo,
      subjectCode: subjectCode,
      exam: exam,
      student: student,
      paperTitle: paperTitle,
      fileName: fileName,
      publishedAt: publishedAt,
      total: total,
      maximum: maximum,
      percentage: maximum > 0 ? total / maximum * 100 : 0,
      totalRounding: totalRounding,
      paperHash: paperHash,
      scriptHash: scriptHash,
      standard: standard,
      sections: <PublishedSection>[
        for (final PublishedSection s in sections)
          PublishedSection(
            sectionId: s.sectionId,
            title: s.title,
            maximum: s.maximum,
            marks: counted
                .where((PublishedQuestion q) => q.section == s.sectionId)
                .fold<double>(0, (double sum, PublishedQuestion q) => sum + q.marks),
          ),
      ],
      questions: changed,
      pages: pages,
    );
  }

  /// The name, without case, spaces or punctuation — how lookups compare.
  static String normalise(String text) => text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Whether a student typing [query] means this result: their name or roll
  /// number, found in the published name or the answer sheet's file name.
  bool matches(String query) {
    final String wanted = normalise(query);
    if (wanted.length < 2) return false;
    return normalise(student).contains(wanted) ||
        normalise(fileName.replaceAll(RegExp(r'\.[^.]+$'), '')).contains(wanted);
  }

  JsonMap toJson() => <String, Object?>{
        'id': id,
        'rollNo': rollNo,
        'subjectCode': subjectCode,
        'exam': exam,
        if (totalRounding != TotalRounding.none) 'totalRounding': totalRounding.name,
        'paperHash': paperHash,
        'scriptHash': scriptHash,
        'student': student,
        'paperTitle': paperTitle,
        'fileName': fileName,
        'publishedAt': publishedAt.toUtc().toIso8601String(),
        'total': total,
        'maximum': maximum,
        'percentage': percentage,
        if (standard.isNotEmpty) 'standard': standard,
        'sections': <JsonMap>[for (final PublishedSection s in sections) s.toJson()],
        'questions': <JsonMap>[for (final PublishedQuestion q in questions) q.toJson()],
        if (pages.isNotEmpty) 'pages': <JsonMap>[for (final PublishedPage p in pages) p.toJson()],
      };

  static PublishedResult? fromJson(JsonMap json) {
    final String? id = readString(json['id']);
    if (id == null) return null;
    return PublishedResult(
      id: id,
      rollNo: readRawString(json['rollNo']) ?? '',
      subjectCode: readRawString(json['subjectCode']) ?? '',
      exam: readRawString(json['exam']) ?? '',
      totalRounding: readEnum(TotalRounding.values, json['totalRounding'], TotalRounding.none),
      paperHash: readRawString(json['paperHash']) ?? '',
      scriptHash: readRawString(json['scriptHash']) ?? '',
      student: readRawString(json['student']) ?? '',
      paperTitle: readRawString(json['paperTitle']) ?? 'Question paper',
      fileName: readRawString(json['fileName']) ?? '',
      publishedAt: DateTime.tryParse(readString(json['publishedAt']) ?? '')?.toLocal() ?? DateTime(2000),
      total: readDouble(json['total']) ?? 0,
      maximum: readDouble(json['maximum']) ?? 0,
      percentage: readDouble(json['percentage']) ?? 0,
      standard: readRawString(json['standard']) ?? '',
      sections: readObjects(json['sections'], PublishedSection.fromJson),
      questions: readObjects(json['questions'], PublishedQuestion.fromJson),
      pages: readObjects(json['pages'], PublishedPage.fromJson),
    );
  }
}
