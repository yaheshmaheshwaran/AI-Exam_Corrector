import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/pipeline/cache/artifact_store.dart';
import 'package:exam_corrector/pipeline/marking/teacher_key.dart';
import 'package:exam_corrector/services/pdf_service.dart';
import 'package:exam_corrector/services/syllabus/syllabus_reader.dart';

/// Reads a teacher's typed answer key into text: a PDF with a text layer, a
/// Word document, or a text or Markdown file.
///
/// Typed keys only, for now. A scanned or photographed key is refused with a
/// message that says what to choose instead, rather than read badly.
class DocumentTextReader {
  const DocumentTextReader({PdfService pdf = const PdfService()}) : _pdf = pdf;

  final PdfService _pdf;

  static const List<String> extensions = <String>['pdf', 'docx', 'txt', 'md'];

  Future<TeacherKeySource> readAnswerKey(String path) async {
    final File file = File(path);
    final String name = file.uri.pathSegments.last;
    final String extension = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final String text = switch (extension) {
      'pdf' => await _fromPdf(path),
      'docx' => await _fromDocx(file),
      'txt' || 'md' => await _fromText(file),
      'doc' => throw const AnswerKeyException(
          'This is an older Word file (.doc). Open it in Word, save it as .docx, and choose it again.'),
      _ => throw AnswerKeyException(
          'An answer key can be a PDF with text, a Word document (.docx) or a text file — not ".$extension".'),
    };
    final String cleaned = text
        .split('\n')
        .where((String line) => !RegExp(r'^---\s*Page\s+\d+\s*---$').hasMatch(line.trim()))
        .join('\n')
        .trim();
    if (cleaned.isEmpty) throw const AnswerKeyException('No text could be read from this answer key.');
    return TeacherKeySource(fileName: name, hash: await ArtifactStore.hashFile(file), text: cleaned);
  }

  Future<String> _fromPdf(String path) async {
    final String? text;
    try {
      text = await _pdf.extractTextIfPresent(path);
    } on PdfExtractionException catch (error) {
      throw AnswerKeyException(error.message);
    }
    if (text == null || text.trim().isEmpty) {
      throw const AnswerKeyException(
        'This answer key is a scan. For now, choose a typed key: a PDF with text, a Word file or a '
        'text file.',
      );
    }
    return text;
  }

  static Future<String> _fromDocx(File file) async {
    try {
      final Archive archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      final ArchiveFile? document = archive.findFile('word/document.xml');
      if (document == null) throw const AnswerKeyException('This Word file has no document text.');
      return SyllabusReader.textOfDocumentXml(
        XmlDocument.parse(utf8.decode(document.content, allowMalformed: true)),
      );
    } on AnswerKeyException {
      rethrow;
    } on FileSystemException catch (error) {
      throw AnswerKeyException('The answer key could not be read: ${error.message}.');
    } on XmlException {
      throw const AnswerKeyException('This Word file looks damaged.');
    } on Exception {
      // Not a zip at all, or a broken one.
      throw const AnswerKeyException('This does not look like a Word (.docx) file — it may be damaged.');
    }
  }

  static Future<String> _fromText(File file) async {
    try {
      return await file.readAsString();
    } on FileSystemException catch (error) {
      throw AnswerKeyException('The answer key could not be read: ${error.message}.');
    } on FormatException {
      return utf8.decode(await file.readAsBytes(), allowMalformed: true);
    }
  }
}
