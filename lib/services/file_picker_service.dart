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

  /// Returns the chosen file's path, or null if the teacher cancelled.
  Future<String?> pickPdf() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[_pdfGroup],
      confirmButtonText: 'Select',
    );
    return file?.path;
  }
}
