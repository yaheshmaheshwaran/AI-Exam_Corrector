import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';

/// A run of consecutive regions that belong together as one logical answer —
/// everything from one question label up to the next.
///
/// A segment can cross pages and mix types: `Q4`, two paragraphs, a diagram,
/// another paragraph. It is the unit the boundary detector produces and the
/// aligner assigns to a question.
class AnswerSegment {
  const AnswerSegment({
    required this.segmentId,
    required this.regionIds,
    required this.pageNumbers,
    this.label,
    this.labelKey,
    this.labelRegionId,
    this.continuesPrevious = false,
    this.confidence = 1,
  });

  final String segmentId;

  /// In reading order.
  final List<String> regionIds;
  final List<int> pageNumbers;

  /// The label that opened the segment, exactly as observed. Null for content
  /// before the first label, or a page that continues without one.
  final String? label;

  /// The label's canonical key (`2.a`), for matching against the paper.
  final String? labelKey;
  final String? labelRegionId;

  /// Started a page with no label of its own, and was taken to continue the
  /// answer before it.
  final bool continuesPrevious;

  /// How sure the boundary detector is that this is one answer.
  final double confidence;

  JsonMap toJson() => <String, Object?>{
        'segmentId': segmentId,
        'regionIds': regionIds,
        'pageNumbers': pageNumbers,
        'label': ?label,
        'labelKey': ?labelKey,
        'labelRegionId': ?labelRegionId,
        'continuesPrevious': continuesPrevious,
        'confidence': confidence,
      };

  static AnswerSegment? fromJson(JsonMap json) {
    final String? id = readString(json['segmentId']);
    if (id == null) return null;
    return AnswerSegment(
      segmentId: id,
      regionIds: readStringList(json['regionIds']),
      pageNumbers: <int>[
        for (final Object? page in readList(json['pageNumbers']))
          if (readInt(page) case final int number) number,
      ],
      label: readString(json['label']),
      labelKey: readString(json['labelKey']),
      labelRegionId: readString(json['labelRegionId']),
      continuesPrevious: readBool(json['continuesPrevious']) ?? false,
      confidence: readConfidence(json['confidence'], orElse: 1),
    );
  }
}

/// How a segment came to be assigned to a question.
enum AlignmentMethod {
  /// Its label matched the question exactly.
  label,

  /// It continued a labelled answer onto a new page.
  continuation,

  /// Its label named the parent question, so it was shared with every part.
  parentLabel,

  /// A sub-part label with no number, resolved from the question before it.
  inferredSubPart,

  /// The paper has only one question, so everything answers it.
  soleQuestion,

  /// The teacher chose this writing as the answer.
  teacher,
}

/// The segments that answer one question, and how sure the mapping is.
class QuestionAlignment {
  const QuestionAlignment({
    required this.questionId,
    required this.segmentIds,
    required this.confidence,
    required this.methods,
    this.notes = const <String>[],
  });

  final String questionId;
  final List<String> segmentIds;

  /// The weakest link across its segments, 0..1.
  final double confidence;
  final List<AlignmentMethod> methods;
  final List<String> notes;

  JsonMap toJson() => <String, Object?>{
        'questionId': questionId,
        'segmentIds': segmentIds,
        'confidence': confidence,
        'methods': <String>[for (final AlignmentMethod m in methods) m.name],
        'notes': notes,
      };

  static QuestionAlignment? fromJson(JsonMap json) {
    final String? id = readString(json['questionId']);
    if (id == null) return null;
    return QuestionAlignment(
      questionId: id,
      segmentIds: readStringList(json['segmentIds']),
      confidence: readConfidence(json['confidence']),
      methods: <AlignmentMethod>[
        for (final Object? name in readList(json['methods']))
          readEnum(AlignmentMethod.values, name, AlignmentMethod.label),
      ],
      notes: readStringList(json['notes']),
    );
  }
}

/// A label on the answer sheet that names no question in the paper.
class UnmatchedLabel {
  const UnmatchedLabel({required this.label, required this.segmentId});

  final String label;
  final String segmentId;

  JsonMap toJson() => <String, Object?>{'label': label, 'segmentId': segmentId};

  static UnmatchedLabel? fromJson(JsonMap json) {
    final String? label = readString(json['label']);
    final String? segment = readString(json['segmentId']);
    if (label == null || segment == null) return null;
    return UnmatchedLabel(label: label, segmentId: segment);
  }
}

/// The complete mapping from the answer sheet onto the question paper.
class AlignmentResult {
  const AlignmentResult({
    required this.segments,
    required this.alignments,
    this.unassignedRegionIds = const <String>[],
    this.preambleRegionIds = const <String>[],
    this.unmatchedLabels = const <UnmatchedLabel>[],
    this.warnings = const <String>[],
  });

  final List<AnswerSegment> segments;

  /// Keyed by question ID. A question with no entry has no answer.
  final Map<String, QuestionAlignment> alignments;

  /// Answer content that could not be tied to any question.
  final List<String> unassignedRegionIds;

  /// Everything before the first question label — a cover sheet, the
  /// candidate's details. Kept, but not suspected of being a lost answer.
  final List<String> preambleRegionIds;

  final List<UnmatchedLabel> unmatchedLabels;
  final List<String> warnings;

  /// The same result with [more] warnings ahead of its own.
  AlignmentResult withWarnings(List<String> more) => more.isEmpty
      ? this
      : AlignmentResult(
          segments: segments,
          alignments: alignments,
          unassignedRegionIds: unassignedRegionIds,
          preambleRegionIds: preambleRegionIds,
          unmatchedLabels: unmatchedLabels,
          warnings: <String>[...more, ...warnings],
        );

  AnswerSegment? segment(String segmentId) {
    for (final AnswerSegment segment in segments) {
      if (segment.segmentId == segmentId) return segment;
    }
    return null;
  }

  /// The question each region was assigned to — for the inspector.
  Map<String, List<String>> get questionsByRegion {
    final Map<String, List<String>> byRegion = <String, List<String>>{};
    alignments.forEach((String questionId, QuestionAlignment alignment) {
      for (final String segmentId in alignment.segmentIds) {
        for (final String regionId
            in segment(segmentId)?.regionIds ?? const <String>[]) {
          byRegion.putIfAbsent(regionId, () => <String>[]).add(questionId);
        }
      }
    });
    return byRegion;
  }

  JsonMap toJson() => <String, Object?>{
        'segments': <JsonMap>[
          for (final AnswerSegment segment in segments) segment.toJson(),
        ],
        'alignments': <JsonMap>[
          for (final QuestionAlignment a in alignments.values) a.toJson(),
        ],
        'unassignedRegionIds': unassignedRegionIds,
        'preambleRegionIds': preambleRegionIds,
        'unmatchedLabels': <JsonMap>[
          for (final UnmatchedLabel label in unmatchedLabels) label.toJson(),
        ],
        'warnings': warnings,
      };

  static AlignmentResult fromJson(JsonMap json) {
    return AlignmentResult(
      segments: readObjects(json['segments'], AnswerSegment.fromJson),
      alignments: <String, QuestionAlignment>{
        for (final QuestionAlignment alignment
            in readObjects(json['alignments'], QuestionAlignment.fromJson))
          alignment.questionId: alignment,
      },
      unassignedRegionIds: readStringList(json['unassignedRegionIds']),
      preambleRegionIds: readStringList(json['preambleRegionIds']),
      unmatchedLabels:
          readObjects(json['unmatchedLabels'], UnmatchedLabel.fromJson),
      warnings: readStringList(json['warnings']),
    );
  }
}

/// One region's text, as it stands in a reconstructed answer.
class TextEvidenceItem {
  const TextEvidenceItem({
    required this.regionId,
    required this.pageNumber,
    required this.type,
    required this.text,
    required this.rawText,
    required this.confidence,
    required this.source,
    this.uncertainSpans = const <UncertainSpan>[],
    this.enginesDisagree = false,
    this.alternativeReading,
    this.illegible = false,
  });

  final String regionId;
  final int pageNumber;
  final RegionType type;

  /// What marking reads: the teacher's correction if any, else [rawText].
  final String text;

  /// The machine transcription, never edited.
  final String rawText;
  final double confidence;
  final ReadingSource source;
  final List<UncertainSpan> uncertainSpans;
  final bool enginesDisagree;

  /// The other engine's reading, when two engines disagreed.
  final String? alternativeReading;
  final bool illegible;

  /// The same evidence under another type — printed question text recognised
  /// on an answer booklet, say.
  TextEvidenceItem retyped(RegionType newType) => TextEvidenceItem(
        regionId: regionId,
        pageNumber: pageNumber,
        type: newType,
        text: text,
        rawText: rawText,
        confidence: confidence,
        source: source,
        uncertainSpans: uncertainSpans,
        enginesDisagree: enginesDisagree,
        alternativeReading: alternativeReading,
        illegible: illegible,
      );

  JsonMap toJson() => <String, Object?>{
        'regionId': regionId,
        'pageNumber': pageNumber,
        'type': type.wireName,
        'text': text,
        'rawText': rawText,
        'confidence': confidence,
        'source': source.name,
        'uncertainSpans': <JsonMap>[
          for (final UncertainSpan span in uncertainSpans) span.toJson(),
        ],
        'enginesDisagree': enginesDisagree,
        'alternativeReading': ?alternativeReading,
        'illegible': illegible,
      };

  static TextEvidenceItem? fromJson(JsonMap json) {
    final String? regionId = readString(json['regionId']);
    if (regionId == null) return null;
    return TextEvidenceItem(
      regionId: regionId,
      pageNumber: readInt(json['pageNumber']) ?? 0,
      type: RegionType.fromWire(json['type']),
      text: readRawString(json['text']) ?? '',
      rawText: readRawString(json['rawText']) ?? '',
      confidence: readConfidence(json['confidence']),
      source: readEnum(ReadingSource.values, json['source'], ReadingSource.trocr),
      uncertainSpans: readObjects(json['uncertainSpans'], UncertainSpan.fromJson),
      enginesDisagree: readBool(json['enginesDisagree']) ?? false,
      alternativeReading: readRawString(json['alternativeReading']),
      illegible: readBool(json['illegible']) ?? false,
    );
  }
}

/// A student's complete answer to one question, assembled from every region
/// that belongs to it — across pages, and across text and visuals.
///
/// Every item keeps its region ID, so the answer can always be traced back to
/// the original page.
class StudentAnswer {
  const StudentAnswer({
    required this.questionId,
    required this.pages,
    required this.regionIds,
    this.textEvidence = const <TextEvidenceItem>[],
    this.visualEvidence = const <VisualEvidence>[],
    this.visualRegionIds = const <String>[],
    this.crossedOut = const <TextEvidenceItem>[],
    this.answerConfidence = 0,
    this.alignmentConfidence = 0,
    this.flags = const <String>[],
  });

  /// No content was found for the question.
  const StudentAnswer.none(this.questionId, {this.flags = const <String>[]})
      : pages = const <int>[],
        regionIds = const <String>[],
        textEvidence = const <TextEvidenceItem>[],
        visualEvidence = const <VisualEvidence>[],
        visualRegionIds = const <String>[],
        crossedOut = const <TextEvidenceItem>[],
        answerConfidence = 1,
        alignmentConfidence = 1;

  final String questionId;
  final List<int> pages;

  /// Every region in the answer, in reading order.
  final List<String> regionIds;

  final List<TextEvidenceItem> textEvidence;

  /// Analysis of every visual region, where analysis ran.
  final List<VisualEvidence> visualEvidence;

  /// Every visual region — including those whose analysis failed, because
  /// their images are still evidence.
  final List<String> visualRegionIds;

  /// Kept apart: crossed-out work is not part of the final answer, but the
  /// teacher can still inspect it.
  final List<TextEvidenceItem> crossedOut;

  /// How well the content itself could be read, 0..1.
  final double answerConfidence;

  /// How sure the question mapping is, 0..1.
  final double alignmentConfidence;

  /// Why this answer deserves a closer look, in the teacher's terms.
  final List<String> flags;

  bool get isEmpty => regionIds.isEmpty;

  List<EquationEvidence> get equations =>
      visualEvidence.whereType<EquationEvidence>().toList();
  List<DiagramEvidence> get diagrams =>
      visualEvidence.whereType<DiagramEvidence>().toList();
  List<GraphEvidence> get graphs =>
      visualEvidence.whereType<GraphEvidence>().toList();
  List<TableEvidence> get tables =>
      visualEvidence.whereType<TableEvidence>().toList();

  /// The answer's text in reading order, for display.
  String get text => textEvidence
      .map((TextEvidenceItem item) => item.text.trim())
      .where((String line) => line.isNotEmpty)
      .join('\n');

  JsonMap toJson() => <String, Object?>{
        'questionId': questionId,
        'pages': pages,
        'regionIds': regionIds,
        'textEvidence': <JsonMap>[
          for (final TextEvidenceItem item in textEvidence) item.toJson(),
        ],
        'visualEvidence': <JsonMap>[
          for (final VisualEvidence visual in visualEvidence) visual.toJson(),
        ],
        'visualRegionIds': visualRegionIds,
        'crossedOut': <JsonMap>[
          for (final TextEvidenceItem item in crossedOut) item.toJson(),
        ],
        'answerConfidence': answerConfidence,
        'alignmentConfidence': alignmentConfidence,
        'flags': flags,
      };

  static StudentAnswer? fromJson(JsonMap json) {
    final String? id = readString(json['questionId']);
    if (id == null) return null;
    return StudentAnswer(
      questionId: id,
      pages: <int>[
        for (final Object? page in readList(json['pages']))
          if (readInt(page) case final int number) number,
      ],
      regionIds: readStringList(json['regionIds']),
      textEvidence: readObjects(json['textEvidence'], TextEvidenceItem.fromJson),
      visualEvidence:
          readObjects(json['visualEvidence'], VisualEvidence.fromJson),
      visualRegionIds: readStringList(json['visualRegionIds']),
      crossedOut: readObjects(json['crossedOut'], TextEvidenceItem.fromJson),
      answerConfidence: readConfidence(json['answerConfidence']),
      alignmentConfidence: readConfidence(json['alignmentConfidence']),
      flags: readStringList(json['flags']),
    );
  }
}
