import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:pdfrx_engine/pdfrx_engine.dart';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';

/// Stage 1: a PDF's pages as images, rendered with PDFium inside the Dart
/// process.
///
/// Each page becomes one JPEG. The page image is what the reader sees, what
/// region boxes are measured against, and what the teacher inspects.
class PageRenderer {
  PageRenderer({this.dpi = 200, this.jpegQuality = 88});

  /// 200 dpi keeps a handwritten line sharp for the reader and a crop
  /// readable for the teacher, at about 0.5 MB a page.
  final int dpi;
  final int jpegQuality;

  /// How PDFium is made ready. Plain Dart (the tools) loads the native
  /// library itself; the Flutter app replaces this with its own initialiser.
  static Future<void> Function() initialize = pdfrxInitialize;

  static Future<void>? _ready;

  /// Loads PDFium once, however many documents are opened.
  static Future<void> ready() => _ready ??= initialize();

  String get fingerprint => 'pdfium-render:v1:$dpi:$jpegQuality';

  /// Renders every page of [pdfPath] into [folder], reusing a page image
  /// already there.
  Future<List<ExamPage>> render(
    String pdfPath, {
    required String documentId,
    required Directory folder,
    void Function(int done, int total)? onPage,
    CancellationToken? cancel,
  }) async {
    await ready();
    await folder.create(recursive: true);
    final PdfDocument document;
    try {
      document = await PdfDocument.openFile(pdfPath);
    } on Object catch (error) {
      throw PipelineException('The PDF could not be opened: $error', stage: 'rendering');
    }
    try {
      final List<ExamPage> pages = <ExamPage>[];
      for (final PdfPage page in document.pages) {
        cancel?.throwIfCancelled();
        final int number = page.pageNumber;
        final File file = File('${folder.path}${Platform.pathSeparator}page_${number.toString().padLeft(3, '0')}.jpg');
        final int width = (page.width * dpi / 72).round();
        final int height = (page.height * dpi / 72).round();
        if (!await file.exists()) {
          final PdfImage? image = await page.render(
            fullWidth: width.toDouble(),
            fullHeight: height.toDouble(),
            backgroundColor: 0xffffffff,
          );
          if (image == null) throw PipelineException('Page $number could not be rendered.', stage: 'rendering', page: number);
          try {
            await file.writeAsBytes(img.encodeJpg(image.createImageNF(), quality: jpegQuality));
          } finally {
            image.dispose();
          }
        }
        pages.add(ExamPage(
          pageId: ExamPage.idFor(documentId, number),
          pageNumber: number,
          width: width,
          height: height,
          dpi: dpi,
          imagePath: file.path,
          originalImagePath: file.path,
          previewImagePath: file.path,
        ));
        onPage?.call(pages.length, document.pages.length);
      }
      return pages;
    } finally {
      await document.dispose();
    }
  }
}

/// Cuts regions out of one page image, decoding the page once for all of
/// them.
class PageCropper {
  PageCropper(this.imagePath);

  final String imagePath;
  img.Image? _page;

  /// Saves [box] (with a little [margin] around it, so a stroke at the edge
  /// is not cut) to [outPath] and returns the path, or null when the page
  /// image cannot be read or the box is empty.
  Future<String?> crop(NormalizedBox box, String outPath, {double margin = 0.01}) async {
    final img.Image? page = _page ??= await _decode();
    if (page == null) return null;
    final int left = (math.max(0, box.x - margin) * page.width).floor();
    final int top = (math.max(0, box.y - margin) * page.height).floor();
    final int right = (math.min(1, box.x + box.width + margin) * page.width).ceil();
    final int bottom = (math.min(1, box.y + box.height + margin) * page.height).ceil();
    if (right - left < 4 || bottom - top < 4) return null;
    final img.Image cut = img.copyCrop(page, x: left, y: top, width: right - left, height: bottom - top);
    final File file = File(outPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(img.encodeJpg(cut, quality: 88));
    return file.path;
  }

  Future<img.Image?> _decode() async {
    try {
      return img.decodeImage(await File(imagePath).readAsBytes());
    } on FileSystemException {
      return null;
    }
  }
}
