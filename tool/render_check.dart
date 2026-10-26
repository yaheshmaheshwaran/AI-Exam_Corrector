// Renders every page of a PDF to JPEG with PDFium (pdfrx), inside the Dart
// process — no Python service — and prints the time per page.
//
//   dart run tool/render_check.dart [script.pdf]
//
// Pages are written to build/render-check/. It runs as plain Dart: under
// `flutter test` PDFium's native library is not loaded and the run hangs.
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:pdfrx_engine/pdfrx_engine.dart';

Future<void> main(List<String> args) async {
  final String path = args.isNotEmpty ? args.first : 'user_inputs/ans/DocScanner 02-Sep-2026 11-22 AM copy.pdf';
  final Stopwatch total = Stopwatch()..start();
  stdout.writeln('initialising PDFium…');
  await pdfrxInitialize();
  stdout.writeln('PDFium ready in ${total.elapsedMilliseconds} ms');
  final PdfDocument document = await PdfDocument.openFile(path);
  stdout.writeln('${document.pages.length} pages');
  final Directory out = Directory('build/render-check')..createSync(recursive: true);
  for (final PdfPage page in document.pages) {
    final Stopwatch watch = Stopwatch()..start();
    final PdfImage? image = await page.render(fullWidth: page.width * 200 / 72, fullHeight: page.height * 200 / 72, backgroundColor: 0xffffffff);
    final img.Image picture = image!.createImageNF();
    final List<int> jpeg = img.encodeJpg(picture, quality: 88);
    image.dispose();
    await File('${out.path}/page_${page.pageNumber.toString().padLeft(3, '0')}.jpg').writeAsBytes(jpeg);
    stdout.writeln('  page ${page.pageNumber}: ${picture.width}x${picture.height}, ${(jpeg.length / 1024).round()} KB, ${watch.elapsedMilliseconds} ms');
  }
  await document.dispose();
  stdout.writeln('done in ${total.elapsedMilliseconds} ms');
}
