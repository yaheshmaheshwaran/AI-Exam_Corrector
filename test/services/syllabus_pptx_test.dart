import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/services/ai/model_client.dart';
import 'package:exam_corrector/services/syllabus/model_syllabus_structurer.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/services/syllabus/syllabus_parser.dart';
import 'package:exam_corrector/services/syllabus/syllabus_reader.dart';

import '../pipeline/pipeline_fakes.dart';

const String _ns = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"';

String _esc(String text) => const HtmlEscape().convert(text);

/// A text box: at [y] (EMU) unless it is a title placeholder with none.
String textBox(List<String> paragraphs, {int? y, int x = 457200, bool title = false}) => '<p:sp>'
    '<p:nvSpPr><p:cNvPr id="2" name="Box"/><p:cNvSpPr/><p:nvPr>${title ? '<p:ph type="title"/>' : ''}</p:nvPr></p:nvSpPr>'
    '<p:spPr>${y == null ? '' : '<a:xfrm><a:off x="$x" y="$y"/><a:ext cx="8000000" cy="500000"/></a:xfrm>'}</p:spPr>'
    '<p:txBody><a:bodyPr/>${paragraphs.map((String t) => '<a:p><a:r><a:t>${_esc(t)}</a:t></a:r></a:p>').join()}</p:txBody>'
    '</p:sp>';

String table(List<List<String>> rows, {int y = 1000000}) => '<p:graphicFrame>'
    '<p:nvGraphicFramePr><p:cNvPr id="3" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>'
    '<p:xfrm><a:off x="457200" y="$y"/><a:ext cx="8000000" cy="3000000"/></p:xfrm>'
    '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl>'
    '${rows.map((List<String> row) => '<a:tr h="370840">${row.map((String cell) => '<a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>${_esc(cell)}</a:t></a:r></a:p></a:txBody></a:tc>').join()}</a:tr>').join()}'
    '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>';

String picture(String relId) => '<p:pic>'
    '<p:nvPicPr><p:cNvPr id="4" name="Picture"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>'
    '<p:blipFill><a:blip r:embed="$relId"/></p:blipFill>'
    '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="6858000"/></a:xfrm></p:spPr>'
    '</p:pic>';

String slide(String shapes, {bool hidden = false}) =>
    '<?xml version="1.0" encoding="UTF-8"?><p:sld $_ns${hidden ? ' show="0"' : ''}><p:cSld><p:spTree>'
    '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'
    '$shapes</p:spTree></p:cSld></p:sld>';

/// A deck whose slides are shown in [order] — file names, not their numbers.
Future<File> deck(
  Directory dir,
  Map<String, String> slides, {
  required List<String> order,
  Map<String, List<int>> media = const <String, List<int>>{},
  Map<String, String> slideRels = const <String, String>{},
  String name = 'syllabus.pptx',
}) async {
  final Archive archive = Archive();
  void add(String path, List<int> bytes) => archive.addFile(ArchiveFile(path, bytes.length, bytes));

  add('ppt/presentation.xml', utf8.encode('<?xml version="1.0" encoding="UTF-8"?><p:presentation $_ns><p:sldIdLst>'
      '${<String>[for (int i = 0; i < order.length; i++) '<p:sldId id="${256 + i}" r:id="rIdS$i"/>'].join()}'
      '</p:sldIdLst></p:presentation>'));
  add('ppt/_rels/presentation.xml.rels', utf8.encode('<?xml version="1.0" encoding="UTF-8"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '${<String>[for (int i = 0; i < order.length; i++) '<Relationship Id="rIdS$i" Type="slide" Target="slides/${order[i]}"/>'].join()}'
      '</Relationships>'));
  for (final MapEntry<String, String> s in slides.entries) {
    add('ppt/slides/${s.key}', utf8.encode(s.value));
  }
  for (final MapEntry<String, String> r in slideRels.entries) {
    add('ppt/slides/_rels/${r.key}.rels', utf8.encode(r.value));
  }
  for (final MapEntry<String, List<int>> m in media.entries) {
    add('ppt/media/${m.key}', m.value);
  }
  final File file = File('${dir.path}/$name');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

final List<int> png = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('pptx'));
  tearDown(() async => dir.delete(recursive: true));

  /// Slide 1: title and regulation; 2: the units table; 3: hidden; 4: a
  /// picture of more syllabus. Stored in the zip out of order.
  Future<File> collegeDeck() => deck(
        dir,
        <String, String>{
          'slide7.xml': slide(
            // The body comes first in the file but sits lower on the slide.
            textBox(<String>['Regulation 2021'], y: 2000000) +
                textBox(<String>['CCS356  INTERNET OF THINGS'], title: true),
          ),
          'slide2.xml': slide(table(<List<String>>[
            <String>['Unit', 'Title', 'Contents', 'Hours'],
            <String>['UNIT I', 'Embedded Systems', 'Microcontrollers – Interrupts – Real-time operating systems', '9'],
            <String>[
              'II',
              'Introduction to IoT',
              'Physical design of IoT, logical design of IoT, IoT levels and deployment templates, '
                  'enabling technologies, wireless sensor networks',
              '9',
            ],
          ])),
          'slide5.xml': slide(textBox(<String>['UNIT IX SECRET 9'], y: 100), hidden: true),
          'slide1.xml': slide(picture('rIdImg')),
        },
        order: <String>['slide7.xml', 'slide2.xml', 'slide5.xml', 'slide1.xml'],
        slideRels: <String, String>{
          'slide1.xml': '<?xml version="1.0" encoding="UTF-8"?>'
              '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rIdImg" Type="image" Target="../media/image1.png"/></Relationships>',
        },
        media: <String, List<int>>{'image1.png': png},
      );

  test('a deck is read slide by slide, as shown, and each slide as it is read', () async {
    final SyllabusText read = await const SyllabusReader().readDocument((await collegeDeck()).path);
    final List<String> lines = read.text.trim().split('\n');

    expect(lines.take(3), <String>['--- Slide 1 ---', 'CCS356  INTERNET OF THINGS', 'Regulation 2021']);
    expect(lines[3], '--- Slide 2 ---');
    expect(lines[4], 'Unit\tTitle\tContents\tHours');
    expect(read.text, isNot(contains('SECRET')));
    expect(read.pictureSlides.single.slide, 4);
    expect(read.pictureSlides.single.mimeType, 'image/png');
  });

  test('a table of units becomes units, with titles, topics and hours', () async {
    final ParsedSyllabus parsed =
        const SyllabusParser().parse((await const SyllabusReader().readDocument((await collegeDeck()).path)).text);

    expect(parsed.courseCode, 'CCS356');
    expect(parsed.courseTitle, 'Internet of Things');
    expect(parsed.regulation, 'R2021');
    expect(parsed.units.map((SyllabusUnit u) => u.label),
        <String>['Unit I — Embedded Systems', 'Unit II — Introduction to IoT']);
    expect(parsed.units.map((SyllabusUnit u) => u.hours), <int?>[9, 9]);
    expect(parsed.units.first.topics,
        <String>['Microcontrollers', 'Interrupts', 'Real-time operating systems']);
    // A cell listing its topics with commas alone.
    expect(parsed.units.last.topics, hasLength(5));
  });

  test('without an API key the text is saved, and the picture slide is named', () async {
    final SyllabusLibrary library = SyllabusLibrary(Directory('${dir.path}/library'));
    final Syllabus saved = (await library.add((await collegeDeck()).path)).single;

    expect(saved.units, hasLength(2));
    expect(saved.structuredBy, 'parser');
    expect(saved.notes.single, allOf(contains('Slide 4 is a picture'), contains('API key')));
  });

  test('with the AI, the picture slide is sent to be read with the text', () async {
    final FakeModelClient model = FakeModelClient((ModelRequest r, List<String> m) => <String, Object?>{
          'course_title': 'Internet of Things',
          'course_code': 'CCS356',
          'regulation': 'R2021',
          'units': <Object?>[
            for (final String n in <String>['I', 'II', 'III'])
              <String, Object?>{'number': n, 'title': 'Unit $n', 'topics': <String>['Topic $n'], 'hours': 9},
          ],
          'outcomes': <String>[],
          'textbooks': <String>[],
        });
    final SyllabusLibrary library = SyllabusLibrary(
      Directory('${dir.path}/library'),
      structurer: ModelSyllabusStructurer(model, () => pipelineConfig),
    );
    final List<String> progress = <String>[];

    final Syllabus saved =
        (await library.add((await collegeDeck()).path, onProgress: progress.add)).single;

    final ModelRequest request = model.requests.single;
    expect(request.parts.whereType<ImagePart>().single.mimeType, 'image/png');
    expect(request.parts.whereType<TextPart>().map((TextPart p) => p.text), contains('Slide 4, a picture:'));
    expect(saved.units, hasLength(3));
    expect(saved.structuredBy, 'model');
    expect(saved.notes, isEmpty);
    expect(progress, contains(startsWith('Slide 4 is a picture — asking the AI to read it')));
  });

  test('a deck whose syllabus is all pictures, with no key, says what it needs', () async {
    final File file = await deck(
      dir,
      <String, String>{'slide1.xml': slide(picture('rIdImg'))},
      order: <String>['slide1.xml'],
      slideRels: <String, String>{
        'slide1.xml': '<?xml version="1.0" encoding="UTF-8"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rIdImg" Type="image" Target="../media/image1.png"/></Relationships>',
      },
      media: <String, List<int>>{'image1.png': png},
    );
    await expectLater(
      SyllabusLibrary(Directory('${dir.path}/library')).add(file.path),
      throwsA(isA<SyllabusException>().having(
        (SyllabusException e) => e.message,
        'message',
        allOf(contains('in pictures (slides 1)'), contains('API key')),
      )),
    );
  });

  test('a Word table of units reads the same way', () async {
    String cell(String text) => '<w:tc><w:p><w:r><w:t>${_esc(text)}</w:t></w:r></w:p></w:tc>';
    String row(List<String> cells) => '<w:tr>${cells.map(cell).join()}</w:tr>';
    final String xml = '<?xml version="1.0" encoding="UTF-8"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
        '<w:p><w:r><w:t>Course Code: CS3401</w:t></w:r></w:p>'
        '<w:tbl>${row(<String>['S.No', 'Unit', 'Contents', 'Periods'])}'
        '${row(<String>['1', 'Unit 1', 'Processes: process states – threads', '9'])}'
        '${row(<String>['2', 'Unit 2', 'Memory: paging – segmentation', '9'])}</w:tbl>'
        '</w:body></w:document>';
    final List<int> bytes = utf8.encode(xml);
    final File file = File('${dir.path}/os.docx')
      ..writeAsBytesSync(ZipEncoder().encode(Archive()..addFile(ArchiveFile('word/document.xml', bytes.length, bytes))));

    final ParsedSyllabus parsed = const SyllabusParser().parse(await const SyllabusReader().read(file.path));
    expect(parsed.courseCode, 'CS3401');
    expect(parsed.units.map((SyllabusUnit u) => u.label), <String>['Unit 1 — Processes', 'Unit 2 — Memory']);
    expect(parsed.units.first.topics, <String>['process states', 'threads']);
    expect(parsed.units.first.hours, 9);
  });

  test('an old .ppt is refused, with how to save it as .pptx', () async {
    final File old = File('${dir.path}/syllabus.ppt')..writeAsStringSync('x');
    await expectLater(
      const SyllabusReader().read(old.path),
      throwsA(isA<SyllabusException>().having((SyllabusException e) => e.message, 'message', contains('save it as .pptx'))),
    );
  });
}
