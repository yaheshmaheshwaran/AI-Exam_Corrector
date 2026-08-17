/// Optional marking notes the teacher typed alongside the question paper.
///
/// Supplementary by design. The question paper is what establishes the
/// questions, their sections and their marks; this only fills gaps the paper
/// leaves — a question with no printed mark allocation, or how marks should be
/// divided within one. Where the paper states something, the paper wins.
///
/// Being empty is the normal case, not a missing input.
class MarkingGuidance {
  const MarkingGuidance(this.text);

  const MarkingGuidance.none() : text = '';

  final String text;

  String get trimmed => text.trim();

  bool get isEmpty => trimmed.isEmpty;

  bool get isNotEmpty => !isEmpty;
}
