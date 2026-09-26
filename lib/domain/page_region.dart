import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/json_read.dart';

/// What a region of a page contains.
///
/// The page understanding engine never assumes everything on a page is text.
/// The type decides which evidence engine reads the region: handwriting goes
/// to recognition, a diagram is kept as an image and analysed visually, a
/// crossed-out line is read but kept out of the final answer.
enum RegionType {
  printedText('printed_text', 'Printed text'),
  questionNumber('question_number', 'Question number'),
  handwrittenAnswer('handwritten_answer', 'Handwritten answer'),
  diagram('diagram', 'Diagram'),
  graph('graph', 'Graph'),
  table('table', 'Table'),
  equation('equation', 'Equation'),
  label('label', 'Label'),
  crossedOut('crossed_out', 'Crossed out'),
  marginNote('margin_note', 'Margin note'),
  header('header', 'Header'),
  footer('footer', 'Footer'),
  unknown('unknown', 'Unknown');

  const RegionType(this.wireName, this.displayName);

  /// The name used on the wire — by the sidecar and in model prompts.
  final String wireName;

  final String displayName;

  static RegionType fromWire(Object? name) {
    if (name is String) {
      final String normalised = name.trim().toLowerCase();
      for (final RegionType type in values) {
        if (type.wireName == normalised || type.name == name) return type;
      }
    }
    return unknown;
  }

  /// Read by handwriting recognition.
  bool get isTextual => switch (this) {
        printedText ||
        questionNumber ||
        handwrittenAnswer ||
        label ||
        crossedOut ||
        marginNote ||
        header ||
        footer =>
          true,
        _ => false,
      };

  /// Kept as an image and analysed visually rather than transcribed.
  bool get isVisual => switch (this) {
        diagram || graph || table || equation => true,
        _ => false,
      };

  /// Content the student wrote as part of an answer. Headers, footers and the
  /// printed question text are context, not answer.
  bool get isAnswerContent => switch (this) {
        handwrittenAnswer ||
        diagram ||
        graph ||
        table ||
        equation ||
        label ||
        crossedOut ||
        marginNote =>
          true,
        _ => false,
      };
}

/// Which engine found a region. Recorded because the engines differ in how far
/// their boxes and types can be trusted, and the inspector shows it.
enum RegionOrigin {
  /// Read from the PDF's own text layer — exact.
  textLayer,

  /// Local computer-vision layout analysis in the sidecar.
  local,

  /// The vision model's page analysis.
  vision,

  /// Derived from another region — a label line split off a block, an
  /// equation line promoted out of a paragraph.
  derived,
}

/// One semantic region of one page.
///
/// A region is the unit evidence is attached to, and the unit marks cite. It
/// keeps its page, its box and its crop for the whole life of a correction, so
/// any mark can be followed back to the pixels it was awarded for.
class PageRegion {
  const PageRegion({
    required this.regionId,
    required this.pageId,
    required this.pageNumber,
    required this.type,
    required this.box,
    required this.confidence,
    required this.readingOrder,
    this.origin = RegionOrigin.local,
    this.parentRegionId,
    this.cropPath,
    this.detectedLabel,
    this.detectedText,
    this.lineBoxes = const <NormalizedBox>[],
    this.lineWords = const <List<NormalizedBox>>[],
  });

  /// Stable across runs: derived from the page ID and the detection order, so
  /// a cached marking result still points at the right region.
  final String regionId;
  final String pageId;
  final int pageNumber;
  final RegionType type;
  final NormalizedBox box;

  /// How sure the detector is of the type and the extent, 0..1.
  final double confidence;

  /// Position in the page's reading order, from 0.
  final int readingOrder;

  final RegionOrigin origin;
  final String? parentRegionId;

  /// The region cut out of the page image, when one has been made.
  final String? cropPath;

  /// A question label the detector saw at the start of this region — `4`,
  /// `2(b)`, `Q7` — exactly as written. Resolved against the question paper
  /// later; this is only what was observed.
  final String? detectedLabel;

  /// Text the detector itself read: the text layer, or the vision model's
  /// transcription during page analysis. Not a substitute for handwriting
  /// evidence — it is one more reading.
  final String? detectedText;

  /// Text-line boxes inside the region, when the detector found them. Used to
  /// split a block at a question label that starts partway down it.
  final List<NormalizedBox> lineBoxes;

  /// Word boxes within each line, parallel to [lineBoxes], when the detector
  /// found words. Lets an uncertain word be highlighted on its own ink.
  final List<List<NormalizedBox>> lineWords;

  PageRegion copyWith({
    String? regionId,
    RegionType? type,
    NormalizedBox? box,
    double? confidence,
    int? readingOrder,
    RegionOrigin? origin,
    String? Function()? parentRegionId,
    String? Function()? cropPath,
    String? Function()? detectedLabel,
    String? Function()? detectedText,
    List<NormalizedBox>? lineBoxes,
    List<List<NormalizedBox>>? lineWords,
  }) {
    return PageRegion(
      regionId: regionId ?? this.regionId,
      pageId: pageId,
      pageNumber: pageNumber,
      type: type ?? this.type,
      box: box ?? this.box,
      confidence: confidence ?? this.confidence,
      readingOrder: readingOrder ?? this.readingOrder,
      origin: origin ?? this.origin,
      parentRegionId:
          parentRegionId == null ? this.parentRegionId : parentRegionId(),
      cropPath: cropPath == null ? this.cropPath : cropPath(),
      detectedLabel:
          detectedLabel == null ? this.detectedLabel : detectedLabel(),
      detectedText: detectedText == null ? this.detectedText : detectedText(),
      lineBoxes: lineBoxes ?? this.lineBoxes,
      lineWords: lineWords ?? this.lineWords,
    );
  }

  JsonMap toJson() => <String, Object?>{
        'regionId': regionId,
        'pageId': pageId,
        'pageNumber': pageNumber,
        'type': type.wireName,
        'box': box.toJson(),
        'confidence': confidence,
        'readingOrder': readingOrder,
        'origin': origin.name,
        'parentRegionId': ?parentRegionId,
        'cropPath': ?cropPath,
        'detectedLabel': ?detectedLabel,
        'detectedText': ?detectedText,
        if (lineBoxes.isNotEmpty)
          'lineBoxes': <List<double>>[
            for (final NormalizedBox line in lineBoxes) line.toJson(),
          ],
        if (lineWords.any((List<NormalizedBox> words) => words.isNotEmpty))
          'lineWords': <List<List<double>>>[
            for (final List<NormalizedBox> words in lineWords)
              <List<double>>[for (final NormalizedBox w in words) w.toJson()],
          ],
      };

  static PageRegion? fromJson(JsonMap json) {
    final String? regionId = readString(json['regionId']);
    final String? pageId = readString(json['pageId']);
    final NormalizedBox? box = NormalizedBox.fromJson(json['box']);
    if (regionId == null || pageId == null || box == null) return null;

    return PageRegion(
      regionId: regionId,
      pageId: pageId,
      pageNumber: readInt(json['pageNumber']) ?? 0,
      type: RegionType.fromWire(json['type']),
      box: box,
      confidence: readConfidence(json['confidence']),
      readingOrder: readInt(json['readingOrder']) ?? 0,
      origin: readEnum(RegionOrigin.values, json['origin'], RegionOrigin.local),
      parentRegionId: readString(json['parentRegionId']),
      cropPath: readString(json['cropPath']),
      detectedLabel: readString(json['detectedLabel']),
      detectedText: readRawString(json['detectedText']),
      lineBoxes: <NormalizedBox>[
        for (final Object? line in readList(json['lineBoxes']))
          if (NormalizedBox.fromJson(line) case final NormalizedBox box) box,
      ],
      lineWords: <List<NormalizedBox>>[
        for (final Object? words in readList(json['lineWords']))
          <NormalizedBox>[
            for (final Object? word in readList(words))
              if (NormalizedBox.fromJson(word) case final NormalizedBox box) box,
          ],
      ],
    );
  }
}
