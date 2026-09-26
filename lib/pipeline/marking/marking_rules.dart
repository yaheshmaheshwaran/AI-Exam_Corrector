import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/moderation.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/syllabus_match.dart';
import 'package:exam_corrector/pipeline/syllabus/syllabus_index.dart';

/// The arithmetic of a marking standard, applied to the AI's marks.
///
/// Pure and cheap: it runs on every result, freshly marked or from the
/// cache, so changing the mark step, the rounding or the penalty for a wrong
/// multiple-choice answer takes effect without asking the AI again. Every
/// change it makes is written into the result's adjustments — a mark is
/// never quietly altered — and the AI's own mark is kept beside it.
class MarkingRules {
  const MarkingRules(
    this.standard, {
    required this.defaultReviewThreshold,
    this.moderation = Moderation.none,
  });

  final MarkingStandard standard;

  /// The paper's marks brought to the teacher's own marking.
  final Moderation moderation;

  /// The Settings threshold, used by the Balanced level.
  final double defaultReviewThreshold;

  double get reviewThreshold => standard.level.reviewThreshold ?? defaultReviewThreshold;

  QuestionResult apply(QuestionResult result, MarkingTask task) {
    final MarkingLevel level = standard.level;
    final List<String> adjustments = <String>[];
    final List<String> reasons = List<String>.of(result.reviewReasons);
    bool review = result.needsReview;
    final String by = '(${level.label})';

    final double maximum = result.maximumMarks;
    final RealismRules realism = standard.realism;
    final RealismStrictness strictness = realism.strictness;
    final String firmly = '(${strictness.label})';
    final bool mcq = isMcq(task);

    // Strict, or a firm strictness: nothing for a point that rests on an
    // uncertain reading. Strict: no part-marks within a point either.
    List<MarkingPoint> points = result.markingPoints;
    final bool uncertainNothing = level == MarkingLevel.strict || strictness.uncertainEarnsNothing;
    points = <MarkingPoint>[
      for (final MarkingPoint point in points)
        if (uncertainNothing && point.marks > 0 && point.basis == EvidenceBasis.uncertain)
          () {
            adjustments.add('“${point.criterion}” rested on an uncertain reading, '
                'so it earns nothing ${level == MarkingLevel.strict ? by : firmly}.');
            review = true;
            if (!reasons.contains(_uncertain)) reasons.add(_uncertain);
            return point.copyWith(marks: 0, satisfied: false);
          }()
        else if (level == MarkingLevel.strict && point.marks > 0 && point.marks < point.marksAvailable - 1e-9)
          () {
            adjustments.add('“${point.criterion}” was only partly met '
                '(${formatMarks(point.marks)} of ${formatMarks(point.marksAvailable)}), '
                'so it earns nothing $by.');
            return point.copyWith(marks: 0, satisfied: false);
          }()
        else
          point,
    ];

    // A point is credited only for what the answer states: one with none of
    // its key terms anywhere in the answer keeps a part of its marks.
    if (strictness.keyTermFactor < 1 && !mcq) {
      final Set<String> vocabulary = answerVocabulary(result, task);
      if (vocabulary.isNotEmpty) {
        points = <MarkingPoint>[
          for (final MarkingPoint point in points)
            if (_unstated(point, vocabulary) case final List<String> terms)
              () {
                final double kept = point.marks * strictness.keyTermFactor;
                adjustments.add('“${point.criterion}” was credited, but none of its terms '
                    '(${terms.join(', ')}) appear in the answer — '
                    '${kept == 0 ? 'it earns nothing' : 'halved to ${formatMarks(kept)}'} $firmly.');
                return point.copyWith(marks: kept, satisfied: kept > 0);
              }()
            else
              point,
        ];
      }
    }

    double awarded = result.awardedMarks;
    final bool pointsChanged = <int>[
      for (int i = 0; i < points.length; i++)
        if ((points[i].marks - result.markingPoints[i].marks).abs() > 1e-9) i,
    ].isNotEmpty;
    if (pointsChanged) {
      awarded = points
          .fold<double>(0, (double sum, MarkingPoint p) => sum + p.marks)
          .clamp(0, maximum)
          .toDouble();
    } else {
      points = result.markingPoints;
    }

    final bool long = maximum >= RealismRules.longFrom - 1e-9;

    // An answer stays within its quality band.
    final QualityBand? band = result.qualityBand;
    if (realism.bandCap && !mcq && maximum >= strictness.bandFrom - 1e-9 && band != null) {
      final double share = band.shareAt(level, strictness);
      final double cap = maximum * share;
      if (awarded > cap + 1e-9) {
        adjustments.add('Capped at the ${band.label} band — at most ${(share * 100).round()}% of '
            '${formatMarks(maximum)}, so ${formatMarks(cap)}'
            '${result.bandReason.isEmpty ? '' : ': ${result.bandReason}'}.');
        awarded = cap;
      }
    }

    // A long answer far shorter than a full one cannot earn most of the marks.
    if (realism.lengthCap && long && !task.answer.isEmpty) {
      final int words = answerWords(task);
      final double expected = (task.expectedWords?.toDouble() ?? realism.wordsPerMark * maximum)
          .clamp(1, double.infinity)
          .toDouble();
      final double share = RealismRules.lengthShare(words / expected, level, strictness);
      final double cap = maximum * share;
      if (awarded > cap + 1e-9) {
        adjustments.add('Capped for length — about $words words where a full answer is about '
            '${expected.round()}: at most ${(share * 100).round()}% of ${formatMarks(maximum)}, '
            'so ${formatMarks(cap)}.');
        awarded = cap;
      }
    }

    // A short answer far shorter than a full one earns at most half.
    final double? shortBelow = strictness.shortBelow;
    if (realism.lengthCap && shortBelow != null && !long && maximum >= 2 - 1e-9 && !mcq && !task.answer.isEmpty) {
      final int words = answerWords(task);
      final double expected = (task.expectedWords?.toDouble() ?? RealismRules.shortWordsPerMark * maximum)
          .clamp(1, double.infinity)
          .toDouble();
      final double cap = maximum / 2;
      if (words / expected < shortBelow && awarded > cap + 1e-9) {
        adjustments.add('Capped for length — about $words words where a full answer is about '
            '${expected.round()}: at most half of ${formatMarks(maximum)} $firmly.');
        awarded = cap;
      }
    }

    // Full marks only for an answer with every point complete and certain.
    if (realism.fullMarksGate && maximum >= 2 && awarded >= maximum - 1e-9 && !mcq) {
      final String? why = points.any((MarkingPoint p) => p.marks > 1e-9 && p.marks < p.marksAvailable - 1e-9)
          ? 'a point was only partly met'
          : points.any((MarkingPoint p) => p.marks > 0 && p.basis == EvidenceBasis.uncertain)
              ? 'a mark rests on an uncertain reading'
              : result.confidence < reviewThreshold
                  ? 'the marking is not certain enough'
                  : null;
      if (why != null) {
        final double lowered =
            (maximum - strictness.gateDrop(maximum, standard.markStep)).clamp(0, maximum).toDouble();
        adjustments.add('Full marks need every point complete and certain; $why — '
            '${formatMarks(maximum)} lowered to ${formatMarks(lowered)}.');
        awarded = lowered;
      }
    }

    // Brought to the teacher's own marking.
    double? moderatedFrom;
    if (moderation.isActive && !task.answer.isEmpty && awarded > 0) {
      final double moderated =
          (awarded * moderation.factorFor(maximum, result.section)).clamp(0, maximum).toDouble();
      if ((moderated - awarded).abs() > 1e-9) {
        adjustments.add(moderation.describe(awarded, moderated, maximum, result.section));
        moderatedFrom = awarded;
        awarded = moderated;
      }
    }

    // Rounded to the mark step, in the level's direction — as the
    // strictness allows — never above the question's maximum.
    final RoundingDirection direction = strictness.rounding(level.rounding);
    final double rounded = _round(awarded, standard.markStep, direction)
        .clamp(0, maximum)
        .toDouble();
    if ((rounded - awarded).abs() > 1e-9) {
      adjustments.add('Rounded ${direction.words} from ${formatMarks(awarded)} to '
          '${formatMarks(rounded)} — ${_step(standard.markStep)} '
          '${direction == level.rounding ? by : firmly}.');
    }
    awarded = rounded;

    // A wrong answer to a multiple-choice question costs the penalty; an
    // unanswered one costs nothing.
    if (standard.mcqPenalty > 0 && awarded == 0 && !task.answer.isEmpty && isMcq(task)) {
      awarded = -standard.mcqPenalty;
      adjustments.add('−${formatMarks(standard.mcqPenalty)} for a wrong multiple-choice '
          'answer (college rule).');
    }

    // A badge, and a bonus, for an answer that covers what the syllabus
    // teaches for the question — never above the question's maximum.
    final SyllabusAward? award = _syllabusAward(result, task, awarded);
    if (award != null && award.bonus > 0) {
      final double wanted = standard.syllabusBonus.bonusFor(award.badge);
      adjustments.add('+${formatMarks(award.bonus)}'
          '${award.bonus < wanted - 1e-9 ? ' of the +${formatMarks(wanted)}' : ''} syllabus bonus — '
          'the answer covers ${award.matched.length} of ${award.matched.length + award.missing.length} '
          'syllabus terms (${award.percent}%): ${award.badge.label}'
          '${award.bonus < wanted - 1e-9 ? ', capped at the question’s maximum of ${formatMarks(result.maximumMarks)}' : ''}.');
      awarded += award.bonus;
    }

    // Flagged against the level's own threshold.
    final String? byConfidence =
        reasons.where((String r) => r.startsWith('Confidence ')).firstOrNull;
    if (result.confidence < reviewThreshold) {
      if (byConfidence == null) {
        reasons.add('Confidence ${(result.confidence * 100).round()}% is below the '
            '${level.label} review threshold of ${(reviewThreshold * 100).round()}%.');
      }
      review = true;
    } else if (byConfidence != null) {
      reasons.remove(byConfidence);
      review = reasons.isNotEmpty;
    }

    final bool changed = adjustments.isNotEmpty;
    return result.copyWith(
      awardedMarks: awarded,
      markingPoints: points,
      needsReview: review,
      reviewReasons: reasons,
      adjustments: adjustments,
      aiRawMarks: () => changed ? result.awardedMarks : null,
      syllabusAward: () => award,
      moderatedFrom: () => moderatedFrom,
    );
  }

  /// Words that say nothing about the subject, however a criterion uses
  /// them: "Correct definition of IoT" is about IoT.
  static final Set<String> _generic = syllabusKeywords(
    'correct correctly definition defines defined proper properly mention mentions mentioned '
    'states stated relevant appropriate accurate accurately clear clearly key point points '
    'concept concepts idea ideas identifies identify identified explanation explains explained '
    'describes described description gives given shows shown least valid complete completely '
    'basic main important working work works role purpose meaning term terms '
    'name names named list lists listed draw draws drawn give gives write writes written '
    'define explain describe discuss compare state outline outlines illustrate illustrates '
    'label labels labelled labeled answer answers student students',
  );

  /// The key terms of a credited point the answer never uses; null when the
  /// point earned nothing, has fewer than two terms to judge by, or the
  /// answer uses any of them.
  static List<String>? _unstated(MarkingPoint point, Set<String> vocabulary) {
    if (point.marks <= 0) return null;
    final Set<String> terms = syllabusKeywords(point.criterion).difference(_generic);
    if (terms.length < 2 || terms.any(vocabulary.contains)) return null;
    return terms.toList()..sort();
  }

  /// Every word the student wrote, as the syllabus index normalises words:
  /// the text, the contextual readings the AI relied on, and what was written
  /// in diagrams, tables, graphs and equations. Empty when there is no text
  /// to judge by.
  static Set<String> answerVocabulary(QuestionResult result, MarkingTask task) {
    final StringBuffer text = StringBuffer(task.answer.text);
    if (text.toString().trim().isEmpty) return const <String>{};
    for (final InterpretedReading reading in result.interpretedReadings) {
      text.write(' ${reading.interpreted}');
    }
    for (final VisualEvidence visual in task.answer.visualEvidence) {
      text.write(switch (visual) {
        DiagramEvidence() => ' ${visual.labels.join(' ')} ${visual.components.join(' ')}',
        TableEvidence() => ' ${visual.rows.expand((List<String> r) => r).join(' ')}',
        GraphEvidence() => ' ${visual.xAxis} ${visual.yAxis}',
        EquationEvidence() => ' ${visual.plainText}',
      });
    }
    return syllabusKeywords(text.toString());
  }

  /// The answer's length in words, a diagram, table, graph or equation
  /// counting as [RealismRules.visualWords].
  static int answerWords(MarkingTask task) =>
      RegExp(r'[A-Za-z0-9]+').allMatches(task.answer.text).length +
      task.answer.visualRegionIds.length * RealismRules.visualWords;

  /// Null when the bonus is off, or there is no syllabus or scheme to
  /// measure the answer against.
  SyllabusAward? _syllabusAward(QuestionResult result, MarkingTask task, double awarded) {
    final SyllabusBonus bonus = standard.syllabusBonus;
    if (!bonus.enabled || task.answer.isEmpty) return null;
    final String answer = task.answer.text.trim().isEmpty ? result.studentAnswer : task.answer.text;
    final SyllabusMatch match = SyllabusMatch.of(answer, '${task.syllabusFocus}\n${task.markScheme}');
    if (match.isEmpty) return null;

    SyllabusBadge badge = bonus.badgeFor(match.coverage);
    String note = '';
    double given = 0;
    if (badge != SyllabusBadge.none) {
      final double needed = bonus.minimumShare * result.maximumMarks;
      if (awarded < needed - 1e-9 || awarded < 0) {
        note = 'Covers the syllabus terms, but earned ${formatMarks(awarded)} of '
            '${formatMarks(result.maximumMarks)} — under the ${(bonus.minimumShare * 100).round()}% '
            'needed for a badge.';
        badge = SyllabusBadge.none;
      } else {
        given = (bonus.bonusFor(badge)).clamp(0, result.maximumMarks - awarded).toDouble();
        if (bonus.bonusFor(badge) > 0 && given <= 1e-9) {
          given = 0;
          note = 'Already full marks — no bonus.';
        } else if (given < bonus.bonusFor(badge) - 1e-9) {
          note = 'Capped at the question’s maximum of ${formatMarks(result.maximumMarks)}.';
        }
      }
    }
    return SyllabusAward(
      badge: badge,
      coverage: match.coverage,
      bonus: given,
      matched: match.matched,
      missing: match.missing,
      note: note,
    );
  }

  static const String _uncertain = 'Strict: a mark resting on an uncertain reading was not given.';

  /// A multiple-choice question: in a section the teacher marked as one, or
  /// printed with lettered options.
  bool isMcq(MarkingTask task) {
    final String? section = task.question.sectionId;
    if (section != null && standard.mcqSections.contains(section)) return true;
    final Iterable<RegExpMatch> options =
        RegExp(r'(?:^|\s|\()([a-dA-D])[).]\s').allMatches(task.question.questionText);
    return options.map((RegExpMatch m) => m.group(1)!.toLowerCase()).toSet().length >= 3;
  }

  static double _round(double value, double step, RoundingDirection direction) {
    final double units = value / step;
    final double whole = switch (direction) {
      RoundingDirection.up => (units - 1e-9).ceilToDouble(),
      RoundingDirection.nearest => units.roundToDouble(),
      RoundingDirection.down => (units + 1e-9).floorToDouble(),
    };
    return whole * step;
  }

  static String _step(double step) => switch (step) {
        1 => 'whole marks',
        0.25 => 'quarter marks',
        _ => 'half marks',
      };
}
