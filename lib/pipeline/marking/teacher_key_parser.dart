import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/pipeline/marking/marking_rules.dart';
import 'package:exam_corrector/pipeline/marking/teacher_key.dart';

/// What reading a key found.
class TeacherKeyParse {
  const TeacherKeyParse({
    required this.entries,
    required this.unmatched,
    required this.warnings,
    required this.labelsSeen,
  });

  final Map<String, TeacherKeyEntry> entries;
  final List<String> unmatched;
  final List<String> warnings;

  /// How many answers the key seemed to give, matched or not.
  final int labelsSeen;

  /// Enough of the key landed on the paper's questions to trust the rest.
  bool get trustworthy => labelsSeen > 0 && entries.isNotEmpty && entries.length / labelsSeen >= 0.6;
}

/// Reads a typed answer key the way teachers write them, and matches each
/// answer to a question on the paper.
///
/// It understands:
/// - answers led by a question label: `1.`, `Q2(a)`, `2 a)`, `11(b):`,
///   `Part B 11(b)`, `Ans 3:`;
/// - multiple-choice lists: `1-B, 2-C, 3-A`, `1. (b)`, a table row `1 | B`;
/// - marks: `(2 marks)`, `[2]` on the answer, and per-point `(1)`;
/// - alternatives: lines starting `OR`, `Accept`, `Also accept`.
///
/// Every label is settled against the paper itself: `1. (b)` is question
/// 1(b) when the paper has one, and option (b) of question 1 when question 1
/// is multiple choice.
class TeacherKeyParser {
  const TeacherKeyParser({this.standard = const MarkingStandard()});

  /// For which sections the college marks as multiple choice.
  final MarkingStandard standard;

  static final RegExp _page = RegExp(r'^---\s*Page\s+\d+\s*---$');
  static final RegExp _sectionOnly =
      RegExp(r'^\s*(?:part|section)\s+([a-z]|\d{1,2}|[ivx]{1,4})\s*[:.\-–]?\s*$', caseSensitive: false);

  /// A line that opens an answer: an optional section, an optional
  /// "Q"/"Ans", a number, up to two parts, then a separator.
  static final RegExp _lead = RegExp(
    <String>[
      r'^\s*(?:(?:part|section)\s+([a-z]|\d{1,2}|[ivx]{1,4})\s*[,:.\-–]?\s*)?',
      r'(?:(?:ans(?:wer)?|',
      QuestionLabel.prefixPattern,
      r')\s*)?',
      r'(\d{1,3})',
      r'((?:\s*\(\s*(?:[a-z]|[ivx]{1,4})\s*\)|\s?[.]?(?:[a-z]|[ivx]{1,4})(?![a-z])){0,2})',
      r'\s*(?:[.):\-–]\s*|\s+|$)',
    ].join(),
    caseSensitive: false,
  );

  /// `3 - B`, `3. (b)`, `3) c`, `3: D`, `3 B` — one pair of a compact list.
  static final RegExp _pair =
      RegExp(r'(\d{1,3})\s*(?:[-–.:)]|\t|\|)?\s*\(?\s*([a-e])\s*\)?(?![a-z0-9])', caseSensitive: false);

  static final RegExp _marksOnAnswer =
      RegExp(r'[\[(]\s*(\d+(?:\.\d+)?)\s*(?:marks?|m)?\s*[\])]\s*$|(\d+(?:\.\d+)?)\s*marks?\s*$', caseSensitive: false);
  static final RegExp _marksOnPoint = RegExp(r'[\[(]\s*(\d+(?:\.\d+)?)\s*(?:marks?|m)?\s*[\])]\s*$', caseSensitive: false);
  static final RegExp _bullet = RegExp(r'^\s*(?:[-•*▪·]|\(?[ivx]{1,4}\)|\(?\d{1,2}[.)])\s+');
  static final RegExp _alternative = RegExp(r'^\s*(?:or|also accept|accept|alternatively)\b\s*[:\-–]?\s*', caseSensitive: false);
  static final RegExp _note = RegExp(r'^\s*note\s*[:\-–]\s*', caseSensitive: false);
  static final RegExp _optionOnly =
      RegExp(r'^\s*(?:(?:ans(?:wer)?|option|opt)\s*[:.\-–]?\s*)?\(?\s*([a-e])\s*\)?\s*[.]?\s*$', caseSensitive: false);

  TeacherKeyParse parse(String text, QuestionPaper paper) {
    final List<String> lines = <String>[
      for (final String raw in text.split(RegExp(r'\r?\n')))
        if (raw.trim().isNotEmpty && !_page.hasMatch(raw.trim())) raw.trimRight(),
    ];

    final Map<String, TeacherKeyEntry> entries = <String, TeacherKeyEntry>{};
    final List<String> unmatched = <String>[];
    final List<String> warnings = <String>[];
    int seen = 0;

    // Blocks: a lead line and the lines under it.
    String? section;
    _Block? block;
    final List<_Block> blocks = <_Block>[];

    for (final String line in lines) {
      final RegExpMatch? sectionOnly = _sectionOnly.firstMatch(line);
      if (sectionOnly != null) {
        section = sectionOnly.group(1)!.toUpperCase();
        continue;
      }

      // A line that is nothing but option pairs: `1-B, 2-C, 3-A`.
      final List<RegExpMatch> pairs = _pair.allMatches(line).toList();
      if (pairs.isNotEmpty && _onlyPairs(line, pairs)) {
        for (final RegExpMatch pair in pairs) {
          seen++;
          final Question? question = _find(paper, QuestionLabel.parse(pair.group(1)!), section);
          if (question != null && question.isLeaf) {
            entries[question.questionId] =
                TeacherKeyEntry(questionId: question.questionId, option: pair.group(2)!.toLowerCase());
          } else {
            unmatched.add(_describe(pair.group(1)!, section));
          }
        }
        block = null;
        continue;
      }

      final RegExpMatch? lead = _lead.firstMatch(line);
      if (lead != null) {
        final String label = '${lead.group(2)}${lead.group(3) ?? ''}';
        final String? leadSection = lead.group(1)?.toUpperCase() ?? section;
        final QuestionLabel? parsed = QuestionLabel.parse(label.replaceAll(RegExp(r'\s'), ''));
        final String rest = line.substring(lead.end).trim();
        // A numbered point inside an answer is not a new question: a label
        // opens a new answer only when it names a question not yet answered.
        final bool opensAnswer = parsed != null &&
            (block == null ||
                !_sameOrEarlier(parsed, block.label) ||
                leadSection != block.section);
        if (opensAnswer) {
          block = _Block(parsed, leadSection, rest);
          blocks.add(block);
          continue;
        }
      }
      block?.lines.add(line.trim());
    }

    for (final _Block b in blocks) {
      seen++;
      final ({Question? question, String? option}) target = _resolve(paper, b);
      final Question? question = target.question;
      if (question == null) {
        unmatched.add(_describe(b.label.display, b.section));
        continue;
      }
      if (!question.isLeaf) {
        // An answer for a question with parts: split it by the parts.
        final Map<String, List<String>> parts = _splitParts(b, question);
        if (parts.isEmpty) {
          unmatched.add(_describe(b.label.display, b.section));
          continue;
        }
        for (final MapEntry<String, List<String>> part in parts.entries) {
          final Question? leaf = paper.byId(part.key);
          if (leaf == null) continue;
          entries[leaf.questionId] = _entry(leaf, part.value, null, warnings, paper);
        }
        continue;
      }
      if (entries.containsKey(question.questionId)) {
        warnings.add('Your key answers question ${question.displayNumber} twice; the first answer is used.');
        continue;
      }
      entries[question.questionId] = _entry(question, <String>[b.first, ...b.lines], target.option, warnings, paper);
    }

    return TeacherKeyParse(entries: entries, unmatched: unmatched, warnings: warnings, labelsSeen: seen);
  }

  /// Which question a block answers — and, for `1. (b)` against a
  /// multiple-choice question 1, the option it gives.
  ({Question? question, String? option}) _resolve(QuestionPaper paper, _Block b) {
    final Question? exact = _find(paper, b.label, b.section);
    if (exact != null) {
      final RegExpMatch? only = _optionOnly.firstMatch(b.first);
      final bool mcq = exact.isLeaf && MarkingRules.isMcqQuestion(exact, standard);
      return (question: exact, option: mcq && only != null && b.lines.isEmpty ? only.group(1)!.toLowerCase() : null);
    }
    // `1(b)` where the paper has no 1(b): the answer (b) to question 1.
    final QuestionLabel? parent = b.label.parent;
    if (parent != null && b.label.depth == 2 && RegExp(r'^[a-e]$').hasMatch(b.label.parts.last)) {
      final Question? question = _find(paper, parent, b.section);
      if (question != null && question.isLeaf && MarkingRules.isMcqQuestion(question, standard)) {
        return (question: question, option: b.label.parts.last);
      }
    }
    return (question: null, option: null);
  }

  static Question? _find(QuestionPaper paper, QuestionLabel? label, String? section) {
    if (label == null) return null;
    final List<Question> all = <Question>[
      for (final Question top in paper.questions) ...<Question>[top, ..._descendants(top)],
    ].where((Question q) => q.label == label).toList();
    if (all.isEmpty) return null;
    if (section != null) {
      final Question? inSection = all.where((Question q) => q.sectionId?.toUpperCase() == section).firstOrNull;
      if (inSection != null) return inSection;
    }
    return all.first;
  }

  static Iterable<Question> _descendants(Question question) sync* {
    for (final Question child in question.subQuestions) {
      yield child;
      yield* _descendants(child);
    }
  }

  /// Splits an answer to a question with parts by lines starting `(a)`,
  /// `a)`, `(ii)` into each part's answer.
  static Map<String, List<String>> _splitParts(_Block b, Question question) {
    final RegExp part = RegExp(r'^\s*\(?\s*([a-z]|[ivx]{1,4})\s*\)\s*(.*)$', caseSensitive: false);
    final Map<String, List<String>> out = <String, List<String>>{};
    String? current;
    for (final String line in <String>[if (b.first.isNotEmpty) b.first, ...b.lines]) {
      final RegExpMatch? m = part.firstMatch(line);
      if (m != null) {
        final Question? leaf = question.subQuestions
            .where((Question q) => q.label.parts.last == m.group(1)!.toLowerCase())
            .firstOrNull;
        if (leaf != null && leaf.isLeaf) {
          current = leaf.questionId;
          out[current] = <String>[m.group(2)!.trim()];
          continue;
        }
      }
      if (current != null) out[current]!.add(line);
    }
    return out;
  }

  TeacherKeyEntry _entry(
    Question question,
    List<String> lines,
    String? option,
    List<String> warnings,
    QuestionPaper paper,
  ) {
    final List<String> body = <String>[for (final String l in lines) if (l.trim().isNotEmpty) l.trim()];
    double? keyMarks;
    final List<String> answer = <String>[];
    final List<AnswerKeyPoint> points = <AnswerKeyPoint>[];
    final List<String> alternatives = <String>[];
    final List<String> notes = <String>[];
    String? mcqOption = option;

    for (int i = 0; i < body.length; i++) {
      String line = body[i];
      if (i == 0) {
        final RegExpMatch? marks = _marksOnAnswer.firstMatch(line);
        if (marks != null && !_bullet.hasMatch(line)) {
          keyMarks = double.tryParse(marks.group(1) ?? marks.group(2)!);
          line = line.substring(0, marks.start).trim();
        }
        if (mcqOption == null && MarkingRules.isMcqQuestion(question, standard)) {
          final RegExpMatch? only = _optionOnly.firstMatch(line);
          if (only != null) {
            mcqOption = only.group(1)!.toLowerCase();
            continue;
          }
        }
        if (line.isEmpty) continue;
      }
      final RegExpMatch? alt = _alternative.firstMatch(line);
      if (alt != null) {
        alternatives.add(line.substring(alt.end).trim());
        continue;
      }
      final RegExpMatch? note = _note.firstMatch(line);
      if (note != null) {
        notes.add(line.substring(note.end).trim());
        continue;
      }
      final RegExpMatch? pointMarks = _marksOnPoint.firstMatch(line);
      if (pointMarks != null && (i > 0 || _bullet.hasMatch(line))) {
        final String criterion = line.substring(0, pointMarks.start).replaceFirst(_bullet, '').trim();
        if (criterion.isNotEmpty) {
          points.add(AnswerKeyPoint(criterion: criterion, marks: double.parse(pointMarks.group(1)!)));
          continue;
        }
      }
      answer.add(line);
    }

    final double? maximum = question.maximumMarks;
    if (maximum != null && keyMarks != null && (keyMarks - maximum).abs() > 0.001) {
      warnings.add('Your key gives ${_marks(keyMarks)} for question ${question.displayNumber}; the paper says '
          '${_marks(maximum)}, so the paper\'s marks are used.');
    } else if (maximum != null && points.isNotEmpty) {
      final double sum = points.fold(0, (double s, AnswerKeyPoint p) => s + p.marks);
      if ((sum - maximum).abs() > 0.001) {
        warnings.add('The points in your key for question ${question.displayNumber} add up to ${_marks(sum)}; the paper '
            'says ${_marks(maximum)}, so they are scaled to fit.');
      }
    }

    return TeacherKeyEntry(
      questionId: question.questionId,
      answer: answer.join('\n'),
      points: points,
      alternatives: alternatives,
      option: mcqOption,
      keyMarks: keyMarks,
      notes: notes.join(' '),
    );
  }

  /// True when a line holds option pairs and nothing but separators.
  static bool _onlyPairs(String line, List<RegExpMatch> pairs) {
    final String rest = line.replaceAllMapped(_pair, (_) => '').replaceAll(RegExp(r'[\s,;|/]'), '');
    return rest.isEmpty && (pairs.length > 1 || RegExp(r'^\s*\d{1,3}\s*[-–:|\t]').hasMatch(line));
  }

  /// `2(b)` after `2(a)` is a new answer; `1.` after `3.` is a numbered point.
  static bool _sameOrEarlier(QuestionLabel next, QuestionLabel current) {
    final int a = int.tryParse(next.major) ?? 0, b = int.tryParse(current.major) ?? 0;
    if (a != b) return a < b;
    return next.key.compareTo(current.key) <= 0 || next.depth < current.depth;
  }

  static String _describe(String label, String? section) =>
      section == null ? label : 'Part $section $label';

  static String _marks(double m) => m == m.roundToDouble() ? '${m.round()} mark${m == 1 ? '' : 's'}' : '$m marks';
}

class _Block {
  _Block(this.label, this.section, this.first);

  final QuestionLabel label;
  final String? section;

  /// What follows the label on its own line.
  final String first;
  final List<String> lines = <String>[];
}
