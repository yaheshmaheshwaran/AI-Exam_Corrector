/// A question label broken into its parts: `3(a)(ii)` → `['3', 'a', 'ii']`.
///
/// This is the join key between the two documents. The question paper prints
/// `2 (a)`, a student writes `2a)`, `Q2(a)` or `2.a`, and recognition may read
/// any of those as `2 ( a )`. All of them must land on the same question, and
/// none of them may be confused with question 20 or with part (a) of another.
class QuestionLabel {
  const QuestionLabel(this.parts);

  /// `['3', 'a', 'ii']`. The first part is always the question number.
  final List<String> parts;

  /// Dotted, lower-case, and unambiguous: `3.a.ii`.
  String get key => parts.join('.');

  /// Compact identifier: `Q3aii`.
  String get questionId => 'Q${parts.join()}';

  /// How a paper prints it: `3(a)(ii)`.
  String get display => parts.isEmpty
      ? ''
      : parts.first + parts.skip(1).map((String part) => '($part)').join();

  String get major => parts.isEmpty ? '' : parts.first;

  int get depth => parts.length;

  QuestionLabel? get parent =>
      parts.length <= 1 ? null : QuestionLabel(parts.sublist(0, parts.length - 1));

  /// True when this label is [other] or one of its sub-parts.
  bool isWithin(QuestionLabel other) {
    if (other.parts.length > parts.length) return false;
    for (int index = 0; index < other.parts.length; index++) {
      if (other.parts[index] != parts[index]) return false;
    }
    return true;
  }

  QuestionLabel child(String part) =>
      QuestionLabel(<String>[...parts, part.toLowerCase()]);

  /// Replaces the deepest part at [depth] — `2(a)` followed by `(b)` is
  /// `2(b)`, not `2(a)(b)`.
  QuestionLabel withPartAt(int depth, String part) {
    final List<String> kept = parts.sublist(0, depth.clamp(0, parts.length));
    return QuestionLabel(<String>[...kept, part.toLowerCase()]);
  }

  /// What may be written before a question number: `Q`, `Q.`, `Qn`, `Ques.`,
  /// `Question`, with or without `No.` — `Q. No. 1`, `Q.No:1`, `Question No. 4`.
  /// Shared by everything that reads labels, on either document.
  static const String prefixPattern =
      r'q(?:uestion|ues|n|u|s)?\s*\.?\s*(?:(?:no|num(?:ber)?)\s*\.?\s*|#\s*)?[.:#-]?\s*';

  static final RegExp _leading = RegExp(
    r'^\s*(?:' + prefixPattern + r')?\s*[.:#-]?\s*(\d{1,3})',
    caseSensitive: false,
  );

  static final RegExp _part = RegExp(
    r'^\s*[.\-]?\s*\(?\s*([a-z]|[ivx]{1,4})\s*\)',
    caseSensitive: false,
  );

  /// A part written without parentheses directly after the number: `2a`, `2.b`.
  static final RegExp _barePart = RegExp(
    r'^[.\-]?([a-z]|[ivx]{1,4})(?![a-z])',
    caseSensitive: false,
  );

  /// Parses a label however it was written. Returns null for anything that
  /// does not start with a question number.
  static QuestionLabel? parse(String text) {
    final RegExpMatch? leading = _leading.firstMatch(text);
    if (leading == null) return null;

    final List<String> parts = <String>[
      int.parse(leading.group(1)!).toString(),
    ];
    String rest = text.substring(leading.end);

    // At most two levels of sub-part: 3(a)(ii). Deeper nesting does not occur
    // on real papers, and allowing it would let prose leak into the label.
    for (int level = 0; level < 2; level++) {
      final RegExpMatch? match = _part.firstMatch(rest) ??
          (level == 0 ? _barePart.firstMatch(rest) : null);
      if (match == null) break;
      parts.add(match.group(1)!.toLowerCase());
      rest = rest.substring(match.end);
    }

    return QuestionLabel(parts);
  }

  /// Parses a dotted key back into a label.
  static QuestionLabel fromKey(String key) => QuestionLabel(
        key.split('.').where((String part) => part.isNotEmpty).toList(),
      );

  /// True for a part that reads as a roman numeral rather than a letter.
  static bool isRoman(String part) => RegExp(r'^[ivx]+$').hasMatch(part);

  @override
  bool operator ==(Object other) => other is QuestionLabel && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => display;
}
