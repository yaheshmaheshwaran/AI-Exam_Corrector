/// One substitution the normaliser made, kept so it can be shown and undone.
class NormalizationChange {
  const NormalizationChange({
    required this.before,
    required this.after,
    required this.reason,
  });

  final String before;
  final String after;
  final String reason;
}

/// The result of normalising one line.
class NormalizedLine {
  const NormalizedLine({required this.text, required this.changes});

  final String text;
  final List<NormalizationChange> changes;

  bool get isChanged => changes.isNotEmpty;
}

/// Repairs the artefacts of recognition without touching the student's answer.
///
/// The line this walks is a fine one. Rejoining a word split across two lines
/// recovers what the student wrote; "correcting" their spelling would fabricate
/// an answer they did not give and could earn them marks they did not deserve.
/// So every rule here is restricted to damage the *pipeline* introduces —
/// hyphenation at line breaks, glyph substitutions, stray whitespace — and
/// every substitution is recorded so the teacher can see it and revert it.
///
/// Nothing here is applied to text the teacher typed themselves.
class AnswerNormalizer {
  const AnswerNormalizer();

  /// Characters recognisers routinely emit in place of plain ASCII.
  static const Map<String, String> _glyphs = <String, String>{
    '‘': "'", // left single quote
    '’': "'", // right single quote
    '‚': "'",
    '“': '"', // left double quote
    '”': '"', // right double quote
    '–': '-', // en dash
    '—': '-', // em dash
    '−': '-', // minus sign
    'ﬀ': 'ff',
    'ﬁ': 'fi',
    'ﬂ': 'fl',
    ' ': ' ', // non-breaking space
  };

  /// Applied only inside tokens that are otherwise numeric — see [_digits].
  static const Map<String, String> _confusions = <String, String>{
    'l': '1',
    'I': '1',
    'O': '0',
    'o': '0',
    'S': '5',
    'B': '8',
  };

  /// Normalises one line in isolation.
  NormalizedLine normalizeLine(String text) {
    final List<NormalizationChange> changes = <NormalizationChange>[];

    String result = _applyGlyphs(text, changes);
    result = _digits(result, changes);
    result = _whitespace(result, changes);

    return NormalizedLine(text: result, changes: changes);
  }

  /// Rejoins words broken across a line break, in an assembled block of text.
  ///
  /// Deliberately *not* applied to the stored per-line text. The review screen
  /// shows each line beside the crop it was read from, and moving a word from
  /// one line to the next would leave the teacher looking at a crop reading
  /// "mito-" next to the text "mitochondria". So this runs only when the lines
  /// are flattened into the string the AI marks, where line boundaries have
  /// already stopped mattering.
  ///
  /// Page markers are left alone.
  String joinHyphenatedLines(String block) {
    final List<String> lines = block.split('\n');
    final List<String> result = <String>[];

    for (int index = 0; index < lines.length; index++) {
      String current = lines[index];

      while (index + 1 < lines.length &&
          _endsWithSplitWord(current) &&
          !_isPageMarker(lines[index + 1])) {
        final RegExpMatch? head = RegExp(r'^([A-Za-z]+)(.*)$', dotAll: true)
            .firstMatch(lines[index + 1].trimLeft());
        if (head == null) break;

        final String stem = current.trimRight();
        current = stem.substring(0, stem.length - 1) + head.group(1)!;

        final String remainder = head.group(2)!.trimLeft();
        if (remainder.isEmpty) {
          index++;
        } else {
          lines[index + 1] = remainder;
          break;
        }
      }

      result.add(current);
    }

    return result.join('\n');
  }

  bool _isPageMarker(String line) => line.trimLeft().startsWith('--- Page ');

  /// A trailing hyphen after letters is how a recogniser renders a word broken
  /// over two lines. A hyphen with spaces around it is punctuation, not a break.
  bool _endsWithSplitWord(String line) =>
      RegExp(r'[A-Za-z]{2,}-$').hasMatch(line.trimRight());

  String _applyGlyphs(String text, List<NormalizationChange> changes) {
    String result = text;
    _glyphs.forEach((String from, String to) {
      if (!result.contains(from)) return;
      result = result.replaceAll(from, to);
      changes.add(
        NormalizationChange(
          before: from,
          after: to,
          reason: 'Replaced a typographic character with its plain equivalent.',
        ),
      );
    });
    return result;
  }

  /// Fixes letter-for-digit confusions, and only inside a token that is
  /// evidently a number.
  ///
  /// "l0" in "12l0" is a misread 1; the same letter in "hello" is not. The
  /// guard is that the token must already be majority digits and contain no
  /// run of letters that could be a word — so "5N" (a force) and "pH7" survive
  /// untouched, while "l2.S" becomes "12.5".
  String _digits(String text, List<NormalizationChange> changes) {
    final RegExp token = RegExp(r'[A-Za-z0-9.,]+');

    return text.replaceAllMapped(token, (Match match) {
      final String original = match.group(0)!;
      if (!_looksNumeric(original)) return original;

      final StringBuffer fixed = StringBuffer();
      for (final String character in original.split('')) {
        fixed.write(_confusions[character] ?? character);
      }

      final String result = fixed.toString();
      if (result != original) {
        changes.add(
          NormalizationChange(
            before: original,
            after: result,
            reason: 'Read as a number: letters corrected to digits.',
          ),
        );
      }
      return result;
    });
  }

  bool _looksNumeric(String token) {
    final String core = token.replaceAll(RegExp(r'[.,]'), '');
    if (core.isEmpty) return false;

    final int digits = core.split('').where(_isDigit).length;
    if (digits == 0) return false;

    // Every non-digit must be a character that is confusable with one; a token
    // holding any other letter is a word, not a damaged number.
    final bool onlyConfusable = core
        .split('')
        .every((String c) => _isDigit(c) || _confusions.containsKey(c));

    return onlyConfusable && digits >= core.length - digits;
  }

  bool _isDigit(String character) =>
      character.codeUnitAt(0) >= 0x30 && character.codeUnitAt(0) <= 0x39;

  String _whitespace(String text, List<NormalizationChange> changes) {
    final String collapsed = text.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    if (collapsed != text) {
      changes.add(
        const NormalizationChange(
          before: 'irregular spacing',
          after: 'single spaces',
          reason: 'Collapsed the spacing the recogniser introduced.',
        ),
      );
    }
    return collapsed;
  }
}
