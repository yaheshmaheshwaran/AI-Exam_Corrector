import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:exam_corrector/ai/model_request.dart';
import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/marking/script/examiner_marks.dart';
import 'package:exam_corrector/marking/script/page_reader.dart';

const ExamPage _page = ExamPage(pageId: 'doc:p5', pageNumber: 5, width: 1652, height: 2338);

Map<String, Object?> _region(
  String type, {
  List<int> box = const <int>[100, 100, 200, 900],
  List<String> lines = const <String>[],
  String label = '',
  String strike = 'none',
  List<String> uncertain = const <String>[],
  Map<String, Object?>? diagram,
}) =>
    <String, Object?>{
      'type': type,
      'box_2d': box,
      'label': label,
      'lines': lines,
      'uncertain_words': uncertain,
      'strike_kind': strike,
      'confidence': 0.9,
      'diagram': ?diagram,
    };

PageResult _parse(List<Map<String, Object?>> regions, {bool blank = false}) => PageReader.parsePage(
      <String, Object?>{'page_index': 0, 'is_blank': blank, 'regions': regions},
      _page,
      model: 'gemini/gemini-3.1-flash-lite',
    );

/// Answers each request with what [answer] makes of how many pages it holds.
class _Client implements ModelClient {
  _Client(this.answer);

  final Object? Function(int pages) answer;
  final List<int> batches = <int>[];

  @override
  bool get isAvailable => true;

  @override
  Future<ModelResponse> requestJson(
    ModelRequest request, {
    required List<String> models,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) async {
    final int pages = request.imageCount;
    batches.add(pages);
    final Object? payload = answer(pages);
    if (payload is AppException) throw payload;
    return ModelResponse(payload: payload, model: models.first);
  }
}

void main() {
  group('a page as read becomes regions and evidence', () {
    test('writing keeps its lines, label, place and reading order', () {
      final PageResult result = _parse(<Map<String, Object?>>[
        _region('question_number', lines: <String>['17)'], label: '17)'),
        _region('handwritten_answer',
            box: <int>[250, 120, 400, 880],
            lines: <String>['Arduino Mega is a microcontroller', 'board based on ATmega 2560.']),
      ]);

      expect(result.regions, hasLength(2));
      final PageRegion answer = result.regions.last;
      expect(answer.regionId, 'doc:p5:v2-1');
      expect(answer.readingOrder, 1);
      expect(answer.origin, RegionOrigin.vision);
      expect(answer.box.y, closeTo(0.25, 1e-9));
      expect(answer.box.x, closeTo(0.12, 1e-9));
      expect(result.regions.first.detectedLabel, '17)');
      final HandwritingReading reading = result.handwriting[answer.regionId]!.primary!;
      expect(reading.text, 'Arduino Mega is a microcontroller\nboard based on ATmega 2560.');
      expect(reading.source, ReadingSource.vision);
      expect(reading.engine, 'gemini/gemini-3.1-flash-lite');
      expect(reading.crossedOut, isFalse);
    });

    test("the student's own crossing-out is crossed out; an examiner's slash never is", () {
      final PageResult result = _parse(<Map<String, Object?>>[
        _region('crossed_out', lines: <String>['It runs at 8 MHz.'], strike: 'student_line'),
        _region('crossed_out', lines: <String>['the data to processors'], strike: 'examiner_mark'),
        _region('handwritten_answer', lines: <String>['sends it to the actuators'], strike: 'unsure'),
      ]);

      final List<PageRegion> regions = result.regions;
      expect(regions[0].type, RegionType.crossedOut);
      expect(result.handwriting[regions[0].regionId]!.crossedOutVerdict, isTrue);
      // The examiner's stroke leaves the writing as the student's answer.
      expect(regions[1].type, RegionType.handwrittenAnswer);
      expect(result.handwriting[regions[1].regionId]!.crossedOutVerdict, isNot(isTrue));
      // Unsure: kept as answer, and said to be possibly struck.
      expect(regions[2].type, RegionType.handwrittenAnswer);
      expect(result.handwriting[regions[2].regionId]!.crossedOutVerdict, isTrue);
    });

    test('a "crossed out" word the model also kept in the answer is an examiner tick, and is dropped', () {
      final PageResult result = _parse(<Map<String, Object?>>[
        _region('handwritten_answer', lines: <String>['clock speed with a SRAM of 54KB & EEPROM']),
        _region('crossed_out', lines: <String>['SRAM'], strike: 'student_line'),
        _region('crossed_out', lines: <String>['54KB'], strike: 'scribble'),
        _region('crossed_out', lines: <String>['Arr'], strike: 'scribble'),
      ]);
      expect(result.regions.map((PageRegion r) => r.type), <RegionType>[RegionType.handwrittenAnswer, RegionType.crossedOut]);
      expect(result.handwriting[result.regions.last.regionId]!.rawText, 'Arr');
      expect(result.regions.last.readingOrder, 1);
      expect(result.handwriting, hasLength(2));
    });

    test('uncertain words are placed in the text and lower the confidence', () {
      final PageResult sure = _parse(<Map<String, Object?>>[
        _region('handwritten_answer', lines: <String>['sixteen analog inputs and fifty four digital pins']),
      ]);
      final PageResult unsure = _parse(<Map<String, Object?>>[
        _region('handwritten_answer',
            lines: <String>['sixteen anal0g inputs and fifty four dgital pins'],
            uncertain: <String>['anal0g', 'dgital']),
      ]);

      final HandwritingEvidence evidence = unsure.handwriting.values.single;
      expect(evidence.uncertainSpans.map((UncertainSpan s) => (s.start, s.end)), <(int?, int?)>[(8, 14), (37, 43)]);
      expect(evidence.confidence, lessThan(sure.handwriting.values.single.confidence));
      expect(sure.handwriting.values.single.confidence, greaterThan(0.9));
    });

    test('a diagram keeps its boxes and arrows as drawn', () {
      final PageResult result = _parse(<Map<String, Object?>>[
        _region('diagram', diagram: <String, Object?>{
          'diagram_kind': 'flowchart',
          'description': 'Workflow of a smart greenhouse',
          'nodes': <Object?>[
            <String, Object?>{'id': 'n1', 'text': 'Sensors'},
            <String, Object?>{'id': 'n2', 'text': 'Processor'},
          ],
          'edges': <Object?>[
            <String, Object?>{'from': 'n1', 'to': 'n2', 'label': 'Data', 'arrow': 'forward'},
          ],
        }),
      ]);

      final DiagramEvidence diagram = result.visuals.values.single as DiagramEvidence;
      expect(result.handwriting, isEmpty);
      expect(diagram.regionId, result.regions.single.regionId);
      expect(diagram.flow, <String>['Sensors → Processor [Data]']);
      expect(diagram.diagramKind, 'flowchart');
    });

    test('stray control characters and runs of spaces are cleaned away', () {
      final PageResult result = _parse(<Map<String, Object?>>[
        _region('handwritten_answer', lines: <String>['[\x10 b\x10 ]  Answer:   loop()']),
      ]);
      expect(result.handwriting.values.single.rawText, '[ b ] Answer: loop()');
    });

    test('a region without a usable box is dropped; a blank page is blank', () {
      expect(_parse(<Map<String, Object?>>[_region('handwritten_answer', box: <int>[1, 2])]).regions, isEmpty);
      expect(_parse(const <Map<String, Object?>>[], blank: true).blank, isTrue);
      expect(_parse(<Map<String, Object?>>[_region('footer', lines: <String>['Page No. 5'])], blank: true).blank, isTrue);
    });

    test('an open model gives its boxes x first', () {
      final PageResult result = PageReader.parsePage(
        <String, Object?>{
          'page_index': 0,
          'regions': <Object?>[_region('handwritten_answer', box: <int>[120, 250, 880, 400], lines: <String>['x'])],
        },
        _page,
        model: 'server/Qwen/Qwen3-VL-8B-Instruct',
        xFirst: true,
      );
      expect(result.regions.single.box.x, closeTo(0.12, 1e-9));
      expect(result.regions.single.box.y, closeTo(0.25, 1e-9));
    });
  });

  group('reading a script', () {
    late Directory dir;
    late List<ExamPage> pages;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('reader');
      final Uint8List jpeg = img.encodeJpg(img.Image(width: 100, height: 140));
      pages = <ExamPage>[
        for (int n = 1; n <= 5; n++)
          ExamPage(
            pageId: 'doc:p$n',
            pageNumber: n,
            width: 100,
            height: 140,
            imagePath: (File('${dir.path}/p$n.jpg')..writeAsBytesSync(jpeg)).path,
          ),
      ];
    });
    tearDown(() => dir.delete(recursive: true));

    Map<String, Object?> answer(int count, {String type = 'handwritten_answer'}) => <String, Object?>{
          'pages': <Object?>[
            for (int i = 0; i < count; i++)
              <String, Object?>{
                'page_index': i,
                'regions': <Object?>[
                  _region(type, lines: <String>['line $i']),
                ],
              },
          ],
        };

    test('pages go three to a request, and every page comes back with its own regions', () async {
      final _Client client = _Client(answer);
      final PageReadout readout = await PageReader(client, models: const <String>['gemini/x']).read(
        pages,
        cropFolder: Directory('${dir.path}/crops'),
      );

      expect(client.batches..sort(), <int>[2, 3]);
      expect(readout.pages.map((ExamPage p) => p.regions.length), <int>[1, 1, 1, 1, 1]);
      expect(readout.handwriting, hasLength(5));
      expect(readout.warnings, isEmpty);
      expect(readout.models[4], 'gemini/x');
    });

    test('an answer cut off is asked for again one page at a time', () async {
      final _Client client = _Client(
        (int count) => count > 1 ? const CorrectionException('Too long.', truncated: true) : answer(1),
      );
      final PageReadout readout = await PageReader(client, models: const <String>['gemini/x']).read(
        pages,
        cropFolder: Directory('${dir.path}/crops'),
      );

      expect(readout.pages.every((ExamPage p) => p.regions.isNotEmpty), isTrue);
      expect(client.batches.where((int b) => b == 1), hasLength(5));
    });

    test('a drawing gets a crop of its own ink; confident writing does not', () async {
      final PageReadout readout = await PageReader(_Client((int count) => answer(count, type: 'diagram')),
              models: const <String>['gemini/x'])
          .read(pages.sublist(0, 1), cropFolder: Directory('${dir.path}/crops'));
      final PageRegion diagram = readout.pages.single.regions.single;
      expect(diagram.cropPath, isNotNull);
      expect(File(diagram.cropPath!).existsSync(), isTrue);

      final PageReadout writing = await PageReader(_Client(answer), models: const <String>['gemini/x'])
          .read(pages.sublist(0, 1), cropFolder: Directory('${dir.path}/crops'));
      expect(writing.pages.single.regions.single.cropPath, isNull);
    });

    test('pages the model numbered its own way are matched in order', () async {
      // Asked about one page, it answers for "page 1" — or the booklet's 5.
      for (final int numbered in <int>[1, 5]) {
        final PageReadout readout = await PageReader(
          _Client((int count) => <String, Object?>{
                'pages': <Object?>[
                  <String, Object?>{
                    'page_index': numbered,
                    'regions': <Object?>[
                      _region('handwritten_answer', lines: <String>['read']),
                    ],
                  },
                ],
              }),
          models: const <String>['gemini/x'],
        ).read(pages.sublist(4), cropFolder: Directory('${dir.path}/crops'));
        expect(readout.warnings, isEmpty, reason: 'numbered $numbered');
        expect(readout.pages.single.regions, hasLength(1));
      }
    });

    test('what was read survives being saved', () async {
      final PageReadout readout = await PageReader(_Client(answer), models: const <String>['gemini/x'])
          .read(pages, cropFolder: Directory('${dir.path}/crops'));
      final PageReadout again = PageReadout.fromJson(readout.toJson())!;
      expect(again.pages.map((ExamPage p) => p.regions.length), <int>[1, 1, 1, 1, 1]);
      expect(again.handwriting.keys, readout.handwriting.keys);
      expect(again.models, readout.models);
    });
  });

  test('a line that looks like an examiner score or tick is reported', () {
    expect(ExaminerMarks.suspicious('Sensors read data\n3\n4/5\n2½\n✓ good\n16 MHz crystal\n1) Sensors'),
        <String>['3', '4/5', '2½', '✓ good']);
    expect(ExaminerMarks.suspicious('The answer is 3/4 of the total'), isEmpty);
    expect(ExaminerMarks.suspicious('17.\n2)\n(b)\n1.5'), <String>['1.5']);
  });
}
