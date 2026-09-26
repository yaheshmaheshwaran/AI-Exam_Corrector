import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/pipeline/document/document_inspector.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/services/pdf_service.dart';

/// Writes a real PDF, one entry per page; an empty entry is a page with no
/// text layer — what a scanned page looks like to the text extractor.
Future<File> _writePages(Directory directory, String name, List<String> pages) async {
  final PdfDocument document = PdfDocument();
  for (final String text in pages) {
    final PdfPage page = document.pages.add();
    if (text.isNotEmpty) {
      page.graphics.drawString(
        text,
        PdfStandardFont(PdfFontFamily.helvetica, 12),
        bounds: const Rect.fromLTWH(0, 0, 500, 700),
      );
    } else {
      page.graphics.drawEllipse(const Rect.fromLTWH(50, 50, 200, 200));
    }
  }
  final List<int> bytes = await document.save();
  document.dispose();
  final File file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes);
  return file;
}

const String _answerText =
    '1 The mitochondrion is the site of aerobic respiration.\n'
    '2 Because muscle cells need a lot of energy for contraction.';

/// Writes a real PDF with a text layer, so extraction is exercised end to end
/// rather than against a fixture nobody can regenerate.
Future<File> _writePdf(Directory directory, String name, String text) async {
  final PdfDocument document = PdfDocument();
  final PdfPage page = document.pages.add();
  page.graphics.drawString(
    text,
    PdfStandardFont(PdfFontFamily.helvetica, 12),
    bounds: const Rect.fromLTWH(0, 0, 500, 700),
  );

  final List<int> bytes = await document.save();
  document.dispose();

  final File file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const PdfService service = PdfService();
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('exam_corrector_test');
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('extracts the text of a readable paper', () async {
    const String answer =
        'Question 1. The mitochondrion is the site of aerobic respiration '
        'and produces ATP for the cell to use.';
    final File file = await _writePdf(workspace, 'paper.pdf', answer);

    final String text = await service.extractText(file.path);

    expect(text, contains('--- Page 1 ---'));
    expect(text, contains('mitochondrion'));
    expect(text.length, greaterThan(answer.length ~/ 2));
  });

  group('inspection', () {
    const LocalDocumentInspector inspector = LocalDocumentInspector();

    test('a typed, multi-page PDF is a text-layer document', () async {
      final File file = await _writePages(workspace, 'typed.pdf', <String>[_answerText, _answerText, _answerText]);

      final SelectedDocument document =
          await inspector.inspect(file.path, DocumentRole.answerSheet);

      expect(document.pageCount, 3);
      expect(document.textLayerPages, 3);
      expect(document.source, DocumentSource.textLayer);
      expect(document.needsRendering, isFalse);
      expect(document.contentHash, hasLength(24));
    });

    test('a PDF with no text anywhere is treated as a scan', () async {
      final File file = await _writePages(workspace, 'scan.pdf', <String>['', '']);

      final SelectedDocument document =
          await inspector.inspect(file.path, DocumentRole.answerSheet);

      expect(document.source, DocumentSource.scanned);
      expect(document.needsRendering, isTrue);
    });

    test('a typed cover sheet stapled to a scan is mixed', () async {
      final File file = await _writePages(workspace, 'mixed.pdf', <String>[_answerText, '']);

      final SelectedDocument document =
          await inspector.inspect(file.path, DocumentRole.answerSheet);

      expect(document.source, DocumentSource.mixed);
      expect(document.textLayerPages, 1);
    });

    test('the same bytes always hash the same, and different bytes differently', () async {
      final File a = await _writePages(workspace, 'a.pdf', <String>[_answerText]);
      final File copy = await a.copy('${workspace.path}/copy.pdf');
      final File b = await _writePages(workspace, 'b.pdf', <String>['$_answerText more']);

      final String first = (await inspector.inspect(a.path, DocumentRole.answerSheet)).contentHash;
      expect((await inspector.inspect(copy.path, DocumentRole.answerSheet)).contentHash, first);
      expect((await inspector.inspect(b.path, DocumentRole.answerSheet)).contentHash, isNot(first));
    });

    test('a corrupted PDF is refused with a message for the teacher', () async {
      final File file = File('${workspace.path}/corrupt.pdf');
      await file.writeAsBytes(<int>[...'%PDF-1.7\n'.codeUnits, ...List<int>.filled(200, 7)]);

      await expectLater(
        inspector.inspect(file.path, DocumentRole.answerSheet),
        throwsA(isA<PdfExtractionException>()),
      );
    });

    test('an image is accepted as a one-page photograph', () async {
      final File file = File('${workspace.path}/photo.jpg');
      await file.writeAsBytes(List<int>.filled(64, 1));

      final SelectedDocument document =
          await inspector.inspect(file.path, DocumentRole.answerSheet);

      expect(document.source, DocumentSource.image);
      expect(document.pageCount, 1);
    });
  });

  test('reads text lines with their positions, page by page', () async {
    final File file = await _writePages(workspace, 'lines.pdf', <String>[_answerText, '']);

    final List<TextLayerPage> pages = await service.readTextLines(file.path);

    expect(pages, hasLength(2));
    expect(pages.first.lines.first.text, startsWith('1 The mitochondrion'));
    expect(pages.first.lines[1].text, startsWith('2 Because'));
    expect(pages.first.lines[1].top, greaterThan(pages.first.lines.first.top));
    expect(pages.first.width, greaterThan(0));
    expect(pages.last.lines, isEmpty);
  });

  test('rejects a PDF with no usable text layer', () async {
    final File file = await _writePdf(workspace, 'scan.pdf', '.');

    await expectLater(
      service.extractText(file.path),
      throwsA(
        isA<PdfExtractionException>().having(
          (PdfExtractionException e) => e.message,
          'message',
          contains('No readable text'),
        ),
      ),
    );
  });

  test('rejects a file that is not a PDF', () async {
    final File file = File('${workspace.path}${Platform.pathSeparator}a.txt');
    await file.writeAsString('Not a PDF at all.');

    await expectLater(
      service.extractText(file.path),
      throwsA(
        isA<PdfExtractionException>().having(
          (PdfExtractionException e) => e.message,
          'message',
          contains('Only PDF files'),
        ),
      ),
    );
  });

  test('rejects a .pdf file that is not really a PDF', () async {
    final File file = File('${workspace.path}${Platform.pathSeparator}f.pdf');
    await file.writeAsString('this is a renamed word document');

    await expectLater(
      service.extractText(file.path),
      throwsA(
        isA<PdfExtractionException>().having(
          (PdfExtractionException e) => e.message,
          'message',
          contains('not a valid PDF'),
        ),
      ),
    );
  });

  test('rejects an empty file', () async {
    final File file = File('${workspace.path}${Platform.pathSeparator}e.pdf');
    await file.writeAsBytes(const <int>[]);

    await expectLater(
      service.extractText(file.path),
      throwsA(
        isA<PdfExtractionException>().having(
          (PdfExtractionException e) => e.message,
          'message',
          contains('empty'),
        ),
      ),
    );
  });

  test('reports a missing file', () async {
    await expectLater(
      service.extractText('${workspace.path}/does_not_exist.pdf'),
      throwsA(
        isA<PdfExtractionException>().having(
          (PdfExtractionException e) => e.message,
          'message',
          contains('File not found'),
        ),
      ),
    );
  });
}
