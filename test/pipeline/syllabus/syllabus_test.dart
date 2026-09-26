import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/marking_prompt.dart';
import 'package:exam_corrector/pipeline/syllabus/syllabus_index.dart';
import 'package:exam_corrector/pipeline/syllabus/syllabus_matcher.dart';
import 'package:exam_corrector/services/syllabus/syllabus_parser.dart';

import '../marking/marking_test.dart' show answerWith;
import '../pipeline_fakes.dart';

Syllabus iot() {
  final ParsedSyllabus parsed =
      const SyllabusParser().parse(File('sample/syllabus_iot.txt').readAsStringSync());
  return Syllabus(
    id: 'iot',
    fileName: 'syllabus_iot.txt',
    courseTitle: parsed.courseTitle,
    courseCode: parsed.courseCode,
    regulation: parsed.regulation,
    units: parsed.units,
    outcomes: parsed.outcomes,
  );
}

const Syllabus operatingSystems = Syllabus(
  id: 'os',
  fileName: 'os.txt',
  courseTitle: 'Operating Systems',
  courseCode: 'CS3401',
  units: <SyllabusUnit>[
    SyllabusUnit(number: 'I', title: 'Processes', topics: <String>['Process states', 'Context switching', 'Threads']),
    SyllabusUnit(number: 'II', title: 'Memory', topics: <String>['Paging', 'Segmentation', 'Virtual memory']),
  ],
);

void main() {
  final Syllabus syllabus = iot();

  group('matching a paper to its syllabus', () {
    const SyllabusMatcher matcher = SyllabusMatcher();
    final List<Syllabus> library = <Syllabus>[operatingSystems, syllabus];

    test('by the course title on the paper — your IoT paper', () {
      final SyllabusMatch? match = matcher.best(
        library,
        title: 'Internet of Things and Its Applications',
        text: 'An embedded system is primarily designed to perform\n'
            'The processor in an embedded system mainly performs',
      );
      expect(match?.syllabus.id, 'iot');
      expect(match!.reason, 'course title');
    });

    test('by the course code anywhere on the paper', () {
      final SyllabusMatch? match = matcher.best(
        library,
        title: '',
        text: 'B.E. DEGREE EXAMINATION\nCCS 356 — IOT\n1. Define IoT.',
      );
      expect(match?.syllabus.id, 'iot');
      expect(match!.reason, contains('CCS356'));
    });

    test('by the topics the questions cover, when the title says little', () {
      final SyllabusMatch? match = matcher.best(
        library,
        title: 'Continuous assessment test 2',
        text: 'Compare MQTT and CoAP. Explain ZigBee and Bluetooth Low Energy. '
            'Describe the physical design of IoT and its protocols. What is LoRaWAN?',
      );
      expect(match?.syllabus.id, 'iot');
    });

    test('an unrelated paper matches nothing, rather than the wrong course', () {
      final SyllabusMatch? match = matcher.best(
        library,
        title: 'Year 10 Combined Science - Biology Paper 1',
        text: File('sample/question_paper.txt').readAsStringSync(),
      );
      expect(match, isNull);
    });
  });

  group("each question's part of the syllabus", () {
    final SyllabusIndex index = SyllabusIndex(syllabus);

    test('finds the unit the question is about', () {
      final SyllabusContext rtos = index.contextFor('Explain priority inversion in a real-time operating system.');
      expect(rtos.label, 'Unit I — Embedded Systems');
      // The topic the question touches comes first.
      expect(rtos.text, startsWith('Unit I — Embedded Systems (9 hours): Real-time operating systems'));

      expect(index.contextFor('Compare the MQTT and CoAP application protocols.').label,
          'Unit III — IoT Communication and Connectivity');
    });

    test('honours a unit the question names', () {
      expect(index.contextFor('(Unit II) Write short notes on deployment templates.').label,
          'Unit II — Introduction to IoT');
    });

    test('gives no unit rather than a guess', () {
      expect(index.contextFor('Define osmosis and give an example.').isEmpty, isTrue);
    });

    test('stays within its size', () {
      final Syllabus long = Syllabus(
        id: 'long',
        fileName: 'long.txt',
        courseTitle: 'Long',
        units: <SyllabusUnit>[
          SyllabusUnit(
            number: 'I',
            title: 'Sensors',
            topics: <String>[for (int i = 0; i < 80; i++) 'Sensor topic number $i about sensing'],
          ),
        ],
      );
      final SyllabusContext context = SyllabusIndex(long).contextFor('Explain sensors and sensing.');
      expect(context.text.length, lessThanOrEqualTo(SyllabusIndex.maxCharacters + 5));
      expect(context.text, endsWith('; …'));
    });

    test('the course header carries the title, regulation and outcomes', () {
      expect(index.courseHeader, startsWith('Internet of Things and its Applications (CCS356), R2021'));
      expect(index.courseHeader, contains('CO3: Compare IoT communication'));
    });
  });

  test('the marker is given the syllabus as a reference, never an answer key', () {
    final SyllabusIndex index = SyllabusIndex(syllabus);
    final SyllabusContext context = index.contextFor('Compare MQTT and CoAP.');
    final String text = MarkingPrompt.buildBatch(
      tasks: <MarkingTask>[
        MarkingTask(
          question: question('1', text: 'Compare MQTT and CoAP.'),
          answer: answerWith(),
          syllabus: context.text,
          syllabusLabel: context.label,
          syllabusCourse: index.courseHeader,
        ),
        MarkingTask(
          question: question('2', text: 'Define IoT.'),
          answer: answerWith(),
          syllabusCourse: index.courseHeader,
        ),
      ],
      aliases: <String, String>{},
      guidance: '',
      typedAnswerSheet: false,
    );

    expect('COURSE SYLLABUS (reference'.allMatches(text), hasLength(1));
    expect(text, contains('Syllabus reference (what the course teaches here — not an answer key): '
        'Unit III — IoT Communication and Connectivity'));
    expect('Syllabus reference'.allMatches(text), hasLength(1));
    expect(MarkingPrompt.systemPrompt, contains('never an answer key'));
    expect(MarkingPrompt.systemPrompt, contains('Do not rely on the syllabus alone'));
    expect(MarkingPrompt.systemPrompt, contains('Never deduct marks because an answer includes correct material beyond the syllabus'));
  });
}
