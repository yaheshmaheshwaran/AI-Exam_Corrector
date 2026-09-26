import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/json_read.dart';

/// One question the teacher marked themselves, beside the AI's mark for it.
class ModerationSample {
  const ModerationSample({
    required this.questionId,
    required this.ai,
    required this.teacher,
    required this.maximum,
    this.section,
  });

  final String questionId;

  /// The paper's section the question is in: `A`, `B`.
  final String? section;

  /// The AI's mark before any moderation.
  final double ai;

  /// The mark the teacher gave, or accepted.
  final double teacher;
  final double maximum;

  JsonMap toJson() => <String, Object?>{
        'questionId': questionId,
        'ai': ai,
        'teacher': teacher,
        'maximum': maximum,
        'section': ?section,
      };

  static ModerationSample? fromJson(JsonMap json) {
    final String? id = readString(json['questionId']);
    final double? ai = readDouble(json['ai']);
    final double? teacher = readDouble(json['teacher']);
    final double? maximum = readDouble(json['maximum']);
    if (id == null || ai == null || teacher == null || maximum == null) return null;
    return ModerationSample(
      questionId: id,
      ai: ai,
      teacher: teacher,
      maximum: maximum,
      section: readString(json['section']),
    );
  }
}

/// The AI's marks brought to the teacher's own standard — the way an exam
/// board moderates an examiner against the chief examiner's marks on sample
/// scripts.
///
/// The teacher marks a few scripts themselves; the ratio of their marks to
/// the AI's on the same questions scales the AI's marks on every other
/// script of the paper. Short and long questions are scaled apart, as an
/// AI's generosity differs between a 2-mark definition and a 13-mark essay.
class Moderation {
  const Moderation({
    this.shortFactor = 1,
    this.longFactor = 1,
    this.questions = 0,
    this.scripts = 0,
    this.sectionFactors = const <String, double>{},
  });

  static const Moderation none = Moderation();

  /// For a section with enough of the teacher's marks of its own — the AI
  /// can be generous on Part A and fair on Part B.
  final Map<String, double> sectionFactors;

  /// A section needs this many of the teacher's marks for its own factor.
  static const int minimumPerSection = 3;

  /// For questions worth [shortUpTo] marks or less.
  final double shortFactor;

  /// For longer questions.
  final double longFactor;

  /// How many of the teacher's marks it rests on, and from how many scripts.
  final int questions;
  final int scripts;

  /// A class average above this, in percent, is higher than real classes
  /// get.
  static const double classHighAverage = 75;

  static const double shortUpTo = 3;
  static const int minimumQuestions = 6;

  /// A group with fewer samples uses the factor of all samples.
  static const int minimumPerGroup = 4;
  static const double lowest = 0.2;
  static const double highest = 1.2;

  bool get isActive => questions > 0;

  double factorFor(double maximum, [String? section]) =>
      sectionFactors[section] ?? (maximum <= shortUpTo ? shortFactor : longFactor);

  /// Whether [other] would change marks noticeably.
  bool differsFrom(Moderation other) {
    if (isActive != other.isActive ||
        (shortFactor - other.shortFactor).abs() > 0.02 ||
        (longFactor - other.longFactor).abs() > 0.02) {
      return true;
    }
    final Set<String> sections = <String>{...sectionFactors.keys, ...other.sectionFactors.keys};
    return sections.any((String s) =>
        !sectionFactors.containsKey(s) ||
        !other.sectionFactors.containsKey(s) ||
        (sectionFactors[s]! - other.sectionFactors[s]!).abs() > 0.02);
  }

  /// "× 0.45", "short questions × 0.8, long × 0.4", or by section:
  /// "Section A × 0.60, Section B × 0.45".
  String get factors {
    if (sectionFactors.isNotEmpty) {
      final List<String> sections = sectionFactors.keys.toList()..sort();
      return sections.map((String s) => 'Section $s × ${_f(sectionFactors[s]!)}').join(', ');
    }
    return (shortFactor - longFactor).abs() < 0.01
        ? '× ${_f(longFactor)}'
        : 'short questions × ${_f(shortFactor)}, long × ${_f(longFactor)}';
  }

  /// "from 14 questions you marked on 3 scripts".
  String get basis => 'from $questions question${questions == 1 ? '' : 's'} you marked '
      'on $scripts script${scripts == 1 ? '' : 's'}';

  static String _f(double v) => v.toStringAsFixed(2);

  /// Moderation from the teacher's marks, script by script; null until
  /// there are enough of them to trust.
  static Moderation? from(Map<String, List<ModerationSample>> byScript) {
    final List<ModerationSample> all = <ModerationSample>[
      for (final List<ModerationSample> samples in byScript.values)
        for (final ModerationSample s in samples)
          if (s.ai > 0 || s.teacher > 0) s,
    ];
    if (all.length < minimumQuestions) return null;
    final double? overall = _ratio(all);
    if (overall == null) return null;
    double group(bool short) {
      final List<ModerationSample> picked = <ModerationSample>[
        for (final ModerationSample s in all)
          if ((s.maximum <= shortUpTo) == short) s,
      ];
      return picked.length >= minimumPerGroup ? (_ratio(picked) ?? overall) : overall;
    }

    final Map<String, List<ModerationSample>> bySection = <String, List<ModerationSample>>{};
    for (final ModerationSample s in all) {
      if (s.section case final String section) (bySection[section] ??= <ModerationSample>[]).add(s);
    }
    return Moderation(
      shortFactor: group(true),
      longFactor: group(false),
      sectionFactors: <String, double>{
        for (final MapEntry<String, List<ModerationSample>> e in bySection.entries)
          if (e.value.length >= minimumPerSection)
            if (_ratio(e.value) case final double factor) e.key: factor,
      },
      questions: all.length,
      scripts: byScript.values.where((List<ModerationSample> s) => s.any((ModerationSample x) => x.ai > 0 || x.teacher > 0)).length,
    );
  }

  static double? _ratio(List<ModerationSample> samples) {
    final double ai = samples.fold<double>(0, (double sum, ModerationSample s) => sum + s.ai);
    if (ai <= 0) return null;
    final double teacher = samples.fold<double>(0, (double sum, ModerationSample s) => sum + s.teacher);
    return (teacher / ai).clamp(lowest, highest).toDouble();
  }

  /// The adjustment line for one question: "Moderated to your marking
  /// × 0.45 (from 14 questions you marked on 3 scripts): 6 → 2.7."
  String describe(double from, double to, double maximum, [String? section]) =>
      'Moderated to your marking'
      '${sectionFactors.containsKey(section) ? ' for Section $section' : ''} '
      '× ${_f(factorFor(maximum, section))} ($basis): '
      '${formatMarks(from)} → ${formatMarks(to)}.';

  /// How far the AI is from the teacher on the questions they marked: the
  /// average of the AI's mark less theirs, per question — as marked, and as
  /// [by] would moderate it. Null without samples.
  static ({double before, double after, int questions})? agreement(
    Map<String, List<ModerationSample>> byScript,
    Moderation by,
  ) {
    final List<ModerationSample> all = <ModerationSample>[
      for (final List<ModerationSample> samples in byScript.values)
        for (final ModerationSample s in samples)
          if (s.ai > 0 || s.teacher > 0) s,
    ];
    if (all.isEmpty) return null;
    double mean(double Function(ModerationSample s) of) =>
        all.fold<double>(0, (double sum, ModerationSample s) => sum + of(s)) / all.length;
    return (
      before: mean((ModerationSample s) => s.ai - s.teacher),
      after: by.isActive
          ? mean((ModerationSample s) =>
              (s.ai * by.factorFor(s.maximum, s.section)).clamp(0, s.maximum) - s.teacher)
          : mean((ModerationSample s) => s.ai - s.teacher),
      questions: all.length,
    );
  }

  /// "+1.1 marks a question above you", "0.3 below you", "level with you".
  static String gap(double difference) {
    if (difference.abs() < 0.05) return 'level with you';
    return '${difference.abs().toStringAsFixed(1)} mark${(difference.abs() - 1).abs() < 0.05 ? '' : 's'} '
        'a question ${difference > 0 ? 'above' : 'below'} you';
  }

  JsonMap toJson() => <String, Object?>{
        'shortFactor': shortFactor,
        'longFactor': longFactor,
        'questions': questions,
        'scripts': scripts,
        if (sectionFactors.isNotEmpty) 'sectionFactors': sectionFactors,
      };

  static Moderation fromJson(Object? value) {
    if (value is! Map) return none;
    final JsonMap json = value.cast<String, Object?>();
    final int questions = readInt(json['questions']) ?? 0;
    if (questions <= 0) return none;
    return Moderation(
      shortFactor: (readDouble(json['shortFactor']) ?? 1).clamp(lowest, highest).toDouble(),
      longFactor: (readDouble(json['longFactor']) ?? 1).clamp(lowest, highest).toDouble(),
      questions: questions,
      scripts: readInt(json['scripts']) ?? 0,
      sectionFactors: <String, double>{
        for (final MapEntry<String, Object?> e in (readMap(json['sectionFactors']) ?? const <String, Object?>{}).entries)
          if (readDouble(e.value) case final double f) e.key: f.clamp(lowest, highest).toDouble(),
      },
    );
  }
}
