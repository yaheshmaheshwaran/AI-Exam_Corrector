import 'dart:convert';
import 'dart:io';

import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/services/pdf_service.dart';
import 'package:exam_corrector/services/syllabus/model_syllabus_structurer.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/services/syllabus/syllabus_parser.dart';
import 'package:exam_corrector/services/syllabus/syllabus_reader.dart';

class _Pdf extends PdfService {
  const _Pdf(this.text);
  final String? text;

  @override
  Future<String?> extractTextIfPresent(String path) async => text;
}

/// A minimal .docx: a zip holding word/document.xml.
Future<File> docx(Directory dir, List<String> paragraphs) async {
  final String xml = '<?xml version="1.0" encoding="UTF-8"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
      '${paragraphs.map((String p) => '<w:p><w:r><w:t xml:space="preserve">${const HtmlEscape().convert(p)}</w:t></w:r></w:p>').join()}'
      '</w:body></w:document>';
  final List<int> bytes = utf8.encode(xml);
  final Archive archive = Archive()..addFile(ArchiveFile('word/document.xml', bytes.length, bytes));
  final File file = File('${dir.path}/syllabus.docx');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('syllabus'));
  tearDown(() async => dir.delete(recursive: true));

  group('the parser', () {
    const SyllabusParser parser = SyllabusParser();

    test('reads a university syllabus: code, title, units, outcomes, books', () {
      final ParsedSyllabus parsed = parser.parse(File('sample/syllabus_iot.txt').readAsStringSync());

      expect(parsed.courseCode, 'CCS356');
      expect(parsed.courseTitle, 'Internet of Things and its Applications');
      expect(parsed.regulation, 'R2021');
      expect(parsed.units.map((SyllabusUnit u) => u.number), <String>['I', 'II', 'III', 'IV', 'V']);
      expect(parsed.units[1].label, 'Unit II — Introduction to IoT');
      expect(parsed.units.first.hours, 9);
      expect(parsed.units[2].topics, contains('Application protocols: MQTT, CoAP, HTTP and REST'));
      // A hyphen inside a word is not a separator.
      expect(parsed.units[2].topics, contains('Wi-Fi and LoRaWAN'));
      expect(parsed.outcomes, hasLength(5));
      expect(parsed.outcomes.first, startsWith('CO1: Explain the architecture'));
      expect(parsed.textbooks, hasLength(2));
    });

    test('reads "Module 1:" and "Unit 2 -" headings, and labelled course details', () {
      final ParsedSyllabus parsed = parser.parse('''
Course Code: CS 3401
Course Title: Operating Systems
Module 1: Processes and Threads (8 hours)
Process states; context switching; threads.
Unit 2 - Scheduling
FCFS, SJF and round robin scheduling – Priority scheduling.
''');
      expect(parsed.courseCode, 'CS3401');
      expect(parsed.courseTitle, 'Operating Systems');
      expect(parsed.units.map((SyllabusUnit u) => u.number), <String>['Module 1', '2']);
      expect(parsed.units.first.title, 'Processes and Threads');
      expect(parsed.units.first.hours, 8);
      expect(parsed.units.last.topics, <String>['FCFS, SJF and round robin scheduling', 'Priority scheduling']);
    });

    test('finds no units in text that is not a syllabus', () {
      expect(parser.parse('Dear students, the exam is on Monday.').hasUnits, isFalse);
    });
  });

  group('real PDF text', () {
    const SyllabusParser parser = SyllabusParser();

    test('code and title in separate columns, hours on their own line, dashes lost', () {
      // As a PDF's text layer gives a typical syllabus page.
      final ParsedSyllabus parsed = parser.parse('''
--- Page 1 ---
CCS356

INTERNET OF THINGS AND ITS APPLICATIONS

L T P C

2 0 2 3

UNIT I    EMBEDDED SYSTEMS

9

Embedded system definition  Processor in an embedded system  Microcontrollers

and microprocessors  Real-time operating systems.

UNIT II    INTRODUCTION TO IoT

9

Physical design of IoT  Logical design of IoT.
''');
      expect(parsed.courseCode, 'CCS356');
      expect(parsed.courseTitle, 'Internet of Things and its Applications');
      expect(parsed.units.first.hours, 9);
      expect(parsed.units.first.topics, <String>[
        'Embedded system definition',
        'Processor in an embedded system',
        'Microcontrollers and microprocessors',
        'Real-time operating systems',
      ]);
      expect(parsed.units.last.topics, <String>['Physical design of IoT', 'Logical design of IoT']);
    });

    test('a whole programme in one file becomes one syllabus per course', () {
      final List<ParsedSyllabus> courses = parser.parseAll('''
REGULATIONS 2021 — B.E. COMPUTER SCIENCE
CS3401   ALGORITHMS                          L T P C 3 0 0 3
UNIT I   INTRODUCTION   9
Asymptotic notation – Recurrences
UNIT II  GRAPHS   9
BFS – DFS – Shortest paths
CO1: Analyse algorithms.
CS3452   THEORY OF COMPUTATION               L T P C 3 0 0 3
UNIT I   AUTOMATA   9
DFA – NFA
UNIT II  GRAMMARS   9
Context free grammars – Pushdown automata
''');
      expect(courses.map((ParsedSyllabus c) => c.courseCode), <String>['CS3401', 'CS3452']);
      expect(courses.map((ParsedSyllabus c) => c.courseTitle), <String>['Algorithms', 'Theory of Computation']);
      expect(courses.first.units, hasLength(2));
      expect(courses.first.outcomes, <String>['CO1: Analyse algorithms.']);
      expect(courses.last.units.last.topics, <String>['Context free grammars', 'Pushdown automata']);
      expect(courses.every((ParsedSyllabus c) => c.regulation == 'R2021'), isTrue);
    });

    test('a real PDF, end to end', () async {
      final PdfDocument document = PdfDocument();
      final PdfFont font = PdfStandardFont(PdfFontFamily.helvetica, 10);
      final PdfPage page = document.pages.add();
      double y = 0;
      void draw(String text, double x) => page.graphics.drawString(text, font, bounds: Rect.fromLTWH(x, y, 400, 14));
      void line(String text, {String? right}) {
        draw(text, 0);
        if (right != null) draw(right, 480);
        y += 14;
      }

      line('CS3401');
      y -= 14;
      draw('ALGORITHMS', 120);
      y += 14;
      line('UNIT I    INTRODUCTION', right: '9');
      line('Asymptotic notation – Recurrences – Divide and conquer');
      line('UNIT II    GRAPHS', right: '9');
      line('Breadth first search – Depth first search');
      final File pdf = File('${dir.path}/algorithms.pdf')..writeAsBytesSync(await document.save());
      document.dispose();

      final List<Syllabus> saved = await SyllabusLibrary(Directory('${dir.path}/library')).add(pdf.path);
      expect(saved.single.name, 'Algorithms (CS3401)');
      expect(saved.single.units.map((SyllabusUnit u) => u.hours), <int?>[9, 9]);
      expect(saved.single.units.first.topics, hasLength(3));
    });
  });

  group('the reader', () {
    test('reads text, Markdown and Word files', () async {
      final File text = File('${dir.path}/s.md')..writeAsStringSync('UNIT I BASICS\nTopic one – topic two');
      expect(await const SyllabusReader().read(text.path), contains('UNIT I BASICS'));

      final File word = await docx(dir, <String>['CCS356 INTERNET OF THINGS', 'UNIT I EMBEDDED SYSTEMS 9', 'Microcontrollers – Interrupts']);
      final String read = await const SyllabusReader().read(word.path);
      expect(read.split('\n'), <String>['CCS356 INTERNET OF THINGS', 'UNIT I EMBEDDED SYSTEMS 9', 'Microcontrollers – Interrupts']);
    });

    test('refuses a scanned PDF, and says what to upload instead', () async {
      final File pdf = File('${dir.path}/scan.pdf')..writeAsStringSync('%PDF');
      await expectLater(
        const SyllabusReader(pdf: _Pdf(null)).read(pdf.path),
        throwsA(isA<SyllabusException>().having(
          (SyllabusException e) => e.message,
          'message',
          contains('no selectable text'),
        )),
      );
    });

    test('refuses a file type it cannot read', () async {
      final File doc = File('${dir.path}/old.doc')..writeAsStringSync('x');
      await expectLater(const SyllabusReader().read(doc.path), throwsA(isA<SyllabusException>()));
    });
  });

  group('the library', () {
    test('adds, lists, updates and removes; re-adding keeps the teacher\'s edits', () async {
      final SyllabusLibrary library = SyllabusLibrary(Directory('${dir.path}/library'));
      final File source = File('${dir.path}/iot.txt')
        ..writeAsStringSync(File('sample/syllabus_iot.txt').readAsStringSync());

      final Syllabus added = (await library.add(source.path)).single;
      expect(added.courseCode, 'CCS356');
      expect(added.units, hasLength(5));
      expect((await library.list()).single.id, added.id);

      await library.update(added.id, courseTitle: 'IoT and its Applications', courseCode: 'ccs 356');
      final Syllabus again = (await library.add(source.path)).single;
      expect(again.courseTitle, 'IoT and its Applications');
      expect(again.courseCode, 'CCS 356');
      expect(await library.list(), hasLength(1));

      await library.setChoice('paper', added.id);
      expect(await library.choiceFor('paper'), added.id);
      await library.remove(added.id);
      expect(await library.list(), isEmpty);
      // A paper chosen to use it goes back to automatic matching.
      expect(await library.choiceFor('paper'), isNull);
    });

    test('a file of several courses is saved course by course, and removed as a whole', () async {
      final SyllabusLibrary library = SyllabusLibrary(Directory('${dir.path}/library'));
      final File book = File('${dir.path}/programme.txt')..writeAsStringSync('''
CS3401   ALGORITHMS
UNIT I   INTRODUCTION   9
Asymptotic notation – Recurrences
CS3452   THEORY OF COMPUTATION
UNIT I   AUTOMATA   9
DFA – NFA
''');
      final List<Syllabus> saved = await library.add(book.path);
      expect(saved.map((Syllabus s) => s.courseCode), <String>['CS3401', 'CS3452']);
      expect(saved.map((Syllabus s) => s.sourceId).toSet(), hasLength(1));
      expect(saved.first.id, isNot(saved.last.id));
      expect(await library.list(), hasLength(2));

      await library.removeSource(saved.first.sourceId);
      expect(await library.list(), isEmpty);
    });

    test('a file with no units is refused, with a way forward', () async {
      final SyllabusLibrary library = SyllabusLibrary(Directory('${dir.path}/library'));
      final File letter = File('${dir.path}/letter.txt')..writeAsStringSync('Dear students, see you Monday.');
      await expectLater(
        library.add(letter.path),
        throwsA(isA<SyllabusException>().having((SyllabusException e) => e.message, 'message', contains('API key'))),
      );
      expect(await library.list(), isEmpty);
    });

    test('reading reports each step, and can be cancelled before anything is saved', () async {
      final SyllabusLibrary library = SyllabusLibrary(Directory('${dir.path}/library'));
      final List<String> steps = <String>[];
      await library.add('sample/syllabus_iot.txt', onProgress: steps.add);
      expect(steps, <String>[
        'Reading the text of syllabus_iot.txt…',
        'Finding the courses and units in syllabus_iot.txt…',
      ]);

      final SyllabusLibrary other = SyllabusLibrary(Directory('${dir.path}/other'));
      final CancellationToken token = CancellationToken()..cancel();
      await expectLater(other.add('sample/syllabus_iot.txt', cancel: token), throwsA(isA<CancelledException>()));
      expect(await other.list(), isEmpty);
    });

    test('the choice "none" is kept for a paper', () async {
      final SyllabusLibrary library = SyllabusLibrary(Directory('${dir.path}/library'));
      await library.setChoice('paper', SyllabusLibrary.none);
      expect(await SyllabusLibrary(library.root).choiceFor('paper'), SyllabusLibrary.none);
      await library.setChoice('paper', null);
      expect(await library.choiceFor('paper'), isNull);
    });
  });

  test("the model's reading of an unusual syllabus is kept as it gave it", () {
    final ParsedSyllabus parsed = ModelSyllabusStructurer.fromPayload(<String, Object?>{
      'course_title': 'Data Structures',
      'course_code': 'CS201',
      'regulation': '',
      'units': <Object?>[
        <String, Object?>{'number': '1', 'title': 'Lists', 'topics': <String>['Arrays', ' Linked lists '], 'hours': 10},
        <String, Object?>{'number': '2', 'title': 'Trees', 'topics': <String>[], 'hours': -1},
      ],
      'outcomes': <String>['CO1: Use lists'],
      'textbooks': <String>[],
    });
    expect(parsed.units.first.topics, <String>['Arrays', 'Linked lists']);
    expect(parsed.units.first.hours, 10);
    expect(parsed.units.last.hours, isNull);
    expect(parsed.courseCode, 'CS201');
  });

  test('a syllabus survives being saved', () {
    final Syllabus syllabus = Syllabus(
      id: 'abc',
      fileName: 'iot.pdf',
      courseTitle: 'Internet of Things',
      courseCode: 'CCS356',
      units: const <SyllabusUnit>[SyllabusUnit(number: 'I', title: 'Basics', topics: <String>['Sensors'], hours: 9)],
      outcomes: const <String>['CO1: Explain'],
      addedAt: DateTime(2026, 9, 26),
    );
    final Syllabus back = Syllabus.fromJson(jsonDecode(jsonEncode(syllabus.toJson())) as Map<String, Object?>)!;
    expect(back.name, 'Internet of Things (CCS356)');
    expect(back.units.single.label, 'Unit I — Basics');
    expect(back.units.single.hours, 9);
    expect(back.addedAt, DateTime(2026, 9, 26));
  });
}
