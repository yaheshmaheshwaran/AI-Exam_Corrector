import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:exam_corrector/core/constants/app_constants.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/exam_paper.dart';

/// PDF validation and text extraction.
///
/// Deliberately isolated from the UI and from the AI layer: this service turns
/// a path on disk into plain text, or throws [PdfExtractionException] with a
/// message that is safe to show a teacher.
class PdfService {
  const PdfService();

  /// Loads a student's exam paper, validating and extracting in one step.
  Future<ExamPaper> loadExamPaper(String path) async {
    final String text = await extractText(path);
    return ExamPaper(
      filePath: path,
      fileName: _baseName(path),
      text: text,
    );
  }

  /// Returns the text content of [path], page by page.
  ///
  /// Throws [PdfExtractionException] for anything the teacher needs to act on:
  /// missing file, wrong format, corrupt file, encrypted file, or a scan with
  /// no text layer.
  Future<String> extractText(String path) async {
    final String? text = await extractTextIfPresent(path);

    if (text == null) {
      throw const PdfExtractionException(
        'No readable text was found in this PDF. It is most likely a scan or '
        'photograph. Please supply a PDF with a text layer.',
      );
    }

    return text;
  }

  /// Returns the text layer, or null when this PDF has none.
  ///
  /// The distinction matters to [DocumentIngestService]: a PDF with no text
  /// layer is a scan, which is a job for handwriting recognition rather than an
  /// error. Every *other* problem — missing, corrupt, encrypted, oversized —
  /// still throws, because none of those are helped by OCR.
  Future<String?> extractTextIfPresent(String path) async {
    final Uint8List bytes = await _readValidatedFile(path);

    // Parsing a long paper is CPU-bound; keep the window responsive.
    final String combined = await compute(_extractPagesText, bytes);

    if (_withoutPageMarkers(combined).length < AppConstants.minUsefulPdfChars) {
      return null;
    }

    return combined;
  }

  Future<Uint8List> _readValidatedFile(String path) async {
    if (path.isEmpty) {
      throw const PdfExtractionException('No file was selected.');
    }
    if (!path.toLowerCase().endsWith('.pdf')) {
      throw const PdfExtractionException('Only PDF files are supported.');
    }

    final File file = File(path);
    if (!await file.exists()) {
      throw PdfExtractionException('File not found: $path');
    }

    final int size = await file.length();
    if (size == 0) {
      throw const PdfExtractionException('This file is empty.');
    }
    if (size > AppConstants.maxPdfBytes) {
      final String actual = (size / 1048576).toStringAsFixed(1);
      final int limit = AppConstants.maxPdfBytes ~/ 1048576;
      throw PdfExtractionException(
        'This PDF is $actual MB, which exceeds the $limit MB limit.',
      );
    }

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on IOException catch (error) {
      throw PdfExtractionException('This file could not be read: $error');
    }

    if (bytes.length < 5 ||
        String.fromCharCodes(bytes.sublist(0, 5)) != '%PDF-') {
      throw const PdfExtractionException('This file is not a valid PDF.');
    }

    return bytes;
  }

  String _baseName(String path) {
    final int separator = path.lastIndexOf(RegExp(r'[/\\]'));
    return separator == -1 ? path : path.substring(separator + 1);
  }
}

/// Runs on a background isolate: bytes in, page-marked text out.
String _extractPagesText(Uint8List bytes) {
  PdfDocument? document;
  try {
    try {
      document = PdfDocument(inputBytes: bytes);
    } on ArgumentError catch (error) {
      // Syncfusion reports a password-protected document this way.
      final String detail = '${error.message ?? error}';
      if (detail.toLowerCase().contains('password') ||
          detail.toLowerCase().contains('encrypt')) {
        throw const PdfExtractionException(
          'This PDF is password protected. Please supply an unlocked copy.',
        );
      }
      throw PdfExtractionException('This file is not a readable PDF: $detail');
    }

    final int pageCount = document.pages.count;
    if (pageCount == 0) {
      throw const PdfExtractionException('This PDF has no pages.');
    }

    final PdfTextExtractor extractor = PdfTextExtractor(document);
    final List<String> pages = <String>[];

    for (int index = 0; index < pageCount; index++) {
      String text;
      try {
        text = extractor.extractText(
          startPageIndex: index,
          endPageIndex: index,
        );
      } on Exception {
        // A single unreadable page should not fail the whole paper.
        text = '';
      }
      pages.add('--- Page ${index + 1} ---\n${text.trim()}');
    }

    return pages.join('\n\n').trim();
  } on PdfExtractionException {
    rethrow;
  } on Exception catch (error) {
    throw PdfExtractionException('This PDF could not be read: $error');
  } finally {
    document?.dispose();
  }
}

String _withoutPageMarkers(String text) => text
    .split('\n')
    .where((String line) => !line.startsWith('--- Page '))
    .join('\n')
    .trim();
