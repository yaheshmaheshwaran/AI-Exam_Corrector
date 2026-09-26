import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/moderation.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/marking_rules.dart';

import '../pipeline_fakes.dart';

/// [words] words of answer, and [visuals] diagrams.
StudentAnswer written(int words, {int visuals = 0}) {
  final String text = List<String>.generate(words, (int i) => 'word$i').join(' ');
  return StudentAnswer(
    questionId: 'Q1',
    pages: const <int>[1],
    regionIds: <String>['r1', for (int i = 0; i < visuals; i++) 'v$i'],
    visualRegionIds: <String>[for (int i = 0; i < visuals; i++) 'v$i'],
    textEvidence: <TextEvidenceItem>[
      TextEvidenceItem(
        regionId: 'r1',
        pageNumber: 1,
        type: RegionType.handwrittenAnswer,
        text: text,
        rawText: text,
        confidence: 0.95,
        source: ReadingSource.trocr,
      ),
    ],
    answerConfidence: 0.95,
    alignmentConfidence: 1,
  );
}

MarkingTask task(int words, {double marks = 13, int visuals = 0, int? expected, String text = 'Explain MQTT.'}) =>
    MarkingTask(
      question: question('1', text: text, marks: marks),
      answer: written(words, visuals: visuals),
      expectedWords: expected,
    );

QuestionResult marked(
  double awarded, {
  double maximum = 13,
  QualityBand? band,
  double confidence = 0.9,
  List<MarkingPoint> points = const <MarkingPoint>[],
}) =>
    QuestionResult(
      questionNumber: '1',
      questionId: 'Q1',
      maximumMarks: maximum,
      awardedMarks: awarded,
      studentAnswer: 'answer',
      evaluation: 'ok',
      confidence: confidence,
      qualityBand: band,
      bandReason: band == null ? '' : 'Mostly listed.',
      markingPoints: points,
    );

/// The checks as first introduced; Firm and Tough are tested apart.
const MarkingStandard standardStrictness = MarkingStandard(realism: RealismRules(strictness: RealismStrictness.standard));

QuestionResult apply(
  QuestionResult r,
  MarkingTask t, {
  MarkingStandard standard = standardStrictness,
  Moderation moderation = Moderation.none,
}) =>
    MarkingRules(standard, defaultReviewThreshold: 0.7, moderation: moderation).apply(r, t);

const MarkingStandard off = MarkingStandard(
  realism: RealismRules(bandCap: false, lengthCap: false, fullMarksGate: false),
);

void main() {
  group('the quality band', () {
    test('caps a long answer at its band', () {
      final QuestionResult out = apply(marked(11, band: QualityBand.weak), task(400));
      expect(out.awardedMarks, 4.5); // 35% of 13 = 4.55, rounded to the half mark
      expect(out.adjustments.first, contains('Capped at the Weak band'));
      expect(out.adjustments.first, contains('Mostly listed.'));
      expect(out.aiRawMarks, 11);
    });

    test('an excellent answer keeps full marks; nothing creditworthy earns nothing', () {
      expect(apply(marked(13, band: QualityBand.excellent), task(400)).awardedMarks, 13);
      expect(apply(marked(3, band: QualityBand.none), task(400)).awardedMarks, 0);
    });

    test('shifts with the level', () {
      expect(QualityBand.weak.shareAt(MarkingLevel.lenient), closeTo(0.45, 1e-9));
      expect(QualityBand.weak.shareAt(MarkingLevel.strict), closeTo(0.25, 1e-9));
      expect(QualityBand.excellent.shareAt(MarkingLevel.strict), 1);
    });

    test('leaves short questions alone', () {
      final QuestionResult out = apply(marked(2, maximum: 2, band: QualityBand.poor), task(8, marks: 2));
      expect(out.awardedMarks, 2);
    });
  });

  group('the length cap', () {
    test('five lines do not earn 11 of 13', () {
      // 60 words where a full answer is 13 × 25 = 325.
      final QuestionResult out = apply(marked(11), task(60));
      expect(out.awardedMarks, lessThanOrEqualTo(4.5));
      expect(out.adjustments.first, contains('about 60 words where a full answer is about 325'));
    });

    test('an answer near full length is not capped', () {
      expect(apply(marked(11), task(240)).awardedMarks, 11);
    });

    test("uses the answer key's length, and counts diagrams", () {
      expect(apply(marked(11), task(60, expected: 80)).awardedMarks, 11);
      expect(apply(marked(11), task(60, visuals: 3)).awardedMarks, 11); // 60 + 180 words
    });

    test('is stricter at Strict', () {
      final double balanced = apply(marked(11), task(150)).awardedMarks;
      final double strict = apply(
        marked(11),
        task(150),
        standard: const MarkingStandard(
          level: MarkingLevel.strict,
          realism: RealismRules(strictness: RealismStrictness.standard),
        ),
      ).awardedMarks;
      expect(strict, lessThan(balanced));
    });
  });

  group('full marks', () {
    const MarkingPoint whole = MarkingPoint(criterion: 'Defines MQTT', satisfied: true, marks: 3);
    const MarkingPoint part = MarkingPoint(criterion: 'Explains the broker', satisfied: true, marks: 1, marksAvailable: 2);

    test('need every point complete', () {
      final QuestionResult out = apply(
        marked(5, maximum: 5, points: const <MarkingPoint>[whole, part, MarkingPoint(criterion: 'QoS', satisfied: true, marks: 1)]),
        task(200, marks: 5),
      );
      expect(out.awardedMarks, 4.5);
      expect(out.adjustments.last, contains('a point was only partly met'));
    });

    test('need confident marking', () {
      expect(apply(marked(5, maximum: 5, confidence: 0.5), task(200, marks: 5)).awardedMarks, 4.5);
    });

    test('stand for a complete, certain answer — and for a multiple-choice one', () {
      expect(
        apply(marked(5, maximum: 5, points: const <MarkingPoint>[whole, MarkingPoint(criterion: 'b', satisfied: true, marks: 2)]), task(200, marks: 5))
            .awardedMarks,
        5,
      );
      expect(
        apply(marked(2, maximum: 2, confidence: 0.5), task(3, marks: 2, text: 'Pick one: (a) x (b) y (c) z (d) w')).awardedMarks,
        2,
      );
    });
  });

  test('every check can be turned off', () {
    final QuestionResult out = apply(marked(11, band: QualityBand.poor, confidence: 0.3), task(20), standard: off);
    expect(out.awardedMarks, 11);
    expect(out.adjustments, isEmpty);
  });

  test('is saved with the standard, on by default, and never re-marks', () {
    const MarkingStandard custom = MarkingStandard(realism: RealismRules(lengthCap: false, wordsPerMark: 30));
    final RealismRules back = MarkingStandard.fromJson(custom.toJson()).realism;
    expect(back.lengthCap, isFalse);
    expect(back.wordsPerMark, 30);
    expect(back.bandCap, isTrue);
    expect(MarkingStandard.fromJson(const <String, Object?>{}).realism.fullMarksGate, isTrue);
    expect(custom.judgementKey, const MarkingStandard().judgementKey);
  });

  group('moderation', () {
    List<ModerationSample> samples(double ai, double teacher, {int n = 3, double maximum = 13}) => <ModerationSample>[
          for (int i = 0; i < n; i++) ModerationSample(questionId: 'Q$i', ai: ai, teacher: teacher, maximum: maximum),
        ];

    test('needs enough of the teacher’s marks', () {
      expect(Moderation.from(<String, List<ModerationSample>>{'s1': samples(10, 4, n: 5)}), isNull);
      final Moderation m = Moderation.from(<String, List<ModerationSample>>{
        's1': samples(10, 4),
        's2': samples(10, 4),
      })!;
      expect(m.longFactor, closeTo(0.4, 1e-9));
      expect(m.questions, 6);
      expect(m.scripts, 2);
      expect(m.basis, 'from 6 questions you marked on 2 scripts');
    });

    test('scales short and long questions apart once each has enough', () {
      final Moderation m = Moderation.from(<String, List<ModerationSample>>{
        's1': <ModerationSample>[...samples(2, 1.5, n: 4, maximum: 2), ...samples(10, 3, n: 4)],
      })!;
      expect(m.shortFactor, closeTo(0.75, 1e-9));
      expect(m.longFactor, closeTo(0.3, 1e-9));
      expect(m.factors, 'short questions × 0.75, long × 0.30');
    });

    test('is kept within bounds, and ignores questions nobody gave marks', () {
      final Moderation m = Moderation.from(<String, List<ModerationSample>>{
        's1': <ModerationSample>[...samples(10, 0.5, n: 6), ...samples(0, 0, n: 10)],
      })!;
      expect(m.longFactor, Moderation.lowest);
      expect(m.questions, 6);
    });

    test("brings the AI's mark to the teacher's, after the caps and before rounding", () {
      const Moderation m = Moderation(shortFactor: 0.4, longFactor: 0.4, questions: 8, scripts: 2);
      final QuestionResult out = apply(marked(11), task(400), moderation: m, standard: off);
      expect(out.moderatedFrom, 11);
      expect(out.awardedMarks, 4.5); // 4.4 to the nearest half
      expect(out.adjustments.first, contains('Moderated to your marking × 0.40'));
      expect(apply(marked(0), task(400), moderation: m, standard: off).moderatedFrom, isNull);
    });

    test('is kept and read back', () {
      const Moderation m = Moderation(shortFactor: 0.8, longFactor: 0.4, questions: 8, scripts: 2);
      final Moderation back = Moderation.fromJson(m.toJson());
      expect(back.longFactor, 0.4);
      expect(back.differsFrom(m), isFalse);
      expect(Moderation.fromJson(null).isActive, isFalse);
    });
  });

  test('the syllabus bonus still stops at the maximum after everything', () {
    const MarkingStandard withBonus = MarkingStandard(syllabusBonus: SyllabusBonus(enabled: true, minimumShare: 0));
    final QuestionResult out = apply(
      marked(13, band: QualityBand.excellent),
      MarkingTask(
        question: question('1', text: 'Explain MQTT.', marks: 13),
        answer: written(400),
        syllabusFocus: 'word1 word2 word3 word4',
      ),
      standard: withBonus,
    );
    expect(out.awardedMarks, lessThanOrEqualTo(13));
  });

  group('strictness', () {
    const MarkingStandard firm = MarkingStandard();
    const MarkingStandard tough = MarkingStandard(realism: RealismRules(strictness: RealismStrictness.tough));

    test('Firm is the default, and a standard saved before reads back as Firm', () {
      expect(const MarkingStandard().realism.strictness, RealismStrictness.firm);
      expect(MarkingStandard.fromJson(const <String, Object?>{'realism': <String, Object?>{'bandCap': true}})
          .realism.strictness, RealismStrictness.firm);
      final MarkingStandard back = MarkingStandard.fromJson(tough.toJson());
      expect(back.realism.strictness, RealismStrictness.tough);
      expect(firm.summary, 'Balanced · half marks · Firm');
    });

    test('a vague 2-mark answer gets 1 at Firm, 2 at Standard', () {
      final QuestionResult vague = marked(2, maximum: 2, band: QualityBand.satisfactory);
      expect(apply(vague, task(25, marks: 2)).awardedMarks, 2);
      expect(apply(vague, task(25, marks: 2), standard: firm).awardedMarks, 1);
    });

    test('a two-word answer to a 2-mark question earns at most half at Firm', () {
      final QuestionResult out = apply(marked(2, maximum: 2, band: QualityBand.excellent), task(2, marks: 2), standard: firm);
      expect(out.awardedMarks, 1);
      expect(out.adjustments.single, contains('at most half of 2 (Firm)'));
    });

    test('tighter bands and a longer answer for full marks', () {
      expect(QualityBand.good.shareAt(MarkingLevel.balanced, RealismStrictness.firm), 0.75);
      expect(QualityBand.weak.shareAt(MarkingLevel.balanced, RealismStrictness.tough), 0.25);
      expect(RealismStrictness.firm.fullLengthAt, closeTo(0.85, 1e-9));
      expect(RealismStrictness.tough.fullLengthAt, closeTo(1, 1e-9));
      // 80% of the length: uncapped at Standard, capped at Firm.
      expect(apply(marked(13, band: QualityBand.excellent), task(260)).awardedMarks, 13);
      expect(apply(marked(13, band: QualityBand.excellent), task(260), standard: firm).awardedMarks, lessThan(13));
    });

    test('an incomplete full mark on a long question loses a whole mark, two at Tough', () {
      expect(apply(marked(13, band: QualityBand.excellent, confidence: 0.5), task(400), standard: firm).awardedMarks, 12);
      expect(apply(marked(13, band: QualityBand.excellent, confidence: 0.5), task(400), standard: tough).awardedMarks, 11);
      expect(apply(marked(2, maximum: 2, band: QualityBand.excellent, confidence: 0.5), task(40, marks: 2), standard: firm)
          .awardedMarks, 1.5);
    });

    test('a point resting on an uncertain reading earns nothing at Firm', () {
      final QuestionResult out = apply(
        marked(6, band: QualityBand.excellent, points: const <MarkingPoint>[
          MarkingPoint(criterion: 'word1 word2', satisfied: true, marks: 3),
          MarkingPoint(criterion: 'word3 word4', satisfied: true, marks: 3, basis: EvidenceBasis.uncertain),
        ]),
        task(400),
        standard: firm,
      );
      expect(out.awardedMarks, 3);
      expect(out.adjustments.first, contains('uncertain reading, so it earns nothing (Firm)'));
    });

    group('a point must be stated in the answer', () {
      MarkingTask about(String text) => MarkingTask(
            question: question('1', text: 'Explain MQTT.', marks: 13),
            answer: StudentAnswer(
              questionId: 'Q1',
              pages: const <int>[1],
              regionIds: const <String>['r1'],
              textEvidence: <TextEvidenceItem>[
                TextEvidenceItem(
                  regionId: 'r1',
                  pageNumber: 1,
                  type: RegionType.handwrittenAnswer,
                  text: '$text ${List<String>.filled(300, 'filler').join(' ')}',
                  rawText: text,
                  confidence: 0.9,
                  source: ReadingSource.trocr,
                ),
              ],
              answerConfidence: 0.9,
              alignmentConfidence: 1,
            ),
          );
      QuestionResult credited({List<InterpretedReading> readings = const <InterpretedReading>[]}) => QuestionResult(
            questionNumber: '1',
            questionId: 'Q1',
            maximumMarks: 13,
            awardedMarks: 8,
            studentAnswer: 'answer',
            evaluation: 'ok',
            confidence: 0.9,
            qualityBand: QualityBand.excellent,
            interpretedReadings: readings,
            markingPoints: const <MarkingPoint>[
              MarkingPoint(criterion: 'Explains the broker architecture', satisfied: true, marks: 4),
              MarkingPoint(criterion: 'Describes QoS levels', satisfied: true, marks: 4),
            ],
          );

      test('a point none of whose terms appear is halved at Firm, and earns nothing at Tough', () {
        final QuestionResult firmOut = apply(credited(), about('The broker relays messages.'), standard: firm);
        expect(firmOut.awardedMarks, 6);
        expect(firmOut.adjustments.first, contains('“Describes QoS levels” was credited, but none of its terms (level, qos)'));
        expect(apply(credited(), about('The broker relays messages.'), standard: tough).awardedMarks, 4);
        expect(apply(credited(), about('The broker relays messages.')).awardedMarks, 8); // Standard
      });

      test('a term the AI read in context counts', () {
        final QuestionResult out = apply(
          credited(readings: const <InterpretedReading>[
            InterpretedReading(regionId: 'r1', raw: 'Q0S', interpreted: 'QoS', basis: EvidenceBasis.inferred),
          ]),
          about('The broker relays messages. Q0S 0, 1 and 2.'),
          standard: firm,
        );
        expect(out.awardedMarks, 8);
      });

      test('a criterion with a single subject term is not judged by words', () {
        final QuestionResult out = apply(
          QuestionResult(
            questionNumber: '1',
            questionId: 'Q1',
            maximumMarks: 13,
            awardedMarks: 4,
            studentAnswer: 'answer',
            evaluation: 'ok',
            confidence: 0.9,
            markingPoints: const <MarkingPoint>[MarkingPoint(criterion: 'Names the protocol', satisfied: true, marks: 4)],
          ),
          about('It is MQTT.'),
          standard: firm,
        );
        expect(out.awardedMarks, 4);
      });
    });

    test('Firm never rounds up; Tough always rounds down', () {
      const MarkingStandard lenientFirm = MarkingStandard(level: MarkingLevel.lenient, realism: RealismRules(bandCap: false, lengthCap: false, fullMarksGate: false));
      expect(apply(marked(3.3), task(400), standard: lenientFirm).awardedMarks, 3.5); // nearest, not up
      expect(apply(marked(3.2), task(400), standard: lenientFirm).awardedMarks, 3);
      const MarkingStandard toughOnly = MarkingStandard(realism: RealismRules(bandCap: false, lengthCap: false, fullMarksGate: false, strictness: RealismStrictness.tough));
      expect(apply(marked(3.4), task(400), standard: toughOnly).awardedMarks, 3);
    });
  });

  group('moderation by section, and how close the AI is', () {
    test('a section with enough of the teacher’s marks gets its own factor', () {
      final Moderation m = Moderation.from(<String, List<ModerationSample>>{
        's1': <ModerationSample>[
          for (int i = 0; i < 4; i++) ModerationSample(questionId: 'A$i', ai: 2, teacher: 1, maximum: 2, section: 'A'),
          for (int i = 0; i < 3; i++) ModerationSample(questionId: 'B$i', ai: 10, teacher: 8, maximum: 13, section: 'B'),
        ],
      })!;
      expect(m.factorFor(2, 'A'), closeTo(0.5, 1e-9));
      expect(m.factorFor(13, 'B'), closeTo(0.8, 1e-9));
      expect(m.factorFor(13, 'C'), m.longFactor); // no marks of its own: short or long
      expect(m.factors, 'Section A × 0.50, Section B × 0.80');
      expect(m.describe(10, 8, 13, 'B'), startsWith('Moderated to your marking for Section B × 0.80'));
      expect(Moderation.fromJson(m.toJson()).sectionFactors, m.sectionFactors);
    });

    test('says how far the AI is from the teacher, before and after moderation', () {
      final Map<String, List<ModerationSample>> samples = <String, List<ModerationSample>>{
        's1': <ModerationSample>[
          for (int i = 0; i < 6; i++) ModerationSample(questionId: 'Q$i', ai: 2, teacher: 1, maximum: 2),
        ],
      };
      final ({double before, double after, int questions}) a =
          Moderation.agreement(samples, Moderation.from(samples)!)!;
      expect(a.before, closeTo(1, 1e-9));
      expect(a.after, closeTo(0, 1e-9));
      expect(a.questions, 6);
      expect(Moderation.gap(a.before), '1.0 mark a question above you');
      expect(Moderation.gap(-0.4), '0.4 marks a question below you');
      expect(Moderation.gap(0), 'level with you');
    });
  });
}
