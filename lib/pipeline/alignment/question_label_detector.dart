import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/recognition/text_similarity.dart';

/// A question label found on the answer sheet.
class DetectedLabel {
  const DetectedLabel({
    required this.label,
    required this.observed,
    required this.confidence,
    required this.inPaper,
    this.explicit = false,
    this.continuation = false,
    this.echoes = false,
    this.numbered = false,
  });

  final QuestionLabel label;

  /// The text of the label as written.
  final String observed;

  /// How sure the detector is that this really is a label, 0..1 — before the
  /// recogniser's own confidence in the characters is taken into account.
  final double confidence;

  /// The paper has a question with this label.
  final bool inPaper;

  /// Written with a `Q` or `Question` prefix — unmistakably a label even
  /// when the paper has no such question. `Answer:` is deliberately not a
  /// prefix: "Answer: 50 micrometres…" is an answer that starts with a
  /// number, far more often than it is a label.
  final bool explicit;

  /// Marked as continuing an earlier answer: `Q3 continued`, `3 (cont.)`.
  final bool continuation;

  /// The wording after the label is the question's own, as in an answer
  /// booklet that reprints each question.
  final bool echoes;

  /// Starts with a question number, rather than being a bare part like
  /// `(b)`. Only a number can be mistaken for the student's own numbered
  /// points, so only numbered labels are checked against the sequence.
  final bool numbered;

  /// Unmistakably a label wherever it appears.
  bool get strong => explicit || echoes || continuation;
}

/// Finds question labels at the start of answer-sheet text.
///
/// Built to under-detect rather than over-detect, and — unlike a pattern
/// matcher on its own — checked against the question paper. A student's
/// working opens with numbers all the time (`50 micrometres = 0.05 mm`,
/// `12.5 mol`); a number is taken as a label only when the paper has that
/// question, or when it is written unmistakably as one (`Q12`). A missed label
/// costs a little confidence; a false one moves an answer to the wrong
/// question.
class QuestionLabelDetector {
  const QuestionLabelDetector();

  static final RegExp _explicit = RegExp(
    r'^\s*q(?:uestion|n|u)?\s*[.:#-]?\s*\d',
    caseSensitive: false,
  );

  static final RegExp _continued = RegExp(
    r'\b(?:cont(?:inued|inues|\.|d|’d|\x27d)?|contd)\b',
    caseSensitive: false,
  );

  /// The label and everything written with it: `Q2 (a)`, `3.`, `4)`.
  static final RegExp _prefix = RegExp(
    r'^\s*(?:q(?:uestion|n|u)?\s*[.:#-]?\s*)?\d{1,3}'
    r'(?:\s*[.\-]?\s*\(\s*(?:[a-z]|[ivx]{1,4})\s*\)|[.\-]?(?:[a-z]|[ivx]{1,4})(?=[\s.):\]]|$)){0,2}',
    caseSensitive: false,
  );

  /// A part on its own: `(b)`, `b)`, `(ii)`.
  static final RegExp _partOnly =
      RegExp(r'^\s*\(\s*([a-z]|[ivx]{1,4})\s*\)|^\s*([a-z]|[ivx]{1,4})\s*\)');

  /// Finds a label at the start of [line].
  ///
  /// [current] is the label of the answer being read, so a bare `(b)` can be
  /// resolved to `2(b)`. [standalone] is set for a region the layout engine
  /// already identified as a question number, where the whole text is the
  /// label and the usual demand for wording after it does not apply.
  DetectedLabel? detect(
    String line, {
    required QuestionPaper paper,
    QuestionLabel? current,
    bool standalone = false,
  }) {
    final String text = line.replaceAll('⚠', '').trim();
    if (text.isEmpty) return null;

    final bool explicit = _explicit.hasMatch(text);
    final bool continuation = _continued.hasMatch(
      text.length > 40 ? text.substring(0, 40) : text,
    );

    final QuestionLabel? parsed = QuestionLabel.parse(text);
    if (parsed != null) {
      final RegExpMatch? prefix = _prefix.firstMatch(text);
      final String rest = prefix == null ? '' : text.substring(prefix.end);
      final bool delimited = RegExp(r'^\s*[.):\]]').hasMatch(rest);
      final bool bracketedPart = parsed.depth > 1 &&
          (prefix?.group(0)?.contains('(') ?? false);
      final String after = rest.replaceFirst(RegExp(r'^\s*[.):\]\-]*\s*'), '');

      // What follows the number decides whether it is a label at all.
      final bool wordingFollows = after.isEmpty ||
          RegExp(r'''^[A-Z(\["'“‘]''').hasMatch(after) ||
          continuation;
      final bool shaped = explicit ||
          standalone ||
          (delimited && !RegExp(r'^\d').hasMatch(after)) ||
          bracketedPart ||
          wordingFollows;
      if (!shaped) return null;

      // A decimal is a number, not a label: "12.5", "0.05".
      if (RegExp(r'^\s*\d+\.\d').hasMatch(text) && !explicit) return null;

      final QuestionLabel? resolved = _resolve(parsed, paper);
      final bool inPaper = resolved != null;
      if (!inPaper && !explicit) return null;

      double confidence = explicit || standalone
          ? 0.95
          : bracketedPart || delimited
              ? 0.9
              : 0.8;
      final bool echoes = inPaper && _echoesQuestion(after, paper.byLabel(resolved));
      if (inPaper) {
        // Two independent confirmations lift a bare number: it comes next in
        // the paper's order, or the wording after it is the question's own —
        // an answer booklet that reprints each question.
        if (echoes) {
          confidence = 0.98;
        } else if (_comesNext(resolved, current, paper)) {
          confidence = confidence < 0.92 ? 0.92 : confidence;
        }
      }
      return DetectedLabel(
        label: resolved ?? parsed,
        observed: prefix?.group(0)?.trim() ?? parsed.display,
        confidence: confidence,
        inPaper: inPaper,
        explicit: explicit,
        continuation: continuation,
        echoes: echoes,
        numbered: true,
      );
    }

    // A bare part, resolved against the answer being read.
    final RegExpMatch? part = _partOnly.firstMatch(text);
    if (part != null && current != null) {
      final String letter = (part.group(1) ?? part.group(2))!.toLowerCase();
      for (final QuestionLabel candidate in _partCandidates(current, letter)) {
        if (paper.byLabel(candidate) != null) {
          return DetectedLabel(
            label: candidate,
            observed: part.group(0)!.trim(),
            confidence: standalone ? 0.85 : 0.75,
            inPaper: true,
          );
        }
      }
    }
    return null;
  }

  /// True when [text] opens with the question's own wording.
  static bool _echoesQuestion(String text, Question? question) {
    if (question == null || question.questionText.length < 12 || text.length < 12) {
      return false;
    }
    final int length = text.length < 48 ? text.length : 48;
    final String printed = question.questionText.length < length
        ? question.questionText
        : question.questionText.substring(0, length);
    return textSimilarity(text.substring(0, length), printed) >= 0.7;
  }

  /// True when [label] is the question after [current] in the paper — or the
  /// first question, when nothing has been read yet.
  static bool _comesNext(QuestionLabel label, QuestionLabel? current, QuestionPaper paper) {
    final List<Question> order = paper.markable;
    int indexOf(QuestionLabel l) => order.indexWhere(
          (Question q) => q.label == l || q.label.isWithin(l) || l.isWithin(q.label),
        );
    final int at = indexOf(label);
    if (at < 0) return false;
    if (current == null) return at == 0;
    final int before = indexOf(current);
    return before >= 0 && at > before && at <= before + 2;
  }

  /// The label as the paper knows it: exact, or with a part the student added
  /// that the paper does not have trimmed back to the question it belongs to.
  QuestionLabel? _resolve(QuestionLabel label, QuestionPaper paper) {
    if (paper.byLabel(label) != null) return label;
    QuestionLabel? ancestor = label.parent;
    while (ancestor != null) {
      final Question? question = paper.byLabel(ancestor);
      if (question != null && question.isLeaf) return label;
      ancestor = ancestor.parent;
    }
    return null;
  }

  /// Where a bare part could sit: a sibling of the current part, a child of
  /// it, or a part of the current question.
  Iterable<QuestionLabel> _partCandidates(QuestionLabel current, String part) sync* {
    if (current.depth >= 2) yield current.withPartAt(current.depth - 1, part);
    yield current.child(part);
    yield QuestionLabel(<String>[current.major, part]);
  }
}
