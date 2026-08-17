import 'package:file_selector/file_selector.dart';

/// Wraps the native file dialog so the state layer never talks to a plugin
/// directly and can be tested with a stub.
class FilePickerService {
  const FilePickerService();

  static const XTypeGroup _pdfGroup = XTypeGroup(
    label: 'PDF files',
    extensions: <String>['pdf'],
    mimeTypes: <String>['application/pdf'],
    uniformTypeIdentifiers: <String>['com.adobe.pdf'],
  );

  /// A scanned script arrives as often as a photograph of one as a PDF.
  static const XTypeGroup _documentGroup = XTypeGroup(
    label: 'Exam papers (PDF or image)',
    extensions: <String>['pdf', 'png', 'jpg', 'jpeg', 'tif', 'tiff', 'bmp'],
    mimeTypes: <String>[
      'application/pdf',
      'image/png',
      'image/jpeg',
      'image/tiff',
      'image/bmp',
    ],
    uniformTypeIdentifiers: <String>[
      'com.adobe.pdf',
      'public.png',
      'public.jpeg',
      'public.tiff',
      'com.microsoft.bmp',
    ],
  );

  /// Returns the chosen file's path, or null if the teacher cancelled.
  Future<String?> pickPdf() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[_pdfGroup],
      confirmButtonText: 'Select',
    );
    return file?.path;
  }

  /// Like [pickPdf], but also accepts the scans and photographs that
  /// handwriting recognition can read.
  ///
  /// Kept separate because the mark scheme still has to be a PDF: there is no
  /// sense in running OCR over the document that defines the marks.
  Future<String?> pickDocument() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[_documentGroup],
      confirmButtonText: 'Select',
    );
    return file?.path;
  }
}
