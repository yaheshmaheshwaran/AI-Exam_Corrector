import 'dart:io';

import 'package:exam_corrector/core/constants/app_constants.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/pipeline/cache/artifact_store.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/services/pdf_service.dart';

/// Validates a chosen file and fingerprints it, without processing it.
///
/// Runs the moment a file is chosen: a corrupt, encrypted or oversized file is
/// refused there and then, and the content hash that identifies the document
/// for caching is computed once.
class LocalDocumentInspector implements DocumentInspector {
  const LocalDocumentInspector({PdfService pdfService = const PdfService()})
      : _pdf = pdfService;

  final PdfService _pdf;

  static const Set<String> imageExtensions = <String>{
    '.png',
    '.jpg',
    '.jpeg',
    '.tif',
    '.tiff',
    '.bmp',
    '.webp',
  };

  static bool isImage(String path) {
    final String lower = path.toLowerCase();
    return imageExtensions.any(lower.endsWith);
  }

  @override
  Future<SelectedDocument> inspect(String path, DocumentRole role) async {
    final File file = File(path);
    if (path.isEmpty) {
      throw const PdfExtractionException('No file was selected.');
    }
    if (!await file.exists()) {
      throw PdfExtractionException('File not found: $path');
    }
    final int size = await file.length();
    if (size == 0) throw const PdfExtractionException('This file is empty.');
    if (size > AppConstants.maxPdfBytes) {
      final String actual = (size / 1048576).toStringAsFixed(1);
      throw PdfExtractionException(
        'This file is $actual MB, which exceeds the '
        '${AppConstants.maxPdfBytes ~/ 1048576} MB limit.',
      );
    }

    final String hash = await ArtifactStore.hashFile(file);
    final String name = _baseName(path);

    if (isImage(path)) {
      return SelectedDocument(
        role: role,
        filePath: path,
        fileName: name,
        contentHash: hash,
        byteCount: size,
        pageCount: 1,
        source: DocumentSource.image,
      );
    }

    final PdfInspection inspection = await _pdf.inspect(path);
    final DocumentSource source = inspection.textLayerPages == 0
        ? DocumentSource.scanned
        : inspection.textLayerPages == inspection.pageCount
            ? DocumentSource.textLayer
            : DocumentSource.mixed;

    return SelectedDocument(
      role: role,
      filePath: path,
      fileName: name,
      contentHash: hash,
      byteCount: size,
      pageCount: inspection.pageCount,
      source: source,
      textLayerPages: inspection.textLayerPages,
    );
  }

  static String _baseName(String path) {
    final int separator = path.lastIndexOf(RegExp(r'[/\\]'));
    return separator == -1 ? path : path.substring(separator + 1);
  }
}
