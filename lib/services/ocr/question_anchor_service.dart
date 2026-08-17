import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';

/// Where a question's answer starts in the transcript.
class QuestionAnchor {
  const QuestionAnchor({
    required this.questionNumber,
    required this.pageIndex,
    required this.lineIndex,
  });

  /// As written on the page, e.g. `1`, `2b`, `3(a)`.
  final String questionNumber;

  final int pageIndex;
  final int lineIndex;
}

/// Anchored text, plus the map back to where each anchor came from.
class AnchoredTranscript {
  const AnchoredTranscript({required this.text, required this.anchors});

  final String text;
  final List<QuestionAnchor> anchors;

  bool get hasAnchors => anchors.isNotEmpty;

  /// The question a given line belongs to, or null before the first anchor.
  String? questionAt(int pageIndex, int lineIndex) {
    String? current;
    for (final QuestionAnchor anchor in anchors) {
      final bool started = anchor.pageIndex < pageIndex ||
          (anchor.pageIndex == pageIndex && anchor.lineIndex <= lineIndex);
      if (!started) break;
      current = anchor.questionNumber;
    }
    return current;
  }
}

/// Finds question numbers in a transcript and marks them explicitly.
///
/// The marking prompt already asks the model to work out which answer belongs
/// to which question, and it is good at it. This does not replace that — it
/// makes it *traceable*. Because the anchors are tied to page and line indices,
/// and every line knows its box and its crop, a marked question can be followed
/// back to the pixels it was read from.
///
/// Written to under-detect rather than over-detect. A missed anchor costs
/// nothing, since the model still maps the question itself; a false one — a
/// date, a measurement, a list item read as "2." — would actively mislead it.
class QuestionAnchorService {
  const QuestionAnchorService();

  /// Wraps a detected question number so the model cannot mistake it for part
  /// of the student's answer.
  static String anchorFor(String questionNumber) => '[[Q$questionNumber]]';

  /// `2 (a)` or `2(a)` — a numbered question with a sub-part.
  ///
  /// The interior whitespace is not cosmetic tolerance: recognition genuinely
  /// emits `2 ( a )` for what the page shows as `2(a)`, so a pattern that
  /// insists on tight parentheses matches nothing on a real transcript.
  static final RegExp _numberedSubPart =
      RegExp(r'^(\d{1,2})\s*\(\s*([a-z])\s*\)\s*(?=\S)');

  /// `2b.` or `2b)` — a sub-part written without parentheses.
  static final RegExp _suffixedSubPart =
      RegExp(r'^(\d{1,2})\s*([a-z])\s*[.)\]:]\s*(?=\S)');

  /// `1.`, `3)`, `4:` — a numbered question with an explicit delimiter.
  static final RegExp _delimited =
      RegExp(r'^(\d{1,2})\s*[.)\]:]\s*(?=\S)');

  /// `1 Name the organelle…` — a numbered question with no delimiter at all,
  /// which is how most papers are actually typeset.
  ///
  /// The capital letter is what makes this safe. Without it the pattern would
  /// also swallow a student's working — `50 micrometres = 0.05 mm` opens with a
  /// number too, and reading that as "question 50" would corrupt the mapping
  /// far worse than missing an anchor ever could.
  static final RegExp _bareNumbered = RegExp(r'^(\d{1,2})\s+(?=[A-Z])');

  /// A sub-part on its own line: `(a)`, `a)`, `(b)`.
  static final RegExp _subPart = RegExp(r'^\(?\s*([a-z])\s*\)\s*(?=\S)');

  /// Adds anchors to a transcript's text and reports where they landed.
  AnchoredTranscript anchor(
    DocumentTranscript transcript, {
    double? flagBelow,
  }) {
    final List<QuestionAnchor> anchors = <QuestionAnchor>[];
    final List<String> blocks = <String>[];

    String? currentNumber;

    for (int pageIndex = 0; pageIndex < transcript.pages.length; pageIndex++) {
      final PageTranscript page = transcript.pages[pageIndex];
      final StringBuffer body = StringBuffer();

      for (int lineIndex = 0; lineIndex < page.lines.length; lineIndex++) {
        final TextLine line = page.lines[lineIndex];
        final String? detected = detectQuestion(line.text, currentNumber);

        if (detected != null) {
          currentNumber = detected;
          anchors.add(
            QuestionAnchor(
              questionNumber: detected,
              pageIndex: pageIndex,
              lineIndex: lineIndex,
            ),
          );
        }

        final bool uncertain = flagBelow != null && line.isUncertain(flagBelow);
        final String prefix = <String>[
          if (uncertain) DocumentTranscript.uncertainMarker,
          if (detected != null) anchorFor(detected),
        ].join(' ');

        body.writeln(prefix.isEmpty ? line.text : '$prefix ${line.text}');
      }

      blocks.add(
        '--- Page ${page.pageNumber} ---\n${body.toString().trim()}',
      );
    }

    return AnchoredTranscript(
      text: blocks.join('\n\n').trim(),
      anchors: anchors,
    );
  }

  /// Returns the question number [line] starts, or null if it starts none.
  ///
  /// [currentNumber] carries the last question seen, so a bare `(b)` can be
  /// resolved to `2b` rather than being reported as an unrelated question.
  String? detectQuestion(String line, String? currentNumber) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) return null;

    // Most specific first: "2 (a)" must not be read as the bare question "2".
    final RegExpMatch? withSubPart = _numberedSubPart.firstMatch(trimmed);
    if (withSubPart != null) {
      return '${withSubPart.group(1)!}${withSubPart.group(2)!}';
    }

    final RegExpMatch? suffixed = _suffixedSubPart.firstMatch(trimmed);
    if (suffixed != null) {
      return '${suffixed.group(1)!}${suffixed.group(2)!}';
    }

    final RegExpMatch? delimited = _delimited.firstMatch(trimmed);
    if (delimited != null) return delimited.group(1)!;

    final RegExpMatch? bare = _bareNumbered.firstMatch(trimmed);
    if (bare != null) return bare.group(1)!;

    final RegExpMatch? subPart = _subPart.firstMatch(trimmed);
    if (subPart != null && currentNumber != null) {
      // Only extend a plain question number: turning "2b" into "2bc" would be
      // nonsense, so a sub-part following a sub-part replaces its letter.
      final String major =
          RegExp(r'^\d+').firstMatch(currentNumber)?.group(0) ?? currentNumber;
      return '$major${subPart.group(1)!}';
    }

    return null;
  }
}
