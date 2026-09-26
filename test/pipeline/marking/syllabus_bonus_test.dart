import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/marking_rules.dart';
import 'package:exam_corrector/pipeline/marking/syllabus_match.dart';
import 'package:exam_corrector/pipeline/syllabus/syllabus_index.dart';

import '../pipeline_fakes.dart';

const String topics = 'MQTT protocol; broker, publish-subscribe model; QoS levels and topics';

/// Covers every term: mqtt, protocol, broker, publish, subscribe, model,
/// qos, level, topic.
const String exact = 'MQTT is a light protocol: a broker relays messages. Clients publish and '
    'subscribe to topics, and the model offers three QoS levels.';

/// Covers 7 of the 9 — no QoS, no levels.
const String close = 'MQTT is a light protocol: a broker relays messages. Clients publish and '
    'subscribe to topics in this model.';

const String weak = 'MQTT uses a broker.';

StudentAnswer written(String text) => StudentAnswer(
      questionId: 'Q1',
      pages: const <int>[1],
      regionIds: const <String>['r1'],
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

MarkingTask task(String answer, {String focus = topics, String scheme = '', bool answered = true}) => MarkingTask(
      question: question('1', text: 'Explain MQTT.', marks: 5),
      answer: answered ? written(answer) : const StudentAnswer.none('Q1'),
      syllabusFocus: focus,
      markScheme: scheme,
    );

QuestionResult marked(double awarded, {double maximum = 5}) => QuestionResult(
      questionNumber: '1',
      questionId: 'Q1',
      maximumMarks: maximum,
      awardedMarks: awarded,
      studentAnswer: 'answer',
      evaluation: 'ok',
      confidence: 0.9,
    );

const MarkingStandard on = MarkingStandard(syllabusBonus: SyllabusBonus(enabled: true));

QuestionResult apply(QuestionResult r, MarkingTask t, {MarkingStandard standard = on}) =>
    MarkingRules(
      standard.copyWith(realism: const RealismRules(bandCap: false, lengthCap: false, fullMarksGate: false, strictness: RealismStrictness.standard)),
      defaultReviewThreshold: 0.7,
    ).apply(r, t);

void main() {
  group('measuring an answer against the syllabus', () {
    test('counts the syllabus terms the answer uses, whatever their form', () {
      final SyllabusMatch match = SyllabusMatch.of(exact, topics);
      expect(match.total, 9);
      expect(match.coverage, 1);
      expect(match.matched, containsAll(<String>['level', 'topic', 'qos']));

      final SyllabusMatch partial = SyllabusMatch.of(close, topics);
      expect(partial.matched.length, 7);
      expect(partial.missing, <String>['level', 'qos']);
    });

    test('too little to measure against gives nothing', () {
      expect(SyllabusMatch.of(exact, '').isEmpty, isTrue);
      expect(SyllabusMatch.of(exact, 'MQTT broker').isEmpty, isTrue);
    });

    test("a question's focus is the syllabus topics it touches", () {
      const Syllabus iot = Syllabus(
        id: 'iot',
        fileName: 'iot.txt',
        courseTitle: 'Internet of Things',
        units: <SyllabusUnit>[
          SyllabusUnit(
            number: 'III',
            title: 'Communication',
            topics: <String>['Zigbee and Bluetooth', 'MQTT protocol and broker', 'CoAP'],
          ),
        ],
      );
      final SyllabusContext context = SyllabusIndex(iot).contextFor('Explain the MQTT protocol with its broker.');
      expect(context.focus, 'MQTT protocol and broker');
      expect(context.text, contains('Zigbee'));
    });
  });

  group('the syllabus bonus', () {
    test('a matching answer earns the badge and its bonus', () {
      final QuestionResult out = apply(marked(3), task(exact));
      expect(out.awardedMarks, 4);
      expect(out.syllabusBadge, SyllabusBadge.exact);
      expect(out.syllabusAward!.bonus, 1);
      expect(out.aiRawMarks, 3);
      expect(out.adjustments.single, contains('+1 syllabus bonus'));
      expect(out.adjustments.single, contains('9 of 9 syllabus terms (100%)'));
    });

    test('a close answer earns the smaller bonus', () {
      final QuestionResult out = apply(marked(3), task(close));
      expect(out.syllabusBadge, SyllabusBadge.almost);
      expect(out.awardedMarks, 3.5);
    });

    test('a weak answer earns nothing, but the measure is kept', () {
      final QuestionResult out = apply(marked(3), task(weak));
      expect(out.syllabusBadge, SyllabusBadge.none);
      expect(out.syllabusAward!.percent, 22);
      expect(out.awardedMarks, 3);
      expect(out.adjustments, isEmpty);
    });

    test('never takes a question above its maximum', () {
      final QuestionResult out = apply(marked(4.5), task(exact));
      expect(out.awardedMarks, 5);
      expect(out.syllabusAward!.bonus, 0.5);
      expect(out.syllabusAward!.note, contains('Capped'));
      expect(out.adjustments.single, contains('+0.5 of the +1 syllabus bonus'));
      expect(out.adjustments.single, contains('maximum of 5'));
    });

    test('full marks keep the badge, with no bonus', () {
      final QuestionResult out = apply(marked(5), task(exact));
      expect(out.awardedMarks, 5);
      expect(out.syllabusBadge, SyllabusBadge.exact);
      expect(out.syllabusAward!.bonus, 0);
      expect(out.syllabusAward!.note, contains('Already full marks'));
      expect(out.adjustments, isEmpty);
    });

    test('syllabus words alone are not enough: the answer must already have earned a share', () {
      final QuestionResult out = apply(marked(2), task(exact));
      expect(out.awardedMarks, 2);
      expect(out.syllabusBadge, SyllabusBadge.none);
      expect(out.syllabusAward!.note, contains('under the 50%'));

      const MarkingStandard any = MarkingStandard(syllabusBonus: SyllabusBonus(enabled: true, minimumShare: 0));
      expect(apply(marked(2), task(exact), standard: any).awardedMarks, 3);
    });

    test('the amounts and thresholds are the teacher’s', () {
      const MarkingStandard custom = MarkingStandard(
        syllabusBonus: SyllabusBonus(enabled: true, almostThreshold: 0.5, exactThreshold: 0.75, almostBonus: 0.25, exactBonus: 2),
      );
      expect(apply(marked(2.5), task(close), standard: custom).awardedMarks, 4.5);
      const MarkingStandard badgeOnly = MarkingStandard(
        syllabusBonus: SyllabusBonus(enabled: true, exactBonus: 0),
      );
      final QuestionResult out = apply(marked(3), task(exact), standard: badgeOnly);
      expect(out.awardedMarks, 3);
      expect(out.syllabusBadge, SyllabusBadge.exact);
      expect(out.syllabusAward!.note, isEmpty);
    });

    test('is applied after rounding', () {
      const MarkingStandard strict = MarkingStandard(
        level: MarkingLevel.strict,
        syllabusBonus: SyllabusBonus(enabled: true),
      );
      final QuestionResult out = apply(marked(3.3), task(exact), standard: strict);
      expect(out.awardedMarks, 4);
      expect(out.adjustments.first, startsWith('Rounded down'));
      expect(out.adjustments.last, contains('syllabus bonus'));
      expect(out.aiRawMarks, 3.3);
    });

    test('the printed mark scheme counts as the reference too', () {
      final QuestionResult out = apply(
        marked(3),
        task(exact, focus: '', scheme: 'MQTT protocol (1), broker (1), publish/subscribe (1), QoS levels (2)'),
      );
      expect(out.syllabusBadge, SyllabusBadge.exact);
    });

    test('off, without a reference, or unanswered: nothing', () {
      expect(apply(marked(3), task(exact), standard: const MarkingStandard()).syllabusAward, isNull);
      expect(apply(marked(3), task(exact), standard: const MarkingStandard()).awardedMarks, 3);
      expect(apply(marked(3), task(exact, focus: '')).syllabusAward, isNull);
      expect(apply(marked(0), task(exact, answered: false)).syllabusAward, isNull);
    });

    test('totals include the bonus, and no question passes its maximum', () {
      final List<QuestionResult> questions = <QuestionResult>[
        apply(marked(4.5), task(exact)),
        apply(marked(3), task(close)),
      ];
      final CorrectionResult result = CorrectionResult.fromQuestions(questions);
      expect(result.totalMarks, 8.5);
      expect(questions.every((QuestionResult q) => q.awardedMarks <= q.maximumMarks), isTrue);
    });

    test('is kept with the result', () {
      final QuestionResult out = apply(marked(4.5), task(exact));
      final QuestionResult back = QuestionResult.fromJson(out.toJson())!;
      expect(back.syllabusBadge, SyllabusBadge.exact);
      expect(back.syllabusAward!.bonus, 0.5);
      expect(back.syllabusAward!.matched, out.syllabusAward!.matched);
      expect(back.syllabusAward!.note, out.syllabusAward!.note);
    });
  });

  group('the setting', () {
    test('is arithmetic: marks already made stay valid', () {
      expect(on.judgementKey, const MarkingStandard().judgementKey);
      expect(on.changesJudgement, isFalse);
      expect(on.summary, contains('syllabus bonus +0.5/+1'));
      expect(const MarkingStandard().summary, isNot(contains('syllabus')));
    });

    test('is saved, and kept sensible when read back', () {
      const MarkingStandard custom = MarkingStandard(
        syllabusBonus: SyllabusBonus(enabled: true, almostThreshold: 0.6, exactThreshold: 0.9, exactBonus: 2),
      );
      final SyllabusBonus back = MarkingStandard.fromJson(custom.toJson()).syllabusBonus;
      expect(back.enabled, isTrue);
      expect(back.almostThreshold, 0.6);
      expect(back.exactThreshold, 0.9);
      expect(back.exactBonus, 2);

      final SyllabusBonus fixed = SyllabusBonus.fromJson(<String, Object?>{
        'enabled': true,
        'almostThreshold': 0.8,
        'exactThreshold': 0.7,
      });
      expect(fixed.exactThreshold, greaterThan(fixed.almostThreshold));
      expect(MarkingStandard.fromJson(<String, Object?>{}).syllabusBonus.enabled, isFalse);
    });
  });
}
