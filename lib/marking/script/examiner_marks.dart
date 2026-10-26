/// Finds lines in a transcription that look like an examiner's marks rather
/// than the student's writing: a score on its own ("3", "4/5", "2½", "1.5"),
/// or a tick or cross. A question label ("17.", "2)", "(b)") is not a score.
///
/// The reader is told never to transcribe examiner marks, but a score that
/// slips into the student's text would let the marker copy it. This only
/// reports; nothing is removed, because a student may also write a short
/// number on its own line.
class ExaminerMarks {
  const ExaminerMarks._();

  static final RegExp _score = RegExp(r'^\d{1,2}(\.\d|\s*½)?\s*(/\s*\d{1,3})?\s*(marks?|m)?$', caseSensitive: false);
  static final RegExp _tick = RegExp('[✓✔✗✘☑☒]');

  /// The lines of [text] that look like an examiner's marks.
  static List<String> suspicious(String text) => <String>[
        for (final String raw in text.split('\n'))
          if (_looksLikeMark(raw.trim())) raw.trim(),
      ];

  static bool _looksLikeMark(String line) {
    if (line.isEmpty) return false;
    if (_tick.hasMatch(line)) return true;
    return line.length <= 12 && _score.hasMatch(line);
  }
}
