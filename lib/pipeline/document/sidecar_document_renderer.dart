import 'dart:io';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/services/ocr/sidecar_client.dart';

/// [DocumentRenderer] backed by the sidecar's PyMuPDF renderer.
///
/// Pages are rendered and written one at a time, so a 200-page script never
/// sits in memory at once — on either side of the wire. The app only ever
/// holds paths; images are loaded when a page is actually shown.
class SidecarDocumentRenderer implements DocumentRenderer {
  SidecarDocumentRenderer(this._client, this._configProvider);

  final SidecarClient _client;
  final AppConfig Function() _configProvider;

  AppConfig get _config => _configProvider();

  @override
  String get fingerprint =>
      'sidecar-render:v1:${_config.ocrDpi}:${_config.maxImageDimension}';

  @override
  Future<ExamDocument> render(
    SelectedDocument document, {
    required Directory outputDirectory,
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final Map<String, Object?> done;
    try {
      done = await _client.stream(
        'render',
        <String, Object?>{
          'path': document.filePath,
          'out_dir': outputDirectory.path,
          'dpi': _config.ocrDpi,
          'preview_max_dim': _config.maxImageDimension,
        },
        onProgress: onProgress,
        cancel: cancel,
      );
    } on PipelineException catch (error) {
      throw PipelineException(
        error.page == null
            ? 'The ${document.role.label} could not be rendered: ${error.message}'
            : 'Page ${error.page} of the ${document.role.label} could not be '
                'rendered: ${error.message}',
        stage: 'rendering',
        page: error.page,
      );
    }

    final List<ExamPage> pages = <ExamPage>[
      for (final JsonMap page in readObjects(done['pages'], (JsonMap m) => m))
        _page(document.contentHash, page),
    ];
    if (pages.isEmpty) {
      throw PipelineException(
        'No pages could be rendered from the ${document.role.label}.',
        stage: 'rendering',
      );
    }

    return ExamDocument(
      documentId: document.contentHash,
      role: document.role,
      filePath: document.filePath,
      fileName: document.fileName,
      source: document.source,
      pages: pages,
    );
  }

  ExamPage _page(String documentId, JsonMap json) {
    final int number = (readInt(json['index']) ?? 0) + 1;
    return ExamPage(
      pageId: ExamPage.idFor(documentId, number),
      pageNumber: number,
      width: readInt(json['width']) ?? 0,
      height: readInt(json['height']) ?? 0,
      dpi: readInt(json['dpi']) ?? 0,
      imagePath: readString(json['image_path']),
      originalImagePath: readString(json['original_path']),
      previewImagePath: readString(json['preview_path']),
      hasTextLayer: readBool(json['has_text_layer']) ?? false,
      textLayerText: readRawString(json['text']),
      inkCoverage: readDouble(json['ink_coverage']) ?? 0,
      isBlank: readBool(json['is_blank']) ?? false,
    );
  }
}
