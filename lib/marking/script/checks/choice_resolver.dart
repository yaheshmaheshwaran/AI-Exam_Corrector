import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/models/question_result.dart';

/// Decides which options of each choice count towards the total.
///
/// Every option of an OR — or of "answer any N" — is marked, because the
/// answer sheet decides which were attempted. The rule is the one examiners
/// use: the options the student answered first count, and the rest are
/// shown but left out of every total. Where options were answered together
/// under one label, so that neither came first, the one that earned more
/// counts. When fewer were answered than count, unanswered options make up
/// the number, scoring nothing, so the maximum stays what the paper says.
///
/// Pure: the same marks and positions always give the same decision.
class ChoiceResolver {
  const ChoiceResolver();

  /// [firstSeen] gives, for each question with an answer, where on the answer
  /// sheet that answer begins; smaller is earlier.
  List<QuestionResult> resolve(
    QuestionPaper paper,
    List<QuestionResult> results,
    Map<String, int> firstSeen,
  ) {
    if (paper.choices.isEmpty) return results;
    final Map<String, QuestionResult> byId = <String, QuestionResult>{
      for (final QuestionResult result in results) result.questionId: result,
    };

    // Innermost choices first, so an option of an outer choice is judged by
    // the parts of it that count.
    int depthOf(QuestionChoice choice) =>
        paper.byId(choice.options.first.first)?.label.depth ?? 0;
    final List<QuestionChoice> choices = List<QuestionChoice>.of(paper.choices)
      ..sort((QuestionChoice a, QuestionChoice b) => depthOf(b).compareTo(depthOf(a)));

    for (final QuestionChoice choice in choices) {
      final List<_Option> options = <_Option>[];
      for (int index = 0; index < choice.options.length; index++) {
        final List<String> leaves = <String>[
          for (final Question leaf in paper.leavesOfOption(choice.options[index]))
            if (byId[leaf.questionId]?.counted ?? false) leaf.questionId,
        ];
        int? at;
        double awarded = 0;
        for (final String id in leaves) {
          final int? seen = firstSeen[id];
          if (seen != null && (at == null || seen < at)) at = seen;
          awarded += byId[id]!.awardedMarks;
        }
        options.add(_Option(index, paper.describeOption(choice.options[index]), leaves, at, awarded));
      }

      final List<_Option> attempted = options.where((_Option o) => o.at != null).toList()
        ..sort((_Option a, _Option b) {
          final int when = a.at!.compareTo(b.at!);
          if (when != 0) return when;
          final int marks = b.awarded.compareTo(a.awarded);
          return marks != 0 ? marks : a.index.compareTo(b.index);
        });
      final List<_Option> chosen = attempted.take(choice.choose).toList();
      for (final _Option option in options) {
        if (chosen.length >= choice.choose) break;
        if (!chosen.contains(option)) chosen.add(option);
      }

      final String rule = choice.choose == 1
          ? 'only one of ${options.map((_Option o) => o.name).join(' or ')} counts'
          : 'only ${choice.choose} of ${options.map((_Option o) => o.name).join(', ')} count';
      final List<_Option> answeredChosen =
          chosen.where((_Option o) => o.at != null).toList();
      final String chosenNames = answeredChosen.map((_Option o) => o.name).join(' and ');
      final bool together = attempted.length > choice.choose &&
          answeredChosen.isNotEmpty &&
          attempted[choice.choose].at == answeredChosen.last.at;

      for (final _Option option in options) {
        final bool counts = chosen.contains(option);
        String note;
        if (counts) {
          if (attempted.length <= choice.choose) continue;
          note = together
              ? 'Counted. The alternatives were answered together under one '
                  'label; $rule, so the one that earned more counts.'
              : 'Counted. More alternatives were answered than count; $rule, '
                  'so the first answered counts.';
        } else if (option.at != null) {
          note = together
              ? 'Not counted. The alternatives were answered together under '
                  'one label; $rule, and $chosenNames earned more.'
              : 'Not counted: $rule, and $chosenNames '
                  '${answeredChosen.length == 1 ? 'was' : 'were'} answered first.';
        } else {
          note = answeredChosen.isEmpty
              ? 'Not counted: $rule, and none was answered.'
              : 'Not counted: $rule, and $chosenNames '
                  '${answeredChosen.length == 1 ? 'was' : 'were'} answered instead.';
        }
        for (final String id in option.leaves) {
          byId[id] = byId[id]!.copyWith(counted: counts, choiceNote: note);
        }
      }
    }

    return <QuestionResult>[
      for (final QuestionResult result in results) byId[result.questionId] ?? result,
    ];
  }
}

class _Option {
  _Option(this.index, this.name, this.leaves, this.at, this.awarded);

  final int index;
  final String name;
  final List<String> leaves;
  final int? at;
  final double awarded;
}
