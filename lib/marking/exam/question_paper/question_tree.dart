import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';

/// One question or part as read off the page, before the hierarchy is built.
class FlatQuestion {
  FlatQuestion({
    required this.label,
    this.sectionId,
    this.text = '',
    this.marks,
    this.markScheme = '',
  });

  final QuestionLabel label;
  final String? sectionId;
  String text;

  /// The paper's own mark scheme for this question, when it prints one.
  String markScheme;

  /// As printed; null when the paper printed no marks for it.
  double? marks;
}

/// A choice as read off the page: answer [choose] of these options, each a
/// group of sibling questions.
///
/// A paper printing `11 a) [6] b) [6] OR c) [4] d) [8]` could mean {a, b} or
/// {c, d}, or a and (b or c) and d. [options] is the first reading and
/// [alternative] the second; the builder keeps whichever makes the options
/// worth the same.
class FlatChoice {
  FlatChoice({
    required this.options,
    this.alternative,
    this.choose = 1,
    this.instruction = '',
  });

  final List<List<QuestionLabel>> options;
  final List<List<QuestionLabel>>? alternative;
  int choose;
  String instruction;
}

/// Builds the question hierarchy from a flat list in paper order, and checks
/// the marks add up.
///
/// Shared by the deterministic parser and the model extractor, so both are
/// held to the same rules: parts sit under their question, a question's total
/// is the sum of its parts, and any printed total that disagrees is reported.
class QuestionTreeBuilder {
  const QuestionTreeBuilder();

  ({List<Question> questions, List<String> warnings, List<QuestionChoice> choices})
      build(
    List<FlatQuestion> flat, {
    List<QuestionSection> sections = const <QuestionSection>[],
    double? statedTotal,
    List<FlatChoice> choices = const <FlatChoice>[],
  }) {
    final List<String> warnings = <String>[];
    final Map<String, _Node> nodes = <String, _Node>{};
    final List<_Node> roots = <_Node>[];

    _Node nodeFor(QuestionLabel label, String? section) {
      final _Node? existing = nodes[label.key];
      if (existing != null) return existing;
      final _Node node = _Node(label, section);
      nodes[label.key] = node;
      final QuestionLabel? parent = label.parent;
      if (parent == null) {
        roots.add(node);
      } else {
        nodeFor(parent, section).children.add(node);
      }
      return node;
    }

    for (final FlatQuestion question in flat) {
      final _Node node = nodeFor(question.label, question.sectionId);
      if (question.text.trim().isNotEmpty) {
        node.text = node.text.isEmpty
            ? question.text.trim()
            : '${node.text}\n${question.text.trim()}';
      }
      if (question.markScheme.trim().isNotEmpty) {
        node.markScheme = node.markScheme.isEmpty
            ? question.markScheme.trim()
            : '${node.markScheme}\n${question.markScheme.trim()}';
      }
      if (question.marks != null) node.marks = question.marks;
      node.section ??= question.sectionId;
    }

    final List<_Choice> resolved = _resolveChoices(choices, nodes, warnings);
    _Choice? choiceOf(QuestionLabel label) {
      for (final _Choice choice in resolved) {
        if (choice.all.contains(label.key)) return choice;
      }
      return null;
    }

    final Set<_Choice> uneven = <_Choice>{};

    /// What [siblings] are worth together, a choice counting only its
    /// [_Choice.choose] most valuable options; null when any is unknown.
    double? worth(List<Question> siblings, String where) {
      if (siblings.any((Question q) => q.maximumMarks == null)) return null;
      final Map<String, double> marks = <String, double>{
        for (final Question q in siblings) q.label.key: q.maximumMarks!,
      };
      double groupWorth(List<String> group) =>
          group.fold<double>(0, (double sum, String key) => sum + (marks[key] ?? 0));

      double total = 0;
      final Set<_Choice> seen = <_Choice>{};
      for (final Question question in siblings) {
        final _Choice? choice = choiceOf(question.label);
        if (choice == null) {
          total += question.maximumMarks!;
          continue;
        }
        if (!seen.add(choice)) continue;
        choice.decide(groupWorth);
        // Siblings the chosen grouping leaves outside every option still
        // count in full: `a` and `d` in "a, (b or c), d".
        for (final String key in choice.all) {
          if (!choice.options.any((List<String> o) => o.contains(key))) {
            total += marks[key] ?? 0;
          }
        }
        final List<double> values = choice.options.map(groupWorth).toList()
          ..sort((double a, double b) => b.compareTo(a));
        if (values.toSet().length > 1 && uneven.add(choice)) {
          warnings.add(
            '$where: the alternatives '
            '${choice.options.map((List<String> o) => o.map((String k) => QuestionLabel.fromKey(k).display).join(' and ')).join(' / ')} '
            'carry different marks (${choice.options.map((List<String> o) => formatMarks(groupWorth(o))).join(', ')}).',
          );
        }
        total += values.take(choice.choose).fold<double>(0, (double a, double b) => a + b);
      }
      return total;
    }

    Question toQuestion(_Node node) {
      final List<Question> parts = node.children.map(toQuestion).toList();
      double? maximum = node.marks;
      bool stated = node.marks != null;

      if (parts.isNotEmpty) {
        final double? sum = worth(parts, 'Question ${node.label.display}');
        if (maximum != null && sum != null && (maximum - sum).abs() > 0.001) {
          warnings.add(
            'Question ${node.label.display}: the paper prints '
            '${formatMarks(maximum)} marks, but its parts add up to '
            '${formatMarks(sum)}. The parts were used.',
          );
        }
        if (sum != null) {
          maximum = sum;
          stated = parts.every((Question part) => part.marksStated);
        }
      } else if (maximum == null) {
        warnings.add(
          'Question ${node.label.display}: the question paper prints no marks '
          'for it.',
        );
      }

      return Question(
        label: node.label,
        questionText: node.text,
        sectionId: node.section,
        maximumMarks: maximum,
        marksStated: stated,
        markScheme: node.markScheme,
        subQuestions: parts,
      );
    }

    final List<Question> questions = roots.map(toQuestion).toList();

    // Section totals, where printed.
    for (final QuestionSection section in sections) {
      final double? stated = section.statedMarks;
      if (stated == null) continue;
      final List<Question> members = questions
          .where((Question q) => q.sectionId == section.sectionId)
          .toList();
      if (members.isEmpty) continue;
      final double? sum = worth(members, 'Section ${section.sectionId}');
      if (sum == null) continue;
      if ((sum - stated).abs() > 0.001) {
        warnings.add(
          'Section ${section.sectionId}: the paper prints '
          '${formatMarks(stated)} marks, but its questions add up to '
          '${formatMarks(sum)}.',
        );
      }
    }

    // Always worked out, so a choice between whole questions is checked
    // even on a paper that prints no total.
    final double? sum = questions.isEmpty ? null : worth(questions, 'The paper');
    if (statedTotal != null) {
      if (sum != null && (sum - statedTotal).abs() > 0.001) {
        warnings.add(
          'The paper states a total of ${formatMarks(statedTotal)} marks, but '
          'its questions add up to ${formatMarks(sum)}.',
        );
      }
    }

    return (
      questions: questions,
      warnings: warnings.toSet().toList(),
      choices: <QuestionChoice>[
        for (final _Choice choice in resolved)
          QuestionChoice(
            options: <List<String>>[
              for (final List<String> option in choice.options)
                <String>[for (final String key in option) QuestionLabel.fromKey(key).questionId],
            ],
            choose: choice.choose,
            instruction: choice.instruction,
          ),
      ],
    );
  }

  /// Keeps the choices that make sense: options the paper has, all siblings
  /// of one another, each question in only one choice, and fewer chosen than
  /// offered.
  static List<_Choice> _resolveChoices(
    List<FlatChoice> choices,
    Map<String, _Node> nodes,
    List<String> warnings,
  ) {
    final List<_Choice> kept = <_Choice>[];
    final Set<String> taken = <String>{};

    List<List<String>>? groups(List<List<QuestionLabel>>? options) {
      if (options == null) return null;
      final List<List<String>> result = <List<String>>[];
      for (final List<QuestionLabel> option in options) {
        final List<String> keys = <String>[];
        for (final QuestionLabel label in option) {
          if (!nodes.containsKey(label.key)) {
            warnings.add('An alternative (${label.display}) is not a question on the paper.');
            continue;
          }
          if (taken.contains(label.key) || result.any((List<String> o) => o.contains(label.key))) {
            continue;
          }
          keys.add(label.key);
        }
        if (keys.isNotEmpty) result.add(keys);
      }
      return result.length < 2 ? null : result;
    }

    for (final FlatChoice choice in choices) {
      final List<List<String>>? options = groups(choice.options);
      if (options == null) continue;
      final List<List<String>>? alternative = groups(choice.alternative);
      final Set<String> all = <String>{...options.expand((List<String> o) => o), ...?alternative?.expand((List<String> o) => o)};
      final Set<String?> parents = <String?>{
        for (final String key in all) QuestionLabel.fromKey(key).parent?.key,
      };
      if (parents.length > 1) {
        warnings.add(
          'The alternatives '
          '${all.map((String k) => QuestionLabel.fromKey(k).display).join(', ')} '
          'are not parts of the same question.',
        );
        continue;
      }
      if (choice.choose < 1 || choice.choose >= options.length) continue;
      taken.addAll(all);
      kept.add(_Choice(options, alternative, all, choice.choose, choice.instruction));
    }
    return kept;
  }
}

class _Choice {
  _Choice(this.options, this._alternative, this.all, this.choose, this.instruction);

  /// The grouping in use: [_alternative] if [decide] preferred it.
  List<List<String>> options;
  final List<List<String>>? _alternative;

  /// Every question either grouping involves.
  final Set<String> all;
  final int choose;
  final String instruction;
  bool _decided = false;

  /// Keeps the grouping whose options are worth the same, preferring the
  /// first when both or neither are.
  void decide(double Function(List<String> option) worth) {
    if (_decided) return;
    _decided = true;
    final List<List<String>>? alternative = _alternative;
    if (alternative == null) return;
    bool even(List<List<String>> grouping) =>
        grouping.map(worth).map((double v) => v.toStringAsFixed(3)).toSet().length == 1;
    if (!even(options) && even(alternative)) options = alternative;
  }
}

class _Node {
  _Node(this.label, this.section);

  final QuestionLabel label;
  String? section;
  String text = '';
  String markScheme = '';
  double? marks;
  final List<_Node> children = <_Node>[];
}
