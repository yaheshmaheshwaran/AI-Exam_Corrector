import 'package:exam_corrector/domain/json_read.dart';

/// Which way a mark is rounded to the mark step.
enum RoundingDirection {
  up('up'),
  nearest('to the nearest'),
  down('down');

  const RoundingDirection(this.words);

  final String words;
}

/// How the paper's total is rounded, when the college rounds it.
enum TotalRounding {
  none('not rounded'),
  up('rounded up to a whole mark'),
  nearest('rounded to the nearest whole mark'),
  down('rounded down to a whole mark');

  const TotalRounding(this.words);

  final String words;

  double apply(double total) => switch (this) {
        TotalRounding.none => total,
        TotalRounding.up => (total - 1e-9).ceilToDouble(),
        TotalRounding.nearest => total.roundToDouble(),
        TotalRounding.down => (total + 1e-9).floorToDouble(),
      };
}

/// How strictly answers are judged.
///
/// Each level states exactly what it changes, both for the AI — how exact,
/// how deep, how generous — and for the arithmetic done on its marks.
enum MarkingLevel {
  lenient(
    'Lenient',
    'For a hard paper or a first course: the right idea earns the marks.',
    RoundingDirection.up,
    0.6,
  ),
  balanced(
    'Balanced',
    'The usual standard: correct ideas, the key terms where asked, depth in '
        'proportion to the marks.',
    RoundingDirection.nearest,
    null,
  ),
  strict(
    'Strict',
    'For a final or university-pattern paper: exact terms, full depth, no '
        'benefit of the doubt.',
    RoundingDirection.down,
    0.8,
  );

  const MarkingLevel(this.label, this.description, this.rounding, this.reviewThreshold);

  final String label;
  final String description;

  /// Which way each question's mark is rounded to the mark step.
  final RoundingDirection rounding;

  /// Flag a question below this confidence; null keeps the Settings value.
  final double? reviewThreshold;

  /// What the level changes, rule by rule, as the teacher reads it.
  List<({String rule, String effect})> get rules => switch (this) {
        MarkingLevel.lenient => const <({String rule, String effect})>[
            (rule: 'Wording', effect: 'The right idea in the student’s own words earns the point.'),
            (rule: 'Partial credit', effect: 'Allowed for a partly correct point.'),
            (rule: 'Spelling', effect: 'Ignored.'),
            (rule: 'Unclear handwriting', effect: 'Read generously in context.'),
            (rule: 'Numericals', effect: 'Method earns its marks; errors are carried forward.'),
            (rule: 'Units', effect: 'Not required.'),
            (rule: 'Diagrams', effect: 'Rough and partly labelled diagrams are accepted.'),
            (rule: 'Long answers', effect: 'The key points are enough.'),
            (rule: 'Contradictions', effect: 'Minor slips are ignored.'),
            (rule: 'Rounding', effect: 'Each question’s mark is rounded up to the mark step.'),
            (rule: 'Review', effect: 'Flagged below 60% confidence.'),
          ],
        MarkingLevel.balanced => const <({String rule, String effect})>[
            (rule: 'Wording', effect: 'The right idea earns the point; the key term is expected where the question asks for it.'),
            (rule: 'Partial credit', effect: 'Allowed where a point is worth 2 or more.'),
            (rule: 'Spelling', effect: 'Ignored unless it changes the meaning.'),
            (rule: 'Unclear handwriting', effect: 'Read in context, and flagged for you.'),
            (rule: 'Numericals', effect: 'Errors are carried forward.'),
            (rule: 'Units', effect: 'Required when the question asks for them.'),
            (rule: 'Diagrams', effect: 'Must be correct, with the main labels.'),
            (rule: 'Long answers', effect: 'Depth in proportion to the marks, at the course’s level.'),
            (rule: 'Contradictions', effect: 'A contradicted point is lost.'),
            (rule: 'Rounding', effect: 'Each question’s mark is rounded to the nearest mark step.'),
            (rule: 'Review', effect: 'Flagged below the confidence set in Settings.'),
          ],
        MarkingLevel.strict => const <({String rule, String effect})>[
            (rule: 'Wording', effect: 'The correct technical term or definition is needed.'),
            (rule: 'Partial credit', effect: 'None: a point is met in full or scores nothing.'),
            (rule: 'Spelling', effect: 'A misspelled key term earns only if it is unambiguous.'),
            (rule: 'Unclear handwriting', effect: 'A point resting on an uncertain reading scores nothing, and is flagged for you.'),
            (rule: 'Numericals', effect: 'No error carried forward: the answer mark needs the right final answer.'),
            (rule: 'Units', effect: 'A missing or wrong unit loses the answer mark.'),
            (rule: 'Diagrams', effect: 'Correct, neat, with every label the question asks for.'),
            (rule: 'Long answers', effect: 'Full depth: explanation and examples in proportion to the marks.'),
            (rule: 'Contradictions', effect: 'A contradicted point is lost, and the question flagged.'),
            (rule: 'Rounding', effect: 'Each question’s mark is rounded down to the mark step.'),
            (rule: 'Review', effect: 'Flagged below 80% confidence.'),
          ],
      };
}

/// How good a long answer is as a whole — the level-of-response band an
/// examiner puts it in. A long answer's mark never goes above its band's
/// share of the marks, however many points it touched.
enum QualityBand {
  excellent('Excellent', 1, 'Complete and accurate: every key point developed, with the diagram or example expected.'),
  good('Good', 0.8, 'Most key points, mostly accurate, with some development; minor gaps.'),
  satisfactory('Satisfactory', 0.6, 'About half the key points, briefly developed, or with some errors.'),
  weak('Weak', 0.35, 'A few relevant points, mostly listed rather than explained, or with serious errors.'),
  poor('Poor', 0.15, 'Barely relevant: a fragment, or mostly wrong.'),
  none('Nothing creditworthy', 0, 'Nothing that earns credit.');

  const QualityBand(this.label, this.share, this.description);

  final String label;

  /// The most of the question's marks the band allows, at Balanced.
  final double share;
  final String description;

  /// The cap at a level and strictness: the strictness sets the band's
  /// share, Lenient allows 10% more and Strict 10% less — except that an
  /// excellent answer can always earn full marks, and nothing creditworthy
  /// nothing.
  double shareAt(MarkingLevel level, [RealismStrictness strictness = RealismStrictness.standard]) {
    if (this == QualityBand.excellent || this == QualityBand.none) return share;
    final double base = strictness.bandShare(this);
    return switch (level) {
      MarkingLevel.lenient => (base + 0.1).clamp(0, 1).toDouble(),
      MarkingLevel.balanced => base,
      MarkingLevel.strict => (base - 0.1).clamp(0, 1).toDouble(),
    };
  }

  static QualityBand? fromWire(Object? name) => switch (name) {
        'excellent' => QualityBand.excellent,
        'good' => QualityBand.good,
        'satisfactory' => QualityBand.satisfactory,
        'weak' => QualityBand.weak,
        'poor' => QualityBand.poor,
        'none' => QualityBand.none,
        _ => null,
      };
}

/// How hard the realistic-marking checks are. Every number the checks use
/// comes from here, so the teacher can step it until the totals match their
/// own marking — instantly, without re-marking.
enum RealismStrictness {
  standard(
    'Standard',
    'The checks as first introduced: long answers only, one step off an incomplete full mark.',
    <double>[0.8, 0.6, 0.35, 0.15],
    5,
    1.25,
    null,
    0,
    false,
    1,
  ),
  firm(
    'Firm',
    'Short answers checked too, tighter bands, a full-length answer for full marks, and a '
        'mark never rounded up.',
    <double>[0.75, 0.5, 0.3, 0.1],
    2,
    0.9 / 0.85,
    0.4,
    1,
    true,
    0.5,
  ),
  tough(
    'Tough',
    'For a strict university examiner: the tightest bands, every mark rounded down, and a '
        'point not stated in the answer earns nothing.',
    <double>[0.7, 0.45, 0.25, 0.05],
    2,
    0.9,
    0.5,
    2,
    true,
    0,
  );

  const RealismStrictness(
    this.label,
    this.description,
    this._bandShares,
    this.bandFrom,
    this.lengthSlope,
    this.shortBelow,
    this._gate,
    this.uncertainEarnsNothing,
    this.keyTermFactor,
  );

  final String label;
  final String description;

  /// Good, Satisfactory, Weak, Poor.
  final List<double> _bandShares;

  /// The band cap applies to questions worth this much or more.
  final double bandFrom;

  /// How fast the length cap rises with the answer's share of a full
  /// answer's length, from 10% at no words.
  final double lengthSlope;

  /// A short answer (2 marks up to a long one) under this share of the
  /// expected length earns at most half; null leaves short answers alone.
  final double? shortBelow;

  /// 0: the full-marks gate lowers by a mark step; 1: by a whole mark on a
  /// long question; 2: by a whole mark, two on a question of 10 or more.
  final int _gate;

  /// A point resting on an uncertain reading earns nothing.
  final bool uncertainEarnsNothing;

  /// What a credited point keeps when none of its key terms is in the
  /// answer: 1 all of it, 0.5 half, 0 nothing.
  final double keyTermFactor;

  double bandShare(QualityBand band) => switch (band) {
        QualityBand.excellent => 1,
        QualityBand.good => _bandShares[0],
        QualityBand.satisfactory => _bandShares[1],
        QualityBand.weak => _bandShares[2],
        QualityBand.poor => _bandShares[3],
        QualityBand.none => 0,
      };

  /// The share of a full answer's length from which full marks are possible,
  /// at Balanced.
  double get fullLengthAt => 0.9 / lengthSlope;

  /// How far the full-marks gate lowers an incomplete full mark.
  double gateDrop(double maximum, double markStep) => switch (_gate) {
        0 => markStep,
        1 => maximum >= RealismRules.longFrom - 1e-9 ? (markStep > 1 ? markStep : 1) : markStep,
        _ => maximum >= 10 - 1e-9 ? 2 : 1,
      };

  /// Which way marks are rounded, given the level's own direction.
  RoundingDirection rounding(RoundingDirection level) => switch (this) {
        RealismStrictness.standard => level,
        RealismStrictness.firm => level == RoundingDirection.up ? RoundingDirection.nearest : level,
        RealismStrictness.tough => RoundingDirection.down,
      };

  /// What the setting does, rule by rule, as the teacher reads it.
  List<({String rule, String effect})> get rules {
    String pct(double v) => '${(v * 100).round()}%';
    return <({String rule, String effect})>[
      (
        rule: 'Quality bands',
        effect: 'Good up to ${pct(_bandShares[0])}, Satisfactory ${pct(_bandShares[1])}, '
            'Weak ${pct(_bandShares[2])}, Poor ${pct(_bandShares[3])} — on questions of '
            '${bandFrom.toStringAsFixed(0)} marks or more.',
      ),
      (
        rule: 'Long answers',
        effect: 'Full marks possible from ${pct(fullLengthAt.clamp(0, 1))} of a full answer’s length.',
      ),
      (
        rule: 'Short answers',
        effect: shortBelow == null
            ? 'Not checked for length.'
            : 'Under ${pct(shortBelow!)} of the expected length: at most half the marks.',
      ),
      (
        rule: 'Full marks',
        effect: switch (_gate) {
          0 => 'An incomplete full mark loses one mark step.',
          1 => 'An incomplete full mark loses a step — a whole mark on a long question.',
          _ => 'An incomplete full mark loses a mark — two on a question of 10 or more.',
        },
      ),
      (
        rule: 'Unclear handwriting',
        effect: uncertainEarnsNothing
            ? 'A point resting on an uncertain reading earns nothing.'
            : 'As the level decides.',
      ),
      (
        rule: 'Points not stated',
        effect: switch (keyTermFactor) {
          1 => 'Not checked.',
          0 => 'A point credited with none of its key terms in the answer earns nothing.',
          _ => 'A point credited with none of its key terms in the answer earns half.',
        },
      ),
      (
        rule: 'Rounding',
        effect: switch (this) {
          RealismStrictness.standard => 'As the level rounds.',
          RealismStrictness.firm => 'As the level rounds, but never up.',
          RealismStrictness.tough => 'Always down.',
        },
      ),
    ];
  }
}

/// Checks that keep marks where a real teacher would put them. Arithmetic on
/// the AI's marks, so turning one on or off re-marks nothing.
class RealismRules {
  const RealismRules({
    this.bandCap = true,
    this.lengthCap = true,
    this.wordsPerMark = 25,
    this.fullMarksGate = true,
    this.strictness = RealismStrictness.firm,
  });

  /// How hard the checks are.
  final RealismStrictness strictness;

  /// Words a full short answer needs per mark, where the answer key does
  /// not say.
  static const double shortWordsPerMark = 15;

  /// A long answer's mark stays within its quality band.
  final bool bandCap;

  /// A long answer far shorter than a full answer cannot earn most of the
  /// marks.
  final bool lengthCap;

  /// Words a full answer needs per mark, where the answer key does not say.
  final double wordsPerMark;

  /// Full marks only for an answer with every point complete.
  final bool fullMarksGate;

  /// The caps apply to questions worth this much or more: short answers —
  /// a definition, a 2-mark fact — can be complete in a line.
  static const double longFrom = 5;

  /// A diagram, table, graph or equation counts as this many words.
  static const int visualWords = 60;

  static const List<double> wordsPerMarkOptions = <double>[15, 20, 25, 30, 40];

  /// The most of the marks an answer of [ratio] of the expected length can
  /// earn: at Standard and Balanced, full marks from about 72% of the length.
  static double lengthShare(
    double ratio,
    MarkingLevel level, [
    RealismStrictness strictness = RealismStrictness.standard,
  ]) {
    final double r = ratio.clamp(0, 10).toDouble();
    final double slope = strictness.lengthSlope;
    final double share = switch (level) {
      MarkingLevel.lenient => 0.2 + slope * r,
      MarkingLevel.balanced => 0.1 + slope * r,
      MarkingLevel.strict => slope * r,
    };
    return share.clamp(0, 1).toDouble();
  }

  RealismRules copyWith({
    bool? bandCap,
    bool? lengthCap,
    double? wordsPerMark,
    bool? fullMarksGate,
    RealismStrictness? strictness,
  }) =>
      RealismRules(
        bandCap: bandCap ?? this.bandCap,
        lengthCap: lengthCap ?? this.lengthCap,
        wordsPerMark: wordsPerMark ?? this.wordsPerMark,
        fullMarksGate: fullMarksGate ?? this.fullMarksGate,
        strictness: strictness ?? this.strictness,
      );

  JsonMap toJson() => <String, Object?>{
        'bandCap': bandCap,
        'lengthCap': lengthCap,
        'wordsPerMark': wordsPerMark,
        'fullMarksGate': fullMarksGate,
        'strictness': strictness.name,
      };

  static RealismRules fromJson(Object? value) {
    if (value is! Map) return const RealismRules();
    final JsonMap json = value.cast<String, Object?>();
    return RealismRules(
      bandCap: readBool(json['bandCap']) ?? true,
      lengthCap: readBool(json['lengthCap']) ?? true,
      wordsPerMark: (readDouble(json['wordsPerMark']) ?? 25).clamp(5, 100).toDouble(),
      fullMarksGate: readBool(json['fullMarksGate']) ?? true,
      strictness: readEnum(RealismStrictness.values, json['strictness'], RealismStrictness.firm),
    );
  }
}

/// How close an answer comes to the syllabus for its question.
enum SyllabusBadge {
  none(''),
  almost('Close to syllabus'),
  exact('Syllabus match');

  const SyllabusBadge(this.label);

  final String label;
}

/// A badge, and a bonus mark, for an answer that covers what the syllabus
/// teaches for its question — almost or exactly.
///
/// Arithmetic on the AI's marks, like rounding: changing it re-marks
/// nothing. The bonus never takes a question above its maximum.
class SyllabusBonus {
  const SyllabusBonus({
    this.enabled = false,
    this.almostThreshold = 0.65,
    this.exactThreshold = 0.85,
    this.almostBonus = 0.5,
    this.exactBonus = 1,
    this.minimumShare = 0.5,
  });

  final bool enabled;

  /// The share of the syllabus terms an answer must cover to be close.
  final double almostThreshold;

  /// The share it must cover to match. Always above [almostThreshold].
  final double exactThreshold;

  /// Added for a close answer; 0 for the badge alone.
  final double almostBonus;

  /// Added for a matching answer; 0 for the badge alone.
  final double exactBonus;

  /// The share of the question's marks the answer must already have earned,
  /// so a list of syllabus words with nothing right in it earns nothing.
  final double minimumShare;

  static const List<double> bonuses = <double>[0, 0.25, 0.5, 1, 2];
  static const List<double> minimumShares = <double>[0, 0.25, 0.5, 0.75];

  double bonusFor(SyllabusBadge badge) => switch (badge) {
        SyllabusBadge.exact => exactBonus,
        SyllabusBadge.almost => almostBonus,
        SyllabusBadge.none => 0,
      };

  SyllabusBadge badgeFor(double coverage) => coverage >= exactThreshold - 1e-9
      ? SyllabusBadge.exact
      : coverage >= almostThreshold - 1e-9
          ? SyllabusBadge.almost
          : SyllabusBadge.none;

  SyllabusBonus copyWith({
    bool? enabled,
    double? almostThreshold,
    double? exactThreshold,
    double? almostBonus,
    double? exactBonus,
    double? minimumShare,
  }) =>
      SyllabusBonus(
        enabled: enabled ?? this.enabled,
        almostThreshold: almostThreshold ?? this.almostThreshold,
        exactThreshold: exactThreshold ?? this.exactThreshold,
        almostBonus: almostBonus ?? this.almostBonus,
        exactBonus: exactBonus ?? this.exactBonus,
        minimumShare: minimumShare ?? this.minimumShare,
      );

  JsonMap toJson() => <String, Object?>{
        'enabled': enabled,
        'almostThreshold': almostThreshold,
        'exactThreshold': exactThreshold,
        'almostBonus': almostBonus,
        'exactBonus': exactBonus,
        'minimumShare': minimumShare,
      };

  static SyllabusBonus fromJson(Object? value) {
    if (value is! Map) return const SyllabusBonus();
    final JsonMap json = value.cast<String, Object?>();
    final double almost = (readDouble(json['almostThreshold']) ?? 0.65).clamp(0.3, 0.95).toDouble();
    final double exact = (readDouble(json['exactThreshold']) ?? 0.85).clamp(0.35, 1).toDouble();
    return SyllabusBonus(
      enabled: readBool(json['enabled']) ?? false,
      almostThreshold: almost,
      exactThreshold: exact <= almost ? (almost + 0.05).clamp(0, 1).toDouble() : exact,
      almostBonus: (readDouble(json['almostBonus']) ?? 0.5).clamp(0, 10).toDouble(),
      exactBonus: (readDouble(json['exactBonus']) ?? 1).clamp(0, 10).toDouble(),
      minimumShare: (readDouble(json['minimumShare']) ?? 0.5).clamp(0, 1).toDouble(),
    );
  }
}

/// The standard a question paper is marked to: a strictness level and the
/// college's own rules.
///
/// Two kinds of rule, kept apart on purpose. The level and the written
/// college rules change how the AI judges answers, so changing them means
/// marking again. The mark step, the rounding of the total and the penalty
/// for a wrong multiple-choice answer are arithmetic on the AI's marks, done
/// afterwards — changing them costs nothing.
class MarkingStandard {
  const MarkingStandard({
    this.level = MarkingLevel.balanced,
    this.markStep = 0.5,
    this.totalRounding = TotalRounding.none,
    this.mcqPenalty = 0,
    this.mcqSections = const <String>[],
    this.collegeRules = '',
    this.syllabusBonus = const SyllabusBonus(),
    this.realism = const RealismRules(),
  });

  final MarkingLevel level;

  /// The smallest mark awarded: 1, 0.5 or 0.25.
  final double markStep;
  final TotalRounding totalRounding;

  /// Taken off for a wrong answer to a multiple-choice question; 0 for none.
  final double mcqPenalty;

  /// Sections whose questions are all multiple choice, as the paper names
  /// them: `A`.
  final List<String> mcqSections;

  /// The college's rules in its own words, binding like the teacher's
  /// guidance.
  final String collegeRules;

  /// A badge and bonus for answers that match the syllabus. Arithmetic, so
  /// not part of [judgementKey].
  final SyllabusBonus syllabusBonus;

  /// Band, length and full-marks checks. Arithmetic, so not part of
  /// [judgementKey].
  final RealismRules realism;

  static const List<double> markSteps = <double>[1, 0.5, 0.25];
  static const List<double> penalties = <double>[0, 0.25, 0.33, 0.5, 1];

  /// What changes the AI's judgement. Empty for today's standard, so marks
  /// already made under it stay valid.
  String get judgementKey => level == MarkingLevel.balanced && collegeRules.trim().isEmpty
      ? ''
      : '${level.name}|${collegeRules.trim()}';

  /// Whether the AI is given instructions beyond its usual ones.
  bool get changesJudgement => judgementKey.isNotEmpty;

  /// One line for the teacher: "Strict · half marks · total rounded up ·
  /// MCQ −0.25 · college rules".
  String get summary => <String>[
        level.label,
        switch (markStep) {
          1 => 'whole marks',
          0.25 => 'quarter marks',
          _ => 'half marks',
        },
        if (totalRounding != TotalRounding.none) 'total ${totalRounding.words.replaceFirst(' to a whole mark', '')}',
        if (mcqPenalty > 0) 'MCQ −${_trim(mcqPenalty)}',
        if (collegeRules.trim().isNotEmpty) 'college rules',
        realism.strictness.label,
        if (syllabusBonus.enabled)
          'syllabus bonus +${_trim(syllabusBonus.almostBonus)}/+${_trim(syllabusBonus.exactBonus)}',
      ].join(' · ');

  static String _trim(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  MarkingStandard copyWith({
    MarkingLevel? level,
    double? markStep,
    TotalRounding? totalRounding,
    double? mcqPenalty,
    List<String>? mcqSections,
    String? collegeRules,
    SyllabusBonus? syllabusBonus,
    RealismRules? realism,
  }) =>
      MarkingStandard(
        level: level ?? this.level,
        markStep: markStep ?? this.markStep,
        totalRounding: totalRounding ?? this.totalRounding,
        mcqPenalty: mcqPenalty ?? this.mcqPenalty,
        mcqSections: mcqSections ?? this.mcqSections,
        collegeRules: collegeRules ?? this.collegeRules,
        syllabusBonus: syllabusBonus ?? this.syllabusBonus,
        realism: realism ?? this.realism,
      );

  JsonMap toJson() => <String, Object?>{
        'level': level.name,
        'markStep': markStep,
        'totalRounding': totalRounding.name,
        'mcqPenalty': mcqPenalty,
        'mcqSections': mcqSections,
        'collegeRules': collegeRules,
        'syllabusBonus': syllabusBonus.toJson(),
        'realism': realism.toJson(),
      };

  static MarkingStandard fromJson(JsonMap json) {
    final double step = readDouble(json['markStep']) ?? 0.5;
    return MarkingStandard(
      level: readEnum(MarkingLevel.values, json['level'], MarkingLevel.balanced),
      markStep: markSteps.contains(step) ? step : 0.5,
      totalRounding: readEnum(TotalRounding.values, json['totalRounding'], TotalRounding.none),
      mcqPenalty: (readDouble(json['mcqPenalty']) ?? 0).clamp(0, 1).toDouble(),
      mcqSections: readStringList(json['mcqSections']),
      collegeRules: readRawString(json['collegeRules']) ?? '',
      syllabusBonus: SyllabusBonus.fromJson(json['syllabusBonus']),
      realism: RealismRules.fromJson(json['realism']),
    );
  }
}
