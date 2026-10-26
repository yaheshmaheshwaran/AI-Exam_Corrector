import 'dart:io';

import 'package:pdfrx_engine/pdfrx_engine.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/marking/script/pages.dart';
import 'package:exam_corrector/marking/stage_store.dart';

/// Reads what a PDF is before any stage runs: its identity, its pages, and
/// whether its text can be read directly.
///
/// Plain Dart (PDFium through pdfrx), so the pipeline and the tools that run
/// it need no Flutter.
class DocumentReader {
  const DocumentReader();

  /// A page with fewer characters than this in its text layer is taken for
  /// a scan: a photographed page often carries a few stray characters.
  static const int textLayerMinimum = 40;

  Future<SelectedDocument> inspect(String path, DocumentRole role) async {
    final File file = File(path);
    if (path.isEmpty) throw const PdfExtractionException('No file was selected.');
    if (!await file.exists()) throw PdfExtractionException('File not found: $path');
    final List<String> texts = await _pageTexts(path);
    final int withText = texts.where((String text) => text.trim().length >= textLayerMinimum).length;
    return SelectedDocument(
      role: role,
      filePath: path,
      fileName: path.split(Platform.pathSeparator).last,
      contentHash: await StageStore.hashFile(file),
      byteCount: await file.length(),
      pageCount: texts.length,
      source: withText == 0
          ? DocumentSource.scanned
          : withText == texts.length
              ? DocumentSource.textLayer
              : DocumentSource.mixed,
      textLayerPages: withText,
    );
  }

  /// The text layer of every page, joined, when every page has one; null for
  /// a scan, whose text must be read from the images.
  Future<String?> textIfPresent(String path) async {
    final List<String> texts = await _pageTexts(path);
    if (texts.isEmpty || texts.any((String text) => text.trim().length < textLayerMinimum)) return null;
    return texts.join('\n\n');
  }

  Future<List<String>> _pageTexts(String path) async {
    await PageRenderer.ready();
    final PdfDocument document;
    try {
      document = await PdfDocument.openFile(path);
    } on Object catch (error) {
      throw PdfExtractionException('The PDF could not be opened: $error');
    }
    try {
      return <String>[
        for (final PdfPage page in document.pages) (await page.loadText())?.fullText ?? '',
      ];
    } finally {
      await document.dispose();
    }
  }
}
