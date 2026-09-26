import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/services/ocr/sidecar_client.dart';

/// One page's local layout, with the detector's own verdict on whether it
/// needs a better look.
class LocalPageLayout {
  const LocalPageLayout({
    required this.regions,
    required this.needsVision,
    this.reasons = const <String>[],
    this.error,
  });

  final List<PageRegion> regions;

  /// The page has graphics, or ink the local analysis could not explain.
  final bool needsVision;
  final List<String> reasons;
  final String? error;
}

/// [RegionDetector] running the sidecar's classical computer-vision layout
/// analysis: DBNet text, paragraph grouping, graphic and strike detection.
class LocalRegionDetector implements RegionDetector {
  LocalRegionDetector(this._client);

  final SidecarClient _client;

  @override
  String get fingerprint => 'local-layout:v2';

  @override
  Future<RegionDetection> detect(
    ExamDocument document,
    List<ExamPage> pages, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final Map<int, LocalPageLayout> layouts =
        await analyze(pages, onProgress: onProgress, cancel: cancel);
    final List<String> warnings = <String>[];

    final List<ExamPage> detected = <ExamPage>[
      for (final ExamPage page in pages)
        page.copyWith(
          regions: layouts[page.pageNumber]?.regions ?? const <PageRegion>[],
          detector: fingerprint,
        ),
    ];
    for (final MapEntry<int, LocalPageLayout> entry in layouts.entries) {
      if (entry.value.error != null) {
        warnings.add(
          'Page ${entry.key}: layout analysis failed (${entry.value.error}). '
          'Its image is kept for the teacher.',
        );
      }
    }
    return RegionDetection(pages: detected, warnings: warnings);
  }

  /// Runs layout on [pages] and returns each page's result, keyed by page
  /// number. Used directly by the hybrid detector, which needs the verdicts.
  Future<Map<int, LocalPageLayout>> analyze(
    List<ExamPage> pages, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final List<ExamPage> withImages =
        pages.where((ExamPage page) => page.hasImage).toList();
    if (withImages.isEmpty) return const <int, LocalPageLayout>{};

    final Map<String, Object?> done = await _client.stream(
      'layout',
      <String, Object?>{
        'pages': <Map<String, Object?>>[
          for (final ExamPage page in withImages)
            <String, Object?>{
              'index': page.pageNumber - 1,
              'image_path': page.imagePath,
            },
        ],
      },
      onProgress: onProgress,
      cancel: cancel,
    );

    final Map<int, ExamPage> byNumber = <int, ExamPage>{
      for (final ExamPage page in withImages) page.pageNumber: page,
    };
    final Map<int, LocalPageLayout> layouts = <int, LocalPageLayout>{};

    for (final JsonMap result in readObjects(done['pages'], (JsonMap m) => m)) {
      final int number = (readInt(result['index']) ?? -1) + 1;
      final ExamPage? page = byNumber[number];
      if (page == null) continue;

      final String? error = readString(result['error']);
      if (error != null) {
        layouts[number] = LocalPageLayout(
          regions: const <PageRegion>[],
          needsVision: true,
          reasons: <String>['layout failed'],
          error: error,
        );
        continue;
      }
      layouts[number] = LocalPageLayout(
        regions: regionsFrom(page, result),
        needsVision: readBool(result['needs_vision']) ?? false,
        reasons: readStringList(result['reasons']),
      );
    }
    return layouts;
  }

  /// Converts the sidecar's pixel regions into normalised page regions.
  static List<PageRegion> regionsFrom(ExamPage page, JsonMap result) {
    final int width = readInt(result['width']) ?? page.width;
    final int height = readInt(result['height']) ?? page.height;
    final List<JsonMap> raw = readObjects(result['regions'], (JsonMap m) => m);

    NormalizedBox? box(Object? value) {
      final List<Object?> numbers = readList(value);
      if (numbers.length != 4) return null;
      final List<int?> v = numbers.map(readInt).toList();
      if (v.contains(null)) return null;
      return NormalizedBox.fromPixels(
        x: v[0]!,
        y: v[1]!,
        width: v[2]!,
        height: v[3]!,
        pageWidth: width,
        pageHeight: height,
      );
    }

    String idAt(int index) => '${page.pageId}:r$index';

    return <PageRegion>[
      for (int index = 0; index < raw.length; index++)
        if (box(raw[index]['box']) case final NormalizedBox regionBox)
          PageRegion(
            regionId: idAt(index),
            pageId: page.pageId,
            pageNumber: page.pageNumber,
            type: RegionType.fromWire(raw[index]['type']),
            box: regionBox,
            confidence: readConfidence(raw[index]['confidence']),
            readingOrder: readInt(raw[index]['reading_order']) ?? index,
            origin: RegionOrigin.local,
            parentRegionId: switch (readInt(raw[index]['parent'])) {
              final int parent when parent >= 0 && parent < raw.length =>
                idAt(parent),
              _ => null,
            },
            lineBoxes: <NormalizedBox>[
              for (final Object? line in readList(raw[index]['lines']))
                if (box(line) case final NormalizedBox lineBox) lineBox,
            ],
            lineWords: <List<NormalizedBox>>[
              for (final Object? words in readList(raw[index]['line_words']))
                <NormalizedBox>[
                  for (final Object? word in readList(words))
                    if (box(word) case final NormalizedBox wordBox) wordBox,
                ],
            ],
          ),
    ];
  }
}
