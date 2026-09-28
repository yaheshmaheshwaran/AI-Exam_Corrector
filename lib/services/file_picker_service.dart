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

  /// Several scripts at once — a class set. Empty if the teacher cancelled.
  Future<List<String>> pickDocuments() async {
    final List<XFile> files = await openFiles(
      acceptedTypeGroups: const <XTypeGroup>[_documentGroup],
      confirmButtonText: 'Select',
    );
    return <String>[for (final XFile file in files) file.path];
  }

  /// A course syllabus as the college published it: a PDF with text, a
  /// PowerPoint deck, a Word document, or a text file.
  Future<String?> pickSyllabus() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'Syllabus', extensions: <String>['pdf', 'pptx', 'docx', 'txt', 'md']),
      ],
    );
    return file?.path;
  }

  /// The teacher's own answer key, typed: a PDF with text, a Word document,
  /// or a text file.
  Future<String?> pickAnswerKey() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'Answer key',
          extensions: <String>['pdf', 'docx', 'txt', 'md'],
          uniformTypeIdentifiers: <String>[
            'com.adobe.pdf',
            'org.openxmlformats.wordprocessingml.document',
            'public.plain-text',
          ],
        ),
      ],
      confirmButtonText: 'Select',
    );
    return file?.path;
  }

  /// Marking guidance saved as a file: text, Markdown or a PDF.
  Future<String?> pickGuidance() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'Marking guidance',
          extensions: <String>['txt', 'md', 'pdf'],
          mimeTypes: <String>['text/plain', 'text/markdown', 'application/pdf'],
          uniformTypeIdentifiers: <String>['public.plain-text', 'com.adobe.pdf'],
        ),
      ],
      confirmButtonText: 'Load',
    );
    return file?.path;
  }

  /// Where to save an exported report, or null if the teacher cancelled.
  Future<String?> pickSaveLocation({
    required String suggestedName,
    required String extension,
  }) async {
    final FileSaveLocation? location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: <XTypeGroup>[
        XTypeGroup(label: extension.toUpperCase(), extensions: <String>[extension]),
      ],
      confirmButtonText: 'Save',
    );
    return location?.path;
  }

  /// Like [pickPdf], but also accepts scans and photographs. Both documents
  /// are chosen with this: either can arrive as a scan.
  Future<String?> pickDocument() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[_documentGroup],
      confirmButtonText: 'Select',
    );
    return file?.path;
  }
}
