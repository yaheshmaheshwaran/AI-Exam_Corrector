import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';

/// Which of the two documents a correction needs this is.
enum DocumentRole {
  answerSheet('answer sheet'),
  questionPaper('question paper');

  const DocumentRole(this.label);

  /// How the document is named to the teacher, mid-sentence.
  final String label;
}

/// How a document's content can be read.
enum DocumentSource {
  /// Every page carries a usable text layer.
  textLayer,

  /// No page carries text: a scan or a photographed script.
  scanned,

  /// Some pages have text and some do not — a typed cover sheet stapled to a
  /// handwritten script, most often.
  mixed,

  /// A photograph or image file rather than a PDF.
  image,
}

/// A file the teacher chose, validated and fingerprinted but not yet
/// processed.
///
/// Choosing a file is cheap; understanding it is not. Keeping the two apart
/// lets an unreadable file be refused the moment it is chosen, while the
/// expensive pipeline runs once, when the teacher asks for marking.
class SelectedDocument {
  const SelectedDocument({
    required this.role,
    required this.filePath,
    required this.fileName,
    required this.contentHash,
    required this.byteCount,
    required this.pageCount,
    required this.source,
    this.textLayerPages = 0,
  });

  final DocumentRole role;
  final String filePath;
  final String fileName;

  /// A hash of the file's bytes. The document's identity for caching: an
  /// unchanged file is never processed twice.
  final String contentHash;

  final int byteCount;
  final int pageCount;
  final DocumentSource source;

  /// Pages with a usable text layer.
  final int textLayerPages;

  bool get needsRendering => source != DocumentSource.textLayer;
}

/// One page of a document, rendered and understood.
///
/// The page image is the primary source of truth. Every region is measured
/// against [imagePath], and [originalImagePath] keeps the untouched render so
/// nothing the student wrote is lost to clean-up.
class ExamPage {
  const ExamPage({
    required this.pageId,
    required this.pageNumber,
    required this.width,
    required this.height,
    this.dpi = 0,
    this.imagePath,
    this.originalImagePath,
    this.previewImagePath,
    this.hasTextLayer = false,
    this.textLayerText,
    this.inkCoverage = 0,
    this.isBlank = false,
    this.regions = const <PageRegion>[],
    this.detector = '',
  });

  /// `<documentId>:p<number>` — stable for an unchanged file.
  final String pageId;
  final int pageNumber;

  /// In pixels of [imagePath], or PDF points when the page was not rendered.
  final int width;
  final int height;
  final int dpi;

  /// The image every region box is measured against: deskewed and
  /// contrast-normalised for a scan, a straight render for a text-layer page.
  final String? imagePath;

  /// The render before any clean-up.
  final String? originalImagePath;

  /// A downscaled copy, sized for the vision model.
  final String? previewImagePath;

  final bool hasTextLayer;
  final String? textLayerText;

  /// Fraction of the page covered by ink, from the cheap first-stage analysis.
  final double inkCoverage;

  /// Nothing written here. Blank pages are skipped by every later stage.
  final bool isBlank;

  final List<PageRegion> regions;

  /// Which region detector produced [regions].
  final String detector;

  bool get hasImage => imagePath != null && imagePath!.isNotEmpty;

  static String idFor(String documentId, int pageNumber) =>
      '$documentId:p$pageNumber';

  ExamPage copyWith({
    List<PageRegion>? regions,
    String? detector,
    bool? isBlank,
  }) {
    return ExamPage(
      pageId: pageId,
      pageNumber: pageNumber,
      width: width,
      height: height,
      dpi: dpi,
      imagePath: imagePath,
      originalImagePath: originalImagePath,
      previewImagePath: previewImagePath,
      hasTextLayer: hasTextLayer,
      textLayerText: textLayerText,
      inkCoverage: inkCoverage,
      isBlank: isBlank ?? this.isBlank,
      regions: regions ?? this.regions,
      detector: detector ?? this.detector,
    );
  }

  JsonMap toJson() => <String, Object?>{
        'pageId': pageId,
        'pageNumber': pageNumber,
        'width': width,
        'height': height,
        'dpi': dpi,
        'imagePath': ?imagePath,
        'originalImagePath': ?originalImagePath,
        'previewImagePath': ?previewImagePath,
        'hasTextLayer': hasTextLayer,
        'textLayerText': ?textLayerText,
        'inkCoverage': inkCoverage,
        'isBlank': isBlank,
        'detector': detector,
        'regions': <JsonMap>[
          for (final PageRegion region in regions) region.toJson(),
        ],
      };

  static ExamPage? fromJson(JsonMap json) {
    final String? pageId = readString(json['pageId']);
    final int? pageNumber = readInt(json['pageNumber']);
    if (pageId == null || pageNumber == null) return null;

    return ExamPage(
      pageId: pageId,
      pageNumber: pageNumber,
      width: readInt(json['width']) ?? 0,
      height: readInt(json['height']) ?? 0,
      dpi: readInt(json['dpi']) ?? 0,
      imagePath: readString(json['imagePath']),
      originalImagePath: readString(json['originalImagePath']),
      previewImagePath: readString(json['previewImagePath']),
      hasTextLayer: readBool(json['hasTextLayer']) ?? false,
      textLayerText: readRawString(json['textLayerText']),
      inkCoverage: readDouble(json['inkCoverage']) ?? 0,
      isBlank: readBool(json['isBlank']) ?? false,
      detector: readString(json['detector']) ?? '',
      regions: readObjects(json['regions'], PageRegion.fromJson),
    );
  }
}

/// A document after page understanding: its pages and their regions.
class ExamDocument {
  const ExamDocument({
    required this.documentId,
    required this.role,
    required this.filePath,
    required this.fileName,
    required this.source,
    required this.pages,
  });

  /// The content hash of the file — see [SelectedDocument.contentHash].
  final String documentId;
  final DocumentRole role;
  final String filePath;
  final String fileName;
  final DocumentSource source;
  final List<ExamPage> pages;

  int get pageCount => pages.length;

  Iterable<PageRegion> get regions =>
      pages.expand((ExamPage page) => page.regions);

  /// Regions in document reading order: page by page, then within each page.
  List<PageRegion> get regionsInReadingOrder => <PageRegion>[
        for (final ExamPage page in pages)
          ...(List<PageRegion>.of(page.regions)
            ..sort((PageRegion a, PageRegion b) =>
                a.readingOrder.compareTo(b.readingOrder))),
      ];

  PageRegion? region(String regionId) {
    for (final PageRegion region in regions) {
      if (region.regionId == regionId) return region;
    }
    return null;
  }

  ExamPage? page(String pageId) {
    for (final ExamPage page in pages) {
      if (page.pageId == pageId) return page;
    }
    return null;
  }

  ExamPage? pageNumbered(int pageNumber) {
    for (final ExamPage page in pages) {
      if (page.pageNumber == pageNumber) return page;
    }
    return null;
  }

  int countOf(RegionType type) =>
      regions.where((PageRegion region) => region.type == type).length;

  ExamDocument withPages(List<ExamPage> updated) => ExamDocument(
        documentId: documentId,
        role: role,
        filePath: filePath,
        fileName: fileName,
        source: source,
        pages: updated,
      );

  /// Returns a copy with [replacements] swapped in by region ID and [added]
  /// appended to their pages. Used when alignment splits a block at a label.
  ExamDocument withRegions({
    Map<String, PageRegion> replacements = const <String, PageRegion>{},
    List<PageRegion> added = const <PageRegion>[],
    Set<String> removed = const <String>{},
  }) {
    if (replacements.isEmpty && added.isEmpty && removed.isEmpty) return this;
    return withPages(<ExamPage>[
      for (final ExamPage page in pages)
        page.copyWith(regions: <PageRegion>[
          for (final PageRegion region in page.regions)
            if (!removed.contains(region.regionId))
              replacements[region.regionId] ?? region,
          for (final PageRegion region in added)
            if (region.pageId == page.pageId) region,
        ]),
    ]);
  }

  JsonMap toJson() => <String, Object?>{
        'documentId': documentId,
        'role': role.name,
        'filePath': filePath,
        'fileName': fileName,
        'source': source.name,
        'pages': <JsonMap>[for (final ExamPage page in pages) page.toJson()],
      };

  static ExamDocument? fromJson(JsonMap json) {
    final String? documentId = readString(json['documentId']);
    if (documentId == null) return null;
    return ExamDocument(
      documentId: documentId,
      role: readEnum(DocumentRole.values, json['role'], DocumentRole.answerSheet),
      filePath: readString(json['filePath']) ?? '',
      fileName: readString(json['fileName']) ?? '',
      source: readEnum(
        DocumentSource.values,
        json['source'],
        DocumentSource.scanned,
      ),
      pages: readObjects(json['pages'], ExamPage.fromJson),
    );
  }
}
