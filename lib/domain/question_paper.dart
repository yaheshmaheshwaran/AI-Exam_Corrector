import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/question_label.dart';

/// A section of the question paper, with any instruction that applies to
/// every question in it.
class QuestionSection {
  const QuestionSection({
    required this.sectionId,
    this.title = '',
    this.instructions = '',
    this.statedMarks,
  });

  /// As printed: `A`, `B`, `1`.
  final String sectionId;
  final String title;
  final String instructions;

  /// The section total the paper printed, used to check the questions add up.
  final double? statedMarks;

  JsonMap toJson() => <String, Object?>{
        'sectionId': sectionId,
        'title': title,
        'instructions': instructions,
        'statedMarks': ?statedMarks,
      };

  static QuestionSection? fromJson(JsonMap json) {
    final String? id = readString(json['sectionId']);
    if (id == null) return null;
    return QuestionSection(
      sectionId: id,
      title: readRawString(json['title']) ?? '',
      instructions: readRawString(json['instructions']) ?? '',
      statedMarks: readDouble(json['statedMarks']),
    );
  }
}

/// One question — or one part of one — from the question paper.
///
/// The question paper is the authority on what exists and what it is worth.
/// Nothing on the answer sheet can add a question or change a maximum.
class Question {
  const Question({
    required this.label,
    required this.questionText,
    this.sectionId,
    this.maximumMarks,
    this.marksStated = false,
    this.markScheme = '',
    this.subQuestions = const <Question>[],
  });

  final QuestionLabel label;

  String get questionId => label.questionId;

  /// As the paper prints it: `3`, `2(a)`, `3(b)(ii)`.
  String get displayNumber => label.display;

  String get key => label.key;

  String? get parentId => label.parent?.questionId;

  final String? sectionId;
  final String questionText;

  /// The marks this question carries. For a question with parts, the sum of
  /// its parts unless the paper printed a total of its own.
  final double? maximumMarks;

  /// False when the paper printed no marks and the figure was inferred.
  final bool marksStated;

  /// The mark scheme the paper itself printed for this question — model
  /// answers, marking points, what to accept — kept apart from its wording.
  /// Empty when the paper carries no scheme, which is the usual case.
  final String markScheme;

  bool get hasMarkScheme => markScheme.trim().isNotEmpty;

  final List<Question> subQuestions;

  bool get isLeaf => subQuestions.isEmpty;

  /// The markable units under this question: itself if it has no parts,
  /// otherwise its deepest parts.
  List<Question> get leaves => isLeaf
      ? <Question>[this]
      : <Question>[for (final Question part in subQuestions) ...part.leaves];

  Question copyWith({
    double? Function()? maximumMarks,
    bool? marksStated,
    List<Question>? subQuestions,
    String? questionText,
    String? Function()? sectionId,
    String? markScheme,
  }) {
    return Question(
      label: label,
      questionText: questionText ?? this.questionText,
      sectionId: sectionId == null ? this.sectionId : sectionId(),
      maximumMarks: maximumMarks == null ? this.maximumMarks : maximumMarks(),
      marksStated: marksStated ?? this.marksStated,
      markScheme: markScheme ?? this.markScheme,
      subQuestions: subQuestions ?? this.subQuestions,
    );
  }

  JsonMap toJson() => <String, Object?>{
        'questionId': questionId,
        'displayNumber': displayNumber,
        'key': key,
        'section': ?sectionId,
        'maximumMarks': ?maximumMarks,
        'marksStated': marksStated,
        'questionText': questionText,
        'markScheme': ?(hasMarkScheme ? markScheme : null),
        'subQuestions': <JsonMap>[
          for (final Question part in subQuestions) part.toJson(),
        ],
      };

  static Question? fromJson(JsonMap json) {
    final String? key = readString(json['key']);
    if (key == null) return null;
    return Question(
      label: QuestionLabel.fromKey(key),
      questionText: readRawString(json['questionText']) ?? '',
      sectionId: readString(json['section']),
      maximumMarks: readDouble(json['maximumMarks']),
      marksStated: readBool(json['marksStated']) ?? false,
      markScheme: readRawString(json['markScheme']) ?? '',
      subQuestions: readObjects(json['subQuestions'], Question.fromJson),
    );
  }
}

/// A choice the paper offers: answer [choose] of these options — an OR
/// between two parts or two questions (`choose` 1), or "answer any five".
///
/// Each option is a group of questions at the same level under the same
/// parent: `[11(a)]` or `[11(b)]`; `[11(a), 11(b)]` or `[11(c), 11(d)]` on a
/// paper that prints `11 a) b) OR c) d)`; `[11]` or `[12]`. Every option is
/// marked; which ones count is decided from the answer sheet, and only those
/// reach the total.
class QuestionChoice {
  const QuestionChoice({
    required this.options,
    this.choose = 1,
    this.instruction = '',
  });

  /// Each option's question IDs, in paper order.
  final List<List<String>> options;

  /// How many of the options count.
  final int choose;

  /// As printed, when the paper states it: "Answer any two questions".
  final String instruction;

  /// The option [questionId] heads or belongs to, or -1.
  int optionOf(String questionId) {
    for (int i = 0; i < options.length; i++) {
      if (options[i].contains(questionId)) return i;
    }
    return -1;
  }

  JsonMap toJson() => <String, Object?>{
        'options': options,
        'choose': choose,
        if (instruction.isNotEmpty) 'instruction': instruction,
      };

  static QuestionChoice? fromJson(JsonMap json) {
    final List<List<String>> options = <List<String>>[
      for (final Object? option in readList(json['options']))
        if (readStringList(option) case final List<String> ids when ids.isNotEmpty) ids,
    ];
    if (options.length < 2) return null;
    return QuestionChoice(
      options: options,
      choose: (readInt(json['choose']) ?? 1).clamp(1, options.length - 1),
      instruction: readRawString(json['instruction']) ?? '',
    );
  }
}

/// How the question structure was obtained.
enum QuestionPaperSource {
  /// Parsed deterministically from the text layer.
  parsed,

  /// Extracted by the model from text.
  modelText,

  /// Extracted by the vision model from page images.
  modelVision,
}

/// The normalised structure of a question paper.
class QuestionPaper {
  const QuestionPaper({
    required this.documentId,
    required this.questions,
    this.sections = const <QuestionSection>[],
    this.statedTotal,
    this.title = '',
    this.source = QuestionPaperSource.parsed,
    this.warnings = const <String>[],
    this.markingGuidance = '',
    this.choices = const <QuestionChoice>[],
  });

  final String documentId;
  final String title;

  /// General marking instructions printed with the paper's own mark scheme,
  /// applying to every question. Empty when there are none.
  final String markingGuidance;

  /// The choices the paper offers — OR questions, "answer any N".
  final List<QuestionChoice> choices;
  final List<QuestionSection> sections;

  /// Top-level questions, each carrying its parts.
  final List<Question> questions;

  /// The paper's own printed total, when it has one.
  final double? statedTotal;

  final QuestionPaperSource source;

  /// Inconsistencies found while reading it — a total that does not add up, a
  /// question with no printed marks.
  final List<String> warnings;

  /// Every markable unit, in paper order.
  List<Question> get markable => <Question>[
        for (final Question question in questions) ...question.leaves,
      ];

  /// Whether the paper carries its own mark scheme for any question.
  bool get hasMarkScheme => markSchemeCount > 0;

  /// How many markable questions have a printed scheme — their own, or one
  /// their parent question carries.
  int get markSchemeCount =>
      markable.where((Question q) => markSchemeFor(q).isNotEmpty).length;

  /// The printed scheme that applies to [question]: its ancestors' schemes,
  /// outermost first, then its own.
  String markSchemeFor(Question question) {
    final List<String> parts = <String>[];
    QuestionLabel? label = question.label;
    while (label != null) {
      final Question? found = byLabel(label);
      if (found != null && found.hasMarkScheme) {
        parts.insert(
          0,
          found == question
              ? found.markScheme.trim()
              : '(For ${found.displayNumber} as a whole) ${found.markScheme.trim()}',
        );
      }
      label = label.parent;
    }
    return parts.join('\n');
  }

  /// What the paper is worth: every question, with each choice counting only
  /// as many options as are answered.
  double get totalMarks => worthOf(questions);

  /// What [siblings] are worth together — a choice among them counts only its
  /// [QuestionChoice.choose] most valuable options.
  double worthOf(List<Question> siblings) {
    double total = 0;
    final Set<QuestionChoice> seen = <QuestionChoice>{};
    for (final Question question in siblings) {
      final QuestionChoice? choice = choiceWithOption(question.questionId);
      if (choice == null) {
        total += _worth(question);
      } else if (seen.add(choice)) {
        final List<double> options = <double>[
          for (final List<String> option in choice.options) optionWorth(option),
        ]..sort((double a, double b) => b.compareTo(a));
        total += options.take(choice.choose).fold<double>(0, (double a, double b) => a + b);
      }
    }
    return total;
  }

  /// What one option of a choice is worth.
  double optionWorth(List<String> option) => <Question>[
        for (final String id in option)
          if (byId(id) case final Question question) question,
      ].fold<double>(0, (double sum, Question q) => sum + _worth(q));

  double _worth(Question question) =>
      question.isLeaf ? question.maximumMarks ?? 0 : worthOf(question.subQuestions);

  /// The choice that offers [questionId] as, or within, one of its options at
  /// that question's own level.
  QuestionChoice? choiceWithOption(String questionId) {
    for (final QuestionChoice choice in choices) {
      if (choice.optionOf(questionId) >= 0) return choice;
    }
    return null;
  }

  /// Every choice [questionId] sits inside, innermost first, with the index
  /// of the option it falls under.
  List<({QuestionChoice choice, int option})> choicesOf(String questionId) {
    final Question? question = byId(questionId);
    if (question == null) return const <({QuestionChoice choice, int option})>[];
    final List<({QuestionChoice choice, int option, int depth})> found =
        <({QuestionChoice choice, int option, int depth})>[];
    for (final QuestionChoice choice in choices) {
      for (int i = 0; i < choice.options.length; i++) {
        for (final String id in choice.options[i]) {
          final Question? member = byId(id);
          if (member != null && question.label.isWithin(member.label)) {
            found.add((choice: choice, option: i, depth: member.label.depth));
          }
        }
      }
    }
    found.sort((a, b) => b.depth.compareTo(a.depth));
    return <({QuestionChoice choice, int option})>[
      for (final f in found) (choice: f.choice, option: f.option),
    ];
  }

  /// The markable questions of one option.
  List<Question> leavesOfOption(List<String> option) => <Question>[
        for (final String id in option) ...?byId(id)?.leaves,
      ];

  /// How one option reads: "11(a)", "11(a) and 11(b)".
  String describeOption(List<String> option) =>
      option.map((String id) => byId(id)?.displayNumber ?? id).join(' and ');

  /// How a choice reads: "11(a) or 11(b)", "any 2 of 5, 6, 7".
  String describeChoice(QuestionChoice choice) {
    final List<String> names = choice.options.map(describeOption).toList();
    if (choice.choose == 1 && names.length == 2) return '${names.first} or ${names.last}';
    if (choice.choose == 1) return 'one of ${names.join(', ')}';
    return 'any ${choice.choose} of ${names.join(', ')}';
  }

  Iterable<Question> get _all sync* {
    Iterable<Question> walk(Question question) sync* {
      yield question;
      for (final Question part in question.subQuestions) {
        yield* walk(part);
      }
    }

    for (final Question question in questions) {
      yield* walk(question);
    }
  }

  Question? byId(String questionId) {
    for (final Question question in _all) {
      if (question.questionId == questionId) return question;
    }
    return null;
  }

  Question? byLabel(QuestionLabel label) {
    for (final Question question in _all) {
      if (question.label == label) return question;
    }
    return null;
  }

  QuestionSection? section(String? sectionId) {
    if (sectionId == null) return null;
    for (final QuestionSection section in sections) {
      if (section.sectionId == sectionId) return section;
    }
    return null;
  }

  JsonMap toJson() => <String, Object?>{
        'documentId': documentId,
        'title': title,
        'statedTotal': ?statedTotal,
        'source': source.name,
        'warnings': warnings,
        'markingGuidance': ?(markingGuidance.trim().isEmpty ? null : markingGuidance),
        if (choices.isNotEmpty)
          'choices': <JsonMap>[for (final QuestionChoice c in choices) c.toJson()],
        'sections': <JsonMap>[
          for (final QuestionSection section in sections) section.toJson(),
        ],
        'questions': <JsonMap>[
          for (final Question question in questions) question.toJson(),
        ],
      };

  static QuestionPaper? fromJson(JsonMap json) {
    final String? documentId = readString(json['documentId']);
    if (documentId == null) return null;
    return QuestionPaper(
      documentId: documentId,
      title: readRawString(json['title']) ?? '',
      statedTotal: readDouble(json['statedTotal']),
      source: readEnum(
        QuestionPaperSource.values,
        json['source'],
        QuestionPaperSource.parsed,
      ),
      warnings: readStringList(json['warnings']),
      markingGuidance: readRawString(json['markingGuidance']) ?? '',
      choices: readObjects(json['choices'], QuestionChoice.fromJson),
      sections: readObjects(json['sections'], QuestionSection.fromJson),
      questions: readObjects(json['questions'], Question.fromJson),
    );
  }
}
