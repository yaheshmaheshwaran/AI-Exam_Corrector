import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/exam_paper.dart';
import 'package:exam_corrector/services/pdf_service.dart';

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

    final ExamPaper paper = await service.loadExamPaper(file.path);

    expect(paper.fileName, 'paper.pdf');
    expect(paper.text, contains('--- Page 1 ---'));
    expect(paper.text, contains('mitochondrion'));
    expect(paper.characterCount, greaterThan(answer.length ~/ 2));
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
