import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';

/// How firmly a piece of evidence, or a mark resting on it, was established.
///
/// The marking engine has to say which of these each mark rests on, so a
/// teacher can tell a mark earned by what the student visibly wrote from one
/// that depends on reading a smudge charitably.
enum EvidenceBasis {
  /// Plainly visible on the page.
  observed,

  /// Not legible on its own, but established from context — the question,
  /// the surrounding sentence, a diagram label.
  inferred,

  /// Could not be established either way.
  uncertain;

  static EvidenceBasis fromWire(Object? name) =>
      readEnum(values, name, EvidenceBasis.uncertain);
}

/// Who produced a reading of a region.
enum ReadingSource {
  textLayer('text layer'),
  trocr('TrOCR'),
  vision('vision model'),
  teacher('teacher');

  const ReadingSource(this.label);

  final String label;
}

/// A stretch of a reading the recogniser was unsure of.
class UncertainSpan {
  const UncertainSpan({
    required this.text,
    required this.confidence,
    this.start,
    this.end,
    this.box,
  });

  final String text;
  final double confidence;

  /// Character offsets into the reading's text, when known.
  final int? start;
  final int? end;

  /// Where on the page, when the recogniser could say.
  final NormalizedBox? box;

  JsonMap toJson() => <String, Object?>{
        'text': text,
        'confidence': confidence,
        'start': ?start,
        'end': ?end,
        if (box != null) 'box': box!.toJson(),
      };

  static UncertainSpan? fromJson(JsonMap json) {
    final String? text = readRawString(json['text']);
    if (text == null || text.trim().isEmpty) return null;
    return UncertainSpan(
      text: text,
      confidence: readConfidence(json['confidence']),
      start: readInt(json['start']),
      end: readInt(json['end']),
      box: NormalizedBox.fromJson(json['box']),
    );
  }
}

/// One line inside a region, as a recogniser read it.
class RecognizedLine {
  const RecognizedLine({
    required this.text,
    required this.confidence,
    required this.box,
  });

  final String text;
  final double confidence;

  /// In page coordinates, not region coordinates.
  final NormalizedBox box;

  JsonMap toJson() => <String, Object?>{
        'text': text,
        'confidence': confidence,
        'box': box.toJson(),
      };

  static RecognizedLine? fromJson(JsonMap json) {
    final NormalizedBox? box = NormalizedBox.fromJson(json['box']);
    final String? text = readRawString(json['text']);
    if (box == null || text == null) return null;
    return RecognizedLine(
      text: text,
      confidence: readConfidence(json['confidence']),
      box: box,
    );
  }
}

/// One engine's verbatim reading of a region.
///
/// Verbatim is the whole point: nothing downstream edits a reading. Context is
/// applied later, by the marking engine, and recorded separately as an
/// interpretation — so the raw transcription is always there to check it
/// against.
class HandwritingReading {
  const HandwritingReading({
    required this.source,
    required this.text,
    required this.confidence,
    this.engine = '',
    this.uncertainSpans = const <UncertainSpan>[],
    this.lines = const <RecognizedLine>[],
    this.illegible = false,
    this.crossedOut,
  });

  final ReadingSource source;
  final String text;
  final double confidence;

  /// The model that produced it, e.g. `microsoft/trocr-large-handwritten`.
  final String engine;
  final List<UncertainSpan> uncertainSpans;
  final List<RecognizedLine> lines;

  /// The engine looked and could not read it — distinct from reading nothing.
  final bool illegible;

  /// Whether this engine judged the writing struck through. Null when it was
  /// not asked — TrOCR cannot tell — which is different from "no".
  final bool? crossedOut;

  JsonMap toJson() => <String, Object?>{
        'source': source.name,
        'text': text,
        'confidence': confidence,
        'engine': engine,
        'illegible': illegible,
        'crossedOut': ?crossedOut,
        'uncertainSpans': <JsonMap>[
          for (final UncertainSpan span in uncertainSpans) span.toJson(),
        ],
        'lines': <JsonMap>[
          for (final RecognizedLine line in lines) line.toJson(),
        ],
      };

  static HandwritingReading? fromJson(JsonMap json) {
    final String? text = readRawString(json['text']);
    if (text == null) return null;
    return HandwritingReading(
      source: readEnum(ReadingSource.values, json['source'], ReadingSource.trocr),
      text: text,
      confidence: readConfidence(json['confidence']),
      engine: readString(json['engine']) ?? '',
      illegible: readBool(json['illegible']) ?? false,
      crossedOut: readBool(json['crossedOut']),
      uncertainSpans: readObjects(json['uncertainSpans'], UncertainSpan.fromJson),
      lines: readObjects(json['lines'], RecognizedLine.fromJson),
    );
  }
}

/// Everything known about the writing in one region.
///
/// Holds every reading rather than just the best one. Two engines agreeing is
/// strong evidence; two disagreeing is exactly the case a teacher should see,
/// and that disagreement is lost the moment one reading overwrites the other.
class HandwritingEvidence {
  const HandwritingEvidence({
    required this.regionId,
    required this.readings,
    this.primaryIndex = 0,
    this.agreement,
    this.teacherText,
    this.error,
  });

  /// Recognition failed. The region's image is still there, and the marking
  /// engine is shown it instead.
  const HandwritingEvidence.failed(this.regionId, String this.error)
      : readings = const <HandwritingReading>[],
        primaryIndex = 0,
        agreement = null,
        teacherText = null;

  final String regionId;
  final List<HandwritingReading> readings;

  /// Which reading is taken as the transcription.
  final int primaryIndex;

  /// Similarity of the two engines' readings, 0..1, when there were two.
  final double? agreement;

  /// The teacher's own reading, when they corrected it. Takes precedence for
  /// marking but never replaces the machine readings.
  final String? teacherText;

  final String? error;

  bool get hasReading => readings.isNotEmpty;

  bool get failed => error != null && readings.isEmpty;

  HandwritingReading? get primary =>
      readings.isEmpty ? null : readings[primaryIndex.clamp(0, readings.length - 1)];

  /// The machine transcription, unmodified.
  String get rawText => primary?.text ?? '';

  /// The text marking should use: the teacher's reading if there is one.
  String get effectiveText => teacherText ?? rawText;

  /// The primary reading's confidence — raised when a second, independent
  /// engine read the same thing, which is stronger evidence than either
  /// engine's own score. The readings themselves keep their original scores.
  double get confidence {
    if (teacherText != null) return 1;
    final double base = primary?.confidence ?? 0;
    if (agreement != null && agreement! >= 0.95 && base < 0.97) return 0.97;
    return base;
  }

  bool get isIllegible => teacherText == null && (primary?.illegible ?? false);

  List<UncertainSpan> get uncertainSpans =>
      teacherText != null ? const <UncertainSpan>[] : primary?.uncertainSpans ?? const <UncertainSpan>[];

  /// Two engines read this region and meaningfully disagreed.
  bool get enginesDisagree => agreement != null && agreement! < 0.8;

  /// The strongest verdict any engine gave on whether the writing is struck
  /// through: true if one saw a strike, false if one looked and saw none,
  /// null if no engine was asked.
  bool? get crossedOutVerdict {
    bool? verdict;
    for (final HandwritingReading reading in readings) {
      if (reading.crossedOut == true) return true;
      if (reading.crossedOut == false) verdict = false;
    }
    return verdict;
  }

  bool isUncertain(double threshold) =>
      teacherText == null &&
      (confidence < threshold || enginesDisagree || isIllegible || failed);

  HandwritingEvidence withTeacherText(String? text) => HandwritingEvidence(
        regionId: regionId,
        readings: readings,
        primaryIndex: primaryIndex,
        agreement: agreement,
        teacherText: text,
        error: error,
      );

  JsonMap toJson() => <String, Object?>{
        'regionId': regionId,
        'primaryIndex': primaryIndex,
        'agreement': ?agreement,
        'teacherText': ?teacherText,
        'error': ?error,
        'readings': <JsonMap>[
          for (final HandwritingReading reading in readings) reading.toJson(),
        ],
      };

  static HandwritingEvidence? fromJson(JsonMap json) {
    final String? regionId = readString(json['regionId']);
    if (regionId == null) return null;
    return HandwritingEvidence(
      regionId: regionId,
      readings: readObjects(json['readings'], HandwritingReading.fromJson),
      primaryIndex: readInt(json['primaryIndex']) ?? 0,
      agreement: readDouble(json['agreement']),
      teacherText: readRawString(json['teacherText']),
      error: readString(json['error']),
    );
  }
}

/// Whether visual analysis of a region worked.
enum AnalysisStatus { analyzed, failed, skipped }

/// What visual analysis established about a diagram, graph, table or equation.
///
/// Never a replacement for the image. Analysis that fails, or that is only
/// half sure, still leaves the crop for the marking engine to look at itself.
sealed class VisualEvidence {
  const VisualEvidence({
    required this.regionId,
    required this.kind,
    required this.description,
    required this.confidence,
    this.status = AnalysisStatus.analyzed,
    this.error,
    this.relevance = '',
  });

  final String regionId;
  final RegionType kind;
  final String description;
  final double confidence;
  final AnalysisStatus status;
  final String? error;

  /// How the visual relates to the question it was found under, when known.
  final String relevance;

  bool get analyzed => status == AnalysisStatus.analyzed;

  JsonMap toJson() => <String, Object?>{
        'regionId': regionId,
        'kind': kind.wireName,
        'description': description,
        'confidence': confidence,
        'status': status.name,
        'error': ?error,
        'relevance': relevance,
        ..._fields(),
      };

  JsonMap _fields();

  static VisualEvidence? fromJson(JsonMap json) {
    final String? regionId = readString(json['regionId']);
    if (regionId == null) return null;
    final RegionType kind = RegionType.fromWire(json['kind']);
    final String description = readRawString(json['description']) ?? '';
    final double confidence = readConfidence(json['confidence']);
    final AnalysisStatus status =
        readEnum(AnalysisStatus.values, json['status'], AnalysisStatus.analyzed);
    final String? error = readString(json['error']);
    final String relevance = readRawString(json['relevance']) ?? '';

    return switch (kind) {
      RegionType.graph => GraphEvidence(
          regionId: regionId,
          description: description,
          confidence: confidence,
          status: status,
          error: error,
          relevance: relevance,
          xAxis: readRawString(json['xAxis']) ?? '',
          yAxis: readRawString(json['yAxis']) ?? '',
          plottedElements: readStringList(json['plottedElements']),
          approximateValues: readStringList(json['approximateValues']),
          trend: readRawString(json['trend']) ?? '',
          labels: readStringList(json['labels']),
        ),
      RegionType.table => TableEvidence(
          regionId: regionId,
          description: description,
          confidence: confidence,
          status: status,
          error: error,
          relevance: relevance,
          rows: <List<String>>[
            for (final Object? row in readList(json['rows']))
              <String>[
                for (final Object? cell in readList(row))
                  readRawString(cell) ?? '',
              ],
          ],
          crossedOutCells: readStringList(json['crossedOutCells']),
        ),
      RegionType.equation => EquationEvidence(
          regionId: regionId,
          description: description,
          confidence: confidence,
          status: status,
          error: error,
          relevance: relevance,
          latex: readRawString(json['latex']) ?? '',
          plainText: readRawString(json['plainText']) ?? '',
        ),
      _ => DiagramEvidence(
          regionId: regionId,
          description: description,
          confidence: confidence,
          status: status,
          error: error,
          relevance: relevance,
          labels: readStringList(json['labels']),
          components: readStringList(json['components']),
          relationships: readStringList(json['relationships']),
        ),
    };
  }

  /// A placeholder recording that analysis did not happen, and why. The
  /// region keeps its image either way.
  static VisualEvidence unanalysed({
    required String regionId,
    required RegionType kind,
    required AnalysisStatus status,
    String? error,
  }) {
    return switch (kind) {
      RegionType.graph => GraphEvidence(
          regionId: regionId,
          description: '',
          confidence: 0,
          status: status,
          error: error,
        ),
      RegionType.table => TableEvidence(
          regionId: regionId,
          description: '',
          confidence: 0,
          status: status,
          error: error,
        ),
      RegionType.equation => EquationEvidence(
          regionId: regionId,
          description: '',
          confidence: 0,
          status: status,
          error: error,
        ),
      _ => DiagramEvidence(
          regionId: regionId,
          description: '',
          confidence: 0,
          status: status,
          error: error,
        ),
    };
  }
}

class DiagramEvidence extends VisualEvidence {
  const DiagramEvidence({
    required super.regionId,
    required super.description,
    required super.confidence,
    super.status,
    super.error,
    super.relevance,
    this.labels = const <String>[],
    this.components = const <String>[],
    this.relationships = const <String>[],
  }) : super(kind: RegionType.diagram);

  final List<String> labels;
  final List<String> components;
  final List<String> relationships;

  @override
  JsonMap _fields() => <String, Object?>{
        'labels': labels,
        'components': components,
        'relationships': relationships,
      };
}

class GraphEvidence extends VisualEvidence {
  const GraphEvidence({
    required super.regionId,
    required super.description,
    required super.confidence,
    super.status,
    super.error,
    super.relevance,
    this.xAxis = '',
    this.yAxis = '',
    this.plottedElements = const <String>[],
    this.approximateValues = const <String>[],
    this.trend = '',
    this.labels = const <String>[],
  }) : super(kind: RegionType.graph);

  final String xAxis;
  final String yAxis;

  /// Points, lines, curves, bars and legends, as described.
  final List<String> plottedElements;
  final List<String> approximateValues;
  final String trend;
  final List<String> labels;

  @override
  JsonMap _fields() => <String, Object?>{
        'xAxis': xAxis,
        'yAxis': yAxis,
        'plottedElements': plottedElements,
        'approximateValues': approximateValues,
        'trend': trend,
        'labels': labels,
      };
}

class TableEvidence extends VisualEvidence {
  const TableEvidence({
    required super.regionId,
    required super.description,
    required super.confidence,
    super.status,
    super.error,
    super.relevance,
    this.rows = const <List<String>>[],
    this.crossedOutCells = const <String>[],
  }) : super(kind: RegionType.table);

  /// Cell text, row by row; the first row is the header when the table has
  /// one.
  final List<List<String>> rows;
  final List<String> crossedOutCells;

  @override
  JsonMap _fields() => <String, Object?>{
        'rows': rows,
        'crossedOutCells': crossedOutCells,
      };
}

class EquationEvidence extends VisualEvidence {
  const EquationEvidence({
    required super.regionId,
    required super.description,
    required super.confidence,
    super.status,
    super.error,
    super.relevance,
    this.latex = '',
    this.plainText = '',
  }) : super(kind: RegionType.equation);

  /// Machine-readable form, when the working could be transcribed.
  final String latex;

  /// The same working in plain characters, as a fallback for display.
  final String plainText;

  @override
  JsonMap _fields() => <String, Object?>{
        'latex': latex,
        'plainText': plainText,
      };
}

/// Every piece of evidence extracted from a document, keyed by region.
class EvidenceSet {
  const EvidenceSet({
    this.handwriting = const <String, HandwritingEvidence>{},
    this.visuals = const <String, VisualEvidence>{},
  });

  final Map<String, HandwritingEvidence> handwriting;
  final Map<String, VisualEvidence> visuals;

  EvidenceSet copyWith({
    Map<String, HandwritingEvidence>? handwriting,
    Map<String, VisualEvidence>? visuals,
  }) =>
      EvidenceSet(
        handwriting: handwriting ?? this.handwriting,
        visuals: visuals ?? this.visuals,
      );
}
