import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/pipeline/recognition/text_similarity.dart';
import 'package:exam_corrector/pipeline/syllabus/syllabus_index.dart';

/// Which saved syllabus a question paper belongs to, and why.
class SyllabusMatch {
  const SyllabusMatch(this.syllabus, this.score, this.reason);

  final Syllabus syllabus;
  final double score;

  /// For the teacher: "course code CCS356 on the paper".
  final String reason;
}

/// Picks the saved syllabus a question paper was set from.
///
/// The course code printed on the paper settles it. Otherwise the paper's
/// title is compared with each course title, and its questions with each
/// syllabus's topics; the best only counts when it is clearly a match, so
/// an unrelated paper is marked without a syllabus rather than against the
/// wrong one.
class SyllabusMatcher {
  const SyllabusMatcher();

  static const double threshold = 0.3;

  SyllabusMatch? best(
    List<Syllabus> library, {
    required String title,
    required String text,
  }) {
    SyllabusMatch? best;
    for (final Syllabus syllabus in library) {
      final SyllabusMatch match = score(syllabus, title: title, text: text);
      if (best == null || match.score > best.score) best = match;
    }
    return best != null && best.score >= threshold ? best : null;
  }

  SyllabusMatch score(Syllabus syllabus, {required String title, required String text}) {
    final String code = syllabus.courseCode.replaceAll(' ', '').toUpperCase();
    final String everything = '$title\n$text';
    if (code.length >= 4 &&
        everything.toUpperCase().replaceAll(RegExp(r'\s'), '').contains(code)) {
      return SyllabusMatch(syllabus, 1, 'course code $code on the paper');
    }

    // The course title against the paper's title, or its opening lines.
    final String heading = title.trim().isNotEmpty
        ? title
        : everything.split('\n').take(12).join(' ');
    final Set<String> courseWords = syllabusKeywords(syllabus.courseTitle);
    final Set<String> headingWords = syllabusKeywords(heading);
    final double titleOverlap = courseWords.isEmpty
        ? 0
        : courseWords.intersection(headingWords).length / courseWords.length;
    final double titleSimilarity = title.trim().isEmpty
        ? 0
        : textSimilarity(title.toLowerCase(), syllabus.courseTitle.toLowerCase());
    final double titleScore = titleOverlap > titleSimilarity ? titleOverlap : titleSimilarity;

    // The questions' words against the syllabus's topics.
    final Set<String> vocabulary = <String>{
      for (final SyllabusUnit unit in syllabus.units) ...<String>{
        ...syllabusKeywords(unit.title),
        for (final String topic in unit.topics) ...syllabusKeywords(topic),
      },
    };
    final Set<String> asked = syllabusKeywords(text);
    final double topical =
        asked.length < 5 ? 0 : asked.intersection(vocabulary).length / asked.length;

    final double total = 0.65 * titleScore + 0.35 * (topical * 2).clamp(0.0, 1.0);
    return SyllabusMatch(
      syllabus,
      total,
      titleScore >= 0.6 ? 'course title' : 'topics the questions cover',
    );
  }
}
