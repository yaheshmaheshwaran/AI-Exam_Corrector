import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/questions/question_tree.dart';

/// Reads a question paper's structure from its text layer, deterministically.
///
/// Costs nothing and is exactly repeatable, so it is tried first. It assumes
/// nothing about numbering beyond what papers actually do — `1`, `1.`, `Q1`,
/// `Question 1`, `2 (a)`, `2a)`, `(b)`, `(ii)` — and reports what it could not
/// establish rather than guessing; [isTrustworthy] decides whether the result
/// is good enough to use without a model's help.
class HeuristicQuestionPaperParser implements QuestionPaperExtractor {
  const HeuristicQuestionPaperParser();

  @override
  String get fingerprint => 'heuristic-paper:v3';

  static final RegExp _pageMarker = RegExp(r'^---\s*Page\s+\d+\s*---$');
  static final RegExp _section = RegExp(
    r'^(?:SECTION|Section|PART|Part)\s+([A-Z]|[0-9]{1,2}|[IVX]{1,4})\b\s*[-–—:.]?\s*(.*)$',
  );
  static final RegExp _total = RegExp(
    r'(?:total|maximum)\s+(?:number\s+of\s+)?marks?(?:\s+(?:available|for\s+this\s+paper))?\s*[:=]?\s*(\d+(?:\.\d+)?)',
    caseSensitive: false,
  );
  static final RegExp _marksBracketed = RegExp(
    r'[\[(]\s*(\d+(?:\.\d+)?)\s*(?:marks?|mks?|m)?\s*[\])]\s*$',
    caseSensitive: false,
  );
  static final RegExp _marksWords = RegExp(
    r'\b(\d+(?:\.\d+)?)\s*marks?\s*[.)\]]?\s*$',
    caseSensitive: false,
  );
  static final RegExp _explicitPrefix =
      RegExp(r'^' + QuestionLabel.prefixPattern + r'\d', caseSensitive: false);
  static final RegExp _partOnly =
      RegExp(r'^\(\s*([a-z]|[ivx]{1,4})\s*\)\s*(.*)$');
  static final RegExp _partLetterDot = RegExp(r'^([a-z])[.)]\s+(.*)$');
  static final RegExp _endOfPaper =
      RegExp(r'^(?:end\s+of\s+(?:paper|exam|questions)|total\s+for\s+paper)', caseSensitive: false);

  /// Opens a question's own mark scheme on a paper that prints one inline:
  /// `Answer: …`, `Mark scheme:`, `Marking points —`.
  static final RegExp _schemeHeader = RegExp(
    r'^(?:answers?|ans\.?|model\s+answers?|expected\s+answers?|suggested\s+answers?|mark(?:ing)?\s+schemes?|mark(?:ing)?\s+points?|solutions?|scheme)\s*(?:[:\-–—]\s*(.*))?$',
    caseSensitive: false,
  );

  /// A heading in capitals that opens a separate mark scheme or answer key —
  /// at the end of the paper, or as the title of a scheme-only document.
  static final RegExp _schemeHeading = RegExp(
    r'^(?:MARK(?:ING)?\s+SCHEMES?|ANSWERS|ANSWER\s+KEY|SOLUTIONS|MODEL\s+ANSWERS)\s*(?:$|[(\[\-–—].*$)',
  );
  static final RegExp _generalGuidance = RegExp(
    r'^general\s+marking\s+(?:guidance|instructions|principles|notes)\b',
    caseSensitive: false,
  );

  /// Wording that belongs to a mark scheme, not to a question.
  static final RegExp _schemeCue = RegExp(
    r'\b(?:do\s+not\s+accept|accept|reject)\b|\baward\b.*\bmarks?\b',
    caseSensitive: false,
  );
  static final RegExp _schemeCodes = RegExp(r'\b[MAB][1-9]\b');

  /// A line that is nothing but "OR": `OR`, `(OR)`, `– or –`.
  static final RegExp _orLine = RegExp(
    r'^[\-–—(\[]*\s*or\s*[\-–—)\]]*$',
    caseSensitive: false,
  );

  /// "Answer any five questions", "Answer any two of the following".
  static final RegExp _anyN = RegExp(
    r'\battempt\s+any\s+(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\b|'
    r'\banswer\s+any\s+(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\b',
    caseSensitive: false,
  );
  static const List<String> _numberWords = <String>[
    'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten',
  ];

  /// A numbered line with no part after its number: `2. States that…`.
  static final RegExp _numbered = RegExp(
    r'^(\d{1,2})(\s*[.)])?\s+(?!\(?\s*(?:[a-z]|[ivx]{1,4})\s*\))\S',
  );

  @override
  Future<QuestionPaper> extract(
    QuestionPaperSourceData source, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    return parse(source.text ?? '', documentId: source.document.contentHash);
  }

  /// Parses [text]. Pure; used directly by tests.
  ///
  /// A paper may print its own mark scheme — under each question, or in a
  /// section of its own after the questions — and a document may be nothing
  /// but a scheme. Scheme text goes to the question it belongs to, never into
  /// its wording, and never changes what the question is worth. Where scheme
  /// text could not be told apart from the questions, the paper is reported
  /// and not trusted, so a model reads it instead.
  QuestionPaper parse(String text, {String documentId = ''}) {
    final List<QuestionSection> sections = <QuestionSection>[];
    final List<FlatQuestion> flat = <FlatQuestion>[];
    final List<String> titleLines = <String>[];
    final List<String> guidanceLines = <String>[];
    final List<String> notes = <String>[];
    double? statedTotal;

    String? sectionId;
    String sectionTitle = '';
    double? sectionMarks;
    final StringBuffer sectionInstructions = StringBuffer();

    FlatQuestion? current;
    QuestionLabel? lastLabel;
    bool ended = false;

    // The mark scheme, when the paper prints one.
    bool schemeOnly = false; // The whole document is a scheme.
    bool appendix = false; // Reading a scheme printed after the questions.
    bool inScheme = false; // Reading the current question's scheme.
    bool inGuidance = false; // Reading general marking guidance.
    int? lastPoint; // The last numbered marking point in this scheme.
    _NumberStyle? questionStyle;
    _NumberStyle? pointStyle; // How the scheme numbers its points.
    bool ambiguous = false;
    bool cuesInWording = false;

    // Choices the paper offers.
    QuestionLabel? pendingOr; // The label read before an OR line.
    bool unlabelledOr = false;
    final List<({QuestionLabel before, QuestionLabel after})> ors =
        <({QuestionLabel before, QuestionLabel after})>[];
    // "Answer any N": by section (null: the whole paper), and by question.
    final Map<String?, ({int count, String text})> anyInSection =
        <String?, ({int count, String text})>{};
    final Map<String, ({int count, String text})> anyInQuestion =
        <String, ({int count, String text})>{};

    ({int count, String text})? anyOf(String line) {
      final RegExpMatch? match = _anyN.firstMatch(line);
      if (match == null) return null;
      final String word = (match.group(1) ?? match.group(2))!.toLowerCase();
      final int count = int.tryParse(word) ?? _numberWords.indexOf(word) + 1;
      return count < 1 ? null : (count: count, text: line);
    }

    void closeSection() {
      if (sectionId == null) return;
      sections.add(
        QuestionSection(
          sectionId: sectionId,
          title: sectionTitle,
          instructions: sectionInstructions.toString().trim(),
          statedMarks: sectionMarks,
        ),
      );
      sectionInstructions.clear();
    }

    void addScheme(FlatQuestion question, String line) {
      final String body = line.trim();
      if (body.isEmpty) return;
      question.markScheme =
          question.markScheme.isEmpty ? body : '${question.markScheme}\n$body';
    }

    /// Whether a line in a scheme is one of its numbered marking points
    /// rather than the next question.
    bool isPoint(String line) {
      final RegExpMatch? numbered = _numbered.firstMatch(line);
      if (numbered == null) return false;
      final int number = int.parse(numbered.group(1)!);
      final _NumberStyle style =
          numbered.group(2) == null ? _NumberStyle.plain : _NumberStyle.dotted;
      // Questions numbered "Question 2" or "Q2", or in another style from
      // this line: the line is a point.
      if (questionStyle == null ||
          questionStyle == _NumberStyle.explicit ||
          style != questionStyle) {
        pointStyle ??= style;
        lastPoint = number;
        return true;
      }
      // The scheme numbers its points differently: this is a question.
      if (pointStyle != null && pointStyle != style) return false;
      // Numbered the same way as the questions: only the sequence can tell.
      if (number == 1 || number == (lastPoint ?? 0) + 1) {
        final int? lastMajor = lastLabel == null ? null : int.tryParse(lastLabel.major);
        if (lastMajor != null && number == lastMajor + 1) ambiguous = true;
        pointStyle ??= style;
        lastPoint = number;
        return true;
      }
      return false;
    }

    for (final String rawLine in text.split('\n')) {
      final String line = rawLine.trim();
      if (line.isEmpty || _pageMarker.hasMatch(line)) continue;
      if (RegExp(r'^[-=_*·.]{4,}$').hasMatch(line)) continue;

      if (_schemeHeading.hasMatch(line)) {
        if (flat.isEmpty) {
          schemeOnly = true;
          titleLines.add(line);
        } else {
          appendix = true;
          ended = false;
          current = null;
          inScheme = false;
          inGuidance = false;
          lastPoint = null;
        }
        continue;
      }
      if (ended) continue;
      if (_endOfPaper.hasMatch(line)) {
        ended = true;
        continue;
      }
      if (_generalGuidance.hasMatch(line) && current == null) {
        inGuidance = true;
        continue;
      }

      if (appendix) {
        // Scheme text only: it attaches to questions already read, and
        // changes neither their wording nor their marks.
        if (_section.hasMatch(line)) continue;
        if (current != null && isPoint(line)) {
          addScheme(current, line);
          continue;
        }
        final ({QuestionLabel label, String rest})? start =
            _labelAt(line, current?.label ?? lastLabel);
        final FlatQuestion? target = start == null
            ? null
            : flat.where((FlatQuestion q) => q.label.key == start.label.key).firstOrNull;
        if (start != null && target != null) {
          current = target;
          inGuidance = false;
          lastPoint = null;
          addScheme(target, _stripMarks(start.rest));
        } else if (inGuidance || current == null) {
          if (inGuidance) guidanceLines.add(line);
        } else {
          addScheme(current, line);
        }
        continue;
      }

      final RegExpMatch? total = _total.firstMatch(line);
      if (total != null && current == null && sectionId == null) {
        statedTotal ??= double.tryParse(total.group(1)!);
      }

      final RegExpMatch? section = _section.firstMatch(line);
      if (section != null) {
        closeSection();
        sectionId = section.group(1)!;
        final String rest = section.group(2) ?? '';
        sectionMarks = _marksIn(rest);
        sectionTitle = _stripMarks(rest).replaceAll(RegExp(r'^[-–—:\s]+'), '').trim();
        if (anyOf(rest) case final ({int count, String text}) any) {
          anyInSection[sectionId] = any;
        }
        current = null;
        inScheme = false;
        inGuidance = false;
        pendingOr = null;
        continue;
      }

      // An OR between two questions or parts, standing on its own line. In a
      // mark scheme an OR is an alternative answer, and is scheme text.
      if (_orLine.hasMatch(line) && current != null && !inScheme) {
        pendingOr = lastLabel;
        continue;
      }

      if (current != null && !schemeOnly) {
        final RegExpMatch? header = _schemeHeader.firstMatch(line);
        if (header != null) {
          inScheme = true;
          lastPoint = null;
          addScheme(current, header.group(1) ?? '');
          continue;
        }
      }

      if (inScheme && current != null && isPoint(line)) {
        addScheme(current, line);
        continue;
      }

      final ({QuestionLabel label, String rest})? start =
          _questionStart(line, lastLabel);
      if (start != null &&
          !(inScheme && _partOnlyLine(line) && !_nextSibling(start.label, current?.label))) {
        final FlatQuestion question = FlatQuestion(
          label: start.label,
          sectionId: sectionId,
          text: schemeOnly ? '' : _stripMarks(start.rest),
          marks: _marksIn(start.rest),
        );
        if (schemeOnly) addScheme(question, _stripMarks(start.rest));
        if (pendingOr case final QuestionLabel before) {
          ors.add((before: before, after: start.label));
          pendingOr = null;
        }
        if (!schemeOnly) {
          if (anyOf(start.rest) case final ({int count, String text}) any) {
            anyInQuestion[start.label.key] = any;
          }
        }
        flat.add(question);
        current = question;
        lastLabel = start.label;
        questionStyle ??= _styleOf(line);
        inScheme = schemeOnly;
        inGuidance = false;
        lastPoint = null;
        continue;
      }

      if (current != null) {
        if (inScheme) {
          addScheme(current, line);
          continue;
        }
        if (_schemeCue.hasMatch(line) || _schemeCodes.allMatches(line).length >= 2) {
          cuesInWording = true;
        }
        if (pendingOr != null) {
          // An alternative with no number or letter of its own.
          unlabelledOr = true;
          pendingOr = null;
        }
        if (anyOf(line) case final ({int count, String text}) any) {
          anyInQuestion[current.label.key] = any;
        }
        final double? marks = _marksIn(line);
        if (marks != null) current.marks = marks;
        final String body = _stripMarks(line);
        if (body.isNotEmpty) {
          current.text = current.text.isEmpty ? body : '${current.text} $body';
        }
      } else if (inGuidance) {
        guidanceLines.add(line);
      } else if (sectionId != null) {
        sectionInstructions.writeln(line);
        if (anyOf(line) case final ({int count, String text}) any) {
          anyInSection[sectionId] = any;
        }
      } else {
        titleLines.add(line);
        if (anyOf(line) case final ({int count, String text}) any) {
          anyInSection[null] = any;
        }
      }
    }
    closeSection();

    if (unlabelledOr) {
      notes.add(
        'The question paper has an OR alternative with no number or letter of '
        'its own, so which question it belongs to could not be read reliably.',
      );
    }
    final List<FlatChoice> choices = <FlatChoice>[
      ..._orChoices(ors, flat, notes),
      ..._anyChoices(anyInSection, anyInQuestion, flat),
    ];

    if (cuesInWording) {
      notes.add(
        'The question paper seems to include marking notes ("accept", '
        '"award…") that could not be separated from the questions\' wording.',
      );
    }
    if (ambiguous) {
      notes.add(
        'The mark scheme on the question paper numbers its points the same way '
        'as the questions, so where one question ends and the next begins may '
        'have been misread.',
      );
    }

    final ({List<Question> questions, List<String> warnings, List<QuestionChoice> choices})
        tree = const QuestionTreeBuilder().build(
      flat,
      sections: sections,
      statedTotal: statedTotal,
      choices: choices,
    );

    return QuestionPaper(
      documentId: documentId,
      title: titleLines.take(3).join(' · '),
      sections: sections,
      questions: tree.questions,
      statedTotal: statedTotal,
      source: QuestionPaperSource.parsed,
      warnings: <String>[...tree.warnings, ...notes],
      markingGuidance: guidanceLines.join('\n'),
      choices: tree.choices,
    );
  }

  /// Every question and part the paper names, under its parent, in order —
  /// parents included even where only their parts were printed.
  static Map<String, List<QuestionLabel>> _siblings(List<FlatQuestion> flat) {
    final Map<String, List<QuestionLabel>> byParent = <String, List<QuestionLabel>>{};
    void add(QuestionLabel label) {
      final QuestionLabel? parent = label.parent;
      if (parent != null) add(parent);
      final List<QuestionLabel> list = byParent.putIfAbsent(parent?.key ?? '', () => <QuestionLabel>[]);
      if (!list.contains(label)) list.add(label);
    }

    for (final FlatQuestion question in flat) {
      add(question.label);
    }
    return byParent;
  }

  /// The choices the OR lines make.
  ///
  /// Between whole questions an OR joins the question before it to the one
  /// after. Between parts it may join two groups — `a) b) OR c) d)` — or just
  /// the neighbours, `a) b) OR c)`; the tree builder keeps whichever makes
  /// the alternatives worth the same.
  static List<FlatChoice> _orChoices(
    List<({QuestionLabel before, QuestionLabel after})> ors,
    List<FlatQuestion> flat,
    List<String> notes,
  ) {
    final Map<String, List<QuestionLabel>> siblings = _siblings(flat);
    // For each parent, the positions among its parts where an OR falls.
    final Map<String, Set<int>> cuts = <String, Set<int>>{};
    for (final ({QuestionLabel before, QuestionLabel after}) or in ors) {
      // The OR is between the two labels at the level where they part:
      // 2(a)(ii) OR 2(b)(i) is 2(a) or 2(b).
      int level = 0;
      while (level < or.before.depth &&
          level < or.after.depth &&
          or.before.parts[level] == or.after.parts[level]) {
        level++;
      }
      final bool apart = level < or.before.depth && level < or.after.depth;
      final QuestionLabel before = QuestionLabel(or.before.parts.sublist(0, level + 1));
      final QuestionLabel after = apart
          ? QuestionLabel(or.after.parts.sublist(0, level + 1))
          : or.after;
      final String parent = after.parent?.key ?? '';
      final int at = siblings[parent]?.indexOf(after) ?? -1;
      if (!apart || at < 1 || siblings[parent]![at - 1] != before) {
        notes.add(
          'An OR before ${or.after.display} could not be matched to the '
          'question it is an alternative to.',
        );
        continue;
      }
      cuts.putIfAbsent(parent, () => <int>{}).add(at);
    }

    final List<FlatChoice> choices = <FlatChoice>[];
    for (final MapEntry<String, Set<int>> entry in cuts.entries) {
      final List<QuestionLabel> parts = siblings[entry.key]!;
      final List<int> at = entry.value.toList()..sort();

      // Runs of ORs in a row: a OR b OR c.
      final List<List<int>> chains = <List<int>>[];
      for (final int cut in at) {
        if (chains.isNotEmpty && chains.last.last == cut - 1) {
          chains.last.add(cut);
        } else {
          chains.add(<int>[cut]);
        }
      }
      List<List<QuestionLabel>> neighbours(List<int> chain) => <List<QuestionLabel>>[
            <QuestionLabel>[parts[chain.first - 1]],
            for (final int cut in chain) <QuestionLabel>[parts[cut]],
          ];

      final bool topLevel = entry.key.isEmpty;
      if (topLevel || chains.length > 1) {
        for (final List<int> chain in chains) {
          choices.add(FlatChoice(options: neighbours(chain)));
        }
        continue;
      }
      final List<int> bounds = <int>[0, ...at, parts.length];
      final List<List<QuestionLabel>> groups = <List<QuestionLabel>>[
        for (int k = 0; k + 1 < bounds.length; k++) parts.sublist(bounds[k], bounds[k + 1]),
      ];
      final List<List<QuestionLabel>> single = neighbours(chains.single);
      final bool same = groups.every((List<QuestionLabel> g) => g.length == 1);
      choices.add(FlatChoice(options: groups, alternative: same ? null : single));
    }
    return choices;
  }

  /// The choices "answer any N" makes: among a section's questions, the whole
  /// paper's, or one question's parts.
  static List<FlatChoice> _anyChoices(
    Map<String?, ({int count, String text})> inSection,
    Map<String, ({int count, String text})> inQuestion,
    List<FlatQuestion> flat,
  ) {
    final Map<String, List<QuestionLabel>> siblings = _siblings(flat);
    final List<FlatChoice> choices = <FlatChoice>[];

    void add(List<QuestionLabel> options, ({int count, String text}) any) {
      if (options.length <= any.count) return;
      choices.add(FlatChoice(
        options: <List<QuestionLabel>>[for (final QuestionLabel l in options) <QuestionLabel>[l]],
        choose: any.count,
        instruction: any.text,
      ));
    }

    for (final MapEntry<String?, ({int count, String text})> entry in inSection.entries) {
      final List<QuestionLabel> top = siblings[''] ?? const <QuestionLabel>[];
      add(
        entry.key == null
            ? top
            : <QuestionLabel>[
                for (final QuestionLabel label in top)
                  if (flat.any((FlatQuestion q) =>
                      q.label.isWithin(label) && q.sectionId == entry.key))
                    label,
              ],
        entry.value,
      );
    }
    for (final MapEntry<String, ({int count, String text})> entry in inQuestion.entries) {
      add(siblings[entry.key] ?? const <QuestionLabel>[], entry.value);
    }
    return choices;
  }

  /// Whether [paper] can be used without a model's help: it found questions,
  /// every markable question has printed marks, and the totals agree.
  static bool isTrustworthy(QuestionPaper paper) {
    if (paper.markable.isEmpty) return false;
    if (paper.markable.any((Question q) => q.maximumMarks == null)) return false;
    return paper.warnings.isEmpty;
  }

  /// The label a line starts with, when it plausibly starts a question.
  ///
  /// Plausibility is what keeps prose out: the number must continue the
  /// sequence (the same question for a new part, or one of the next few), or
  /// carry an explicit `Q`/`Question`, and must be followed by the question's
  /// wording rather than more digits.
  ({QuestionLabel label, String rest})? _questionStart(
    String line,
    QuestionLabel? last,
  ) {
    // A part with no number: "(b) Explain…", "b) Explain…", "(ii) Show…".
    final RegExpMatch? partOnly =
        _partOnly.firstMatch(line) ?? _partLetterDot.firstMatch(line);
    if (partOnly != null && last != null) {
      final String part = partOnly.group(1)!.toLowerCase();
      final QuestionLabel? label = _placePart(part, last);
      if (label != null) {
        final String rest = partOnly.group(2) ?? '';
        // "(b) (i) Describe…": the part and its first sub-part on one line.
        final RegExpMatch? sub = _partOnly.firstMatch(rest);
        if (sub != null && label.depth == 2) {
          return (label: label.child(sub.group(1)!), rest: sub.group(2) ?? '');
        }
        return (label: label, rest: rest);
      }
    }

    final QuestionLabel? label = QuestionLabel.parse(line);
    if (label == null) return null;

    final RegExpMatch? consumed = _labelPrefix.firstMatch(line);
    final String rest = consumed == null
        ? ''
        : line.substring(consumed.end).replaceFirst(RegExp(r'^[.):\]\s-]+'), '');

    final bool explicit = _explicitPrefix.hasMatch(line);
    final int major = int.parse(label.major);
    final int? lastMajor = last == null ? null : int.tryParse(last.major);

    final bool continuesSequence = lastMajor == null
        ? major <= 3
        : (major == lastMajor && label.depth > 1) ||
            (major > lastMajor && major <= lastMajor + 3);
    if (!explicit && !continuesSequence) return null;

    // The wording must follow: a capital, a bracket, a quote — or nothing at
    // all, when the label stands on a line of its own.
    if (rest.isNotEmpty && !RegExp(r'''^[A-Z(\["'“‘]''').hasMatch(rest)) {
      return null;
    }
    return (label: label, rest: rest);
  }

  static final RegExp _labelPrefix = RegExp(
    <String>[
      r'^\s*(?:',
      QuestionLabel.prefixPattern,
      r')?\d{1,3}(?:\s*[.\-]?\s*\(?\s*(?:[a-z]|[ivx]{1,4})\s*\)){0,2}(?:[a-z](?![a-z]))?',
    ].join(),
    caseSensitive: false,
  );

  /// Where a bare part label belongs, given the label before it.
  QuestionLabel? _placePart(String part, QuestionLabel last) {
    final bool roman = QuestionLabel.isRoman(part);
    final String? lastPart = last.depth >= 2 ? last.parts[1] : null;
    final String? lastSub = last.depth >= 3 ? last.parts[2] : null;

    // (i) straight after (h) is a letter; otherwise roman numerals nest under
    // the current lettered part when there is one.
    final bool letterSequence = lastPart != null &&
        !QuestionLabel.isRoman(lastPart) &&
        part.length == 1 &&
        part.codeUnitAt(0) == lastPart.codeUnitAt(0) + 1;

    if (roman && !letterSequence && lastPart != null && !QuestionLabel.isRoman(lastPart)) {
      return QuestionLabel(<String>[last.major, lastPart, part]);
    }
    if (roman && lastSub != null && !letterSequence) {
      return QuestionLabel(<String>[last.major, lastPart!, part]);
    }
    return QuestionLabel(<String>[last.major, part]);
  }

  /// A label at the start of a line, with no judgement of whether it is
  /// plausible — for a scheme, whose labels name questions already read.
  ({QuestionLabel label, String rest})? _labelAt(String line, QuestionLabel? last) {
    final RegExpMatch? partOnly =
        _partOnly.firstMatch(line) ?? _partLetterDot.firstMatch(line);
    if (partOnly != null && last != null) {
      final QuestionLabel? label = _placePart(partOnly.group(1)!.toLowerCase(), last);
      if (label != null) return (label: label, rest: partOnly.group(2) ?? '');
    }
    final QuestionLabel? label = QuestionLabel.parse(line);
    if (label == null) return null;
    final RegExpMatch? consumed = _labelPrefix.firstMatch(line);
    final String rest = consumed == null
        ? ''
        : line.substring(consumed.end).replaceFirst(RegExp(r'^[.):\]\s-]+'), '');
    return (label: label, rest: rest);
  }

  bool _partOnlyLine(String line) =>
      _partOnly.hasMatch(line) || _partLetterDot.hasMatch(line);

  /// Whether [label] is the part straight after [current]: `2(b)` after
  /// `2(a)`, `3(a)(ii)` after `3(a)(i)`.
  static bool _nextSibling(QuestionLabel label, QuestionLabel? current) {
    if (current == null || label.depth != current.depth || label.depth < 2) {
      return false;
    }
    if (label.parent?.key != current.parent?.key) return false;
    final String now = current.parts.last;
    final String next = label.parts.last;
    final int romanNow = _romans.indexOf(now);
    if (romanNow >= 0 && _romans.indexOf(next) == romanNow + 1) return true;
    return now.length == 1 &&
        next.length == 1 &&
        next.codeUnitAt(0) == now.codeUnitAt(0) + 1;
  }

  static const List<String> _romans = <String>[
    'i', 'ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix', 'x',
  ];

  static _NumberStyle _styleOf(String line) {
    if (_explicitPrefix.hasMatch(line)) return _NumberStyle.explicit;
    return RegExp(r'^\d{1,3}\s*[.)]').hasMatch(line)
        ? _NumberStyle.dotted
        : _NumberStyle.plain;
  }

  static double? _marksIn(String line) {
    final RegExpMatch? match =
        _marksBracketed.firstMatch(line) ?? _marksWords.firstMatch(line);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  static String _stripMarks(String line) => line
      .replaceFirst(_marksBracketed, '')
      .replaceFirst(_marksWords, '')
      .trim();
}

/// How a paper numbers its questions: `Question 2`/`Q2`, `2.`, or `2`.
enum _NumberStyle { explicit, dotted, plain }
