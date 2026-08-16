// One-off: prints what the application's PDF layer actually extracts from a
// file, so a "No answer found" result can be traced to the input.
//
//   flutter test tool/show_extracted.dart
//   EXAM_CORRECTOR_PDF=/path/to/paper.pdf flutter test tool/show_extracted.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/services/pdf_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shows extracted text', () async {
    final String path =
        Platform.environment['EXAM_CORRECTOR_PDF'] ?? 'sample/student_paper.pdf';

    const PdfService service = PdfService();
    final String text = await service.extractText(path);

    stdout.writeln('=== $path');
    stdout.writeln('=== ${text.length} characters');
    stdout.writeln(
      text.length > 1800 ? '${text.substring(0, 1800)}\n…' : text,
    );
  });
}
