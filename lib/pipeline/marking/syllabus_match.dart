import 'package:exam_corrector/pipeline/syllabus/syllabus_index.dart';

/// How much of what the syllabus teaches for a question an answer covers —
/// measured locally, by the terms they share, spending no requests.
class SyllabusMatch {
  const SyllabusMatch({
    this.matched = const <String>[],
    this.missing = const <String>[],
  });

  /// Nothing to measure against.
  static const SyllabusMatch none = SyllabusMatch();

  /// The reference's terms the answer uses.
  final List<String> matched;

  /// The reference's terms it does not.
  final List<String> missing;

  int get total => matched.length + missing.length;

  bool get isEmpty => total == 0;

  /// 0..1; 0 when there is nothing to measure against.
  double get coverage => total == 0 ? 0 : matched.length / total;

  /// Too few terms to judge by: a coverage of 2 of 2 says little.
  static const int minimumTerms = 3;

  /// [reference] is the syllabus topics the question touches, with the
  /// paper's mark scheme for it when there is one.
  static SyllabusMatch of(String answer, String reference) {
    final Set<String> terms = syllabusKeywords(reference);
    if (terms.length < minimumTerms) return none;
    final Set<String> used = syllabusKeywords(answer);
    final List<String> sorted = terms.toList()..sort();
    return SyllabusMatch(
      matched: <String>[for (final String term in sorted) if (used.contains(term)) term],
      missing: <String>[for (final String term in sorted) if (!used.contains(term)) term],
    );
  }
}
