import 'dart:math' as math;

import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/recognition/text_similarity.dart';

/// Assembles each question's answer from everything aligned to it.
///
/// The result is one object per question holding every piece of evidence —
/// text, diagrams, equations, graphs, tables — in reading order, each tied to
/// its region. Crossed-out work is kept, but apart from the answer; and how
/// well the answer could be read is summarised as a confidence and a list of
/// reasons to look closer.
class EvidenceAnswerReconstructor implements AnswerReconstructor {
  const EvidenceAnswerReconstructor({
    required this.uncertainBelow,
    this.crossedOutAbove = 0.6,
  });

  /// Readings below this confidence are flagged.
  final double uncertainBelow;

  /// A strike detected with at least this confidence takes a region out of
  /// the answer. Below it the region stays in the answer and is flagged: a
  /// weak signal must never silently remove what a student wrote.
  final double crossedOutAbove;

  @override
  Map<String, StudentAnswer> reconstruct({
    required ExamDocument document,
    required EvidenceSet evidence,
    required AlignmentResult alignment,
    required QuestionPaper paper,
  }) {
    // Writing matched to no question is where a missed answer most often
    // hides; it is named by page for a question left without one. Writing
    // before the first label can only answer a question that comes before
    // the first one answered — elsewhere it is a heading or a cover sheet.
    List<int> pagesOf(List<String> ids) => <int>{
          for (final String id in ids)
            if (document.region(id) case final PageRegion region
                when region.type.isAnswerContent || document.source == DocumentSource.textLayer)
              region.pageNumber,
        }.toList()
          ..sort();
    final List<int> unmatchedPages = pagesOf(alignment.unassignedRegionIds);
    final List<int> preamblePages = pagesOf(alignment.preambleRegionIds);
    final List<Question> markable = paper.markable;
    final int firstAnswered = markable.indexWhere(
      (Question q) => alignment.alignments.containsKey(q.questionId),
    );
    List<int> strayFor(int index) => <int>{
          ...unmatchedPages,
          if (firstAnswered < 0 || index < firstAnswered) ...preamblePages,
        }.toList()
          ..sort();

    final Map<String, List<PageRegion>> derived = <String, List<PageRegion>>{};
    for (final PageRegion region in document.regions) {
      final String? parent = region.parentRegionId;
      if (parent != null && isDerivedEquation(region)) {
        derived.putIfAbsent(parent, () => <PageRegion>[]).add(region);
      }
    }

    return <String, StudentAnswer>{
      for (int index = 0; index < markable.length; index++)
        markable[index].questionId: _answer(
          markable[index],
          alignment.alignments[markable[index].questionId],
          document,
          evidence,
          alignment,
          strayFor(index),
          derived,
        ),
    };
  }

  StudentAnswer _answer(
    Question question,
    QuestionAlignment? mapping,
    ExamDocument document,
    EvidenceSet evidence,
    AlignmentResult alignment,
    List<int> strayPages,
    Map<String, List<PageRegion>> derived,
  ) {
    if (mapping == null) {
      return StudentAnswer.none(
        question.questionId,
        flags: <String>[
          if (strayPages.isNotEmpty)
            'No answer was found, but writing on '
                'page${strayPages.length == 1 ? '' : 's'} ${strayPages.join(', ')} '
                'was not matched to any question — check whether it answers '
                'this one.',
        ],
      );
    }

    final List<String> regionIds = <String>[];
    for (final String segmentId in mapping.segmentIds) {
      for (final String id in alignment.segment(segmentId)?.regionIds ?? const <String>[]) {
        if (!regionIds.contains(id)) regionIds.add(id);
      }
    }

    final List<TextEvidenceItem> text = <TextEvidenceItem>[];
    final List<TextEvidenceItem> crossed = <TextEvidenceItem>[];
    final List<VisualEvidence> visuals = <VisualEvidence>[];
    final List<String> visualIds = <String>[];
    final Set<int> pages = <int>{};
    int possiblyStruck = 0;
    int failedVisuals = 0;

    for (final String id in regionIds) {
      final PageRegion? region = document.region(id);
      if (region == null) continue;
      pages.add(region.pageNumber);

      if (region.type.isVisual) {
        visualIds.add(id);
        final VisualEvidence? visual = evidence.visuals[id];
        if (visual != null) {
          visuals.add(visual);
          if (!visual.analyzed) failedVisuals++;
        }
      }

      TextEvidenceItem? item = _textItem(region, evidence.handwriting[id]);
      if (item == null || region.type == RegionType.questionNumber) continue;

      // An answer booklet reprints each question above the space for its
      // answer. That printing is context for the marker, not the student's
      // answer, and it is recognisable by being the paper's own wording.
      if (item.type != RegionType.printedText &&
          document.source != DocumentSource.textLayer &&
          isQuestionEcho(item.text, question.questionText)) {
        item = item.retyped(RegionType.printedText);
      }

      final double strike = strikeLikelihood(region, evidence.handwriting[id]);
      if (strike >= crossedOutAbove) {
        crossed.add(item.retyped(RegionType.crossedOut));
        continue;
      }
      if (strike > 0.3) possiblyStruck++;
      text.add(item);
    }

    // Working found inside the answer's own writing: an equation region the
    // pipeline cut out of a paragraph so it could be read as mathematics.
    for (final String id in List<String>.of(regionIds)) {
      for (final PageRegion child in derived[id] ?? const <PageRegion>[]) {
        if (visualIds.contains(child.regionId)) continue;
        visualIds.add(child.regionId);
        final VisualEvidence? visual = evidence.visuals[child.regionId];
        if (visual != null) {
          visuals.add(visual);
          if (!visual.analyzed) failedVisuals++;
        }
      }
    }

    final List<String> flags = <String>[];
    final int uncertain = text
        .where((TextEvidenceItem t) =>
            t.type != RegionType.printedText && t.confidence < uncertainBelow)
        .length;
    final int disagreements = text.where((TextEvidenceItem t) => t.enginesDisagree).length;
    final int illegible = text.where((TextEvidenceItem t) => t.illegible).length;

    if (uncertain > 0) flags.add('$uncertain region(s) were read with low confidence.');
    if (disagreements > 0) {
      flags.add('Two recognisers disagreed on $disagreements region(s).');
    }
    if (illegible > 0) flags.add('$illegible region(s) could not be read.');
    if (possiblyStruck > 0) {
      flags.add(
        '$possiblyStruck line(s) may be crossed out; they were kept in the '
        'answer.',
      );
    }
    if (crossed.isNotEmpty) {
      flags.add('${crossed.length} crossed-out item(s) were left out of the answer.');
    }
    if (failedVisuals > 0) {
      flags.add('$failedVisuals visual(s) could not be analysed; the images are kept.');
    }
    if (mapping.confidence < 0.8) {
      flags.add('Which question this answer belongs to is uncertain.');
    }
    flags.addAll(mapping.notes);

    return StudentAnswer(
      questionId: question.questionId,
      pages: pages.toList()..sort(),
      regionIds: regionIds,
      textEvidence: text,
      visualEvidence: visuals,
      visualRegionIds: visualIds,
      crossedOut: crossed,
      answerConfidence: _confidence(text, visuals, visualIds.length, illegible),
      alignmentConfidence: mapping.confidence,
      flags: flags,
    );
  }

  TextEvidenceItem? _textItem(PageRegion region, HandwritingEvidence? evidence) {
    if (evidence == null || (!evidence.hasReading && evidence.teacherText == null)) {
      final String? detected = region.detectedText;
      if (evidence?.failed ?? false) {
        return TextEvidenceItem(
          regionId: region.regionId,
          pageNumber: region.pageNumber,
          type: region.type,
          text: detected ?? '',
          rawText: detected ?? '',
          confidence: 0,
          source: ReadingSource.trocr,
          illegible: true,
        );
      }
      if (detected == null || detected.trim().isEmpty) return null;
      return TextEvidenceItem(
        regionId: region.regionId,
        pageNumber: region.pageNumber,
        type: region.type,
        text: detected,
        rawText: detected,
        confidence: region.origin == RegionOrigin.textLayer ? 1 : 0.5,
        source: region.origin == RegionOrigin.textLayer
            ? ReadingSource.textLayer
            : ReadingSource.vision,
      );
    }

    String? alternative;
    if (evidence.enginesDisagree) {
      for (int i = 0; i < evidence.readings.length; i++) {
        if (i != evidence.primaryIndex) alternative = evidence.readings[i].text;
      }
    }

    return TextEvidenceItem(
      regionId: region.regionId,
      pageNumber: region.pageNumber,
      type: region.type,
      text: evidence.effectiveText,
      rawText: evidence.rawText,
      confidence: evidence.confidence,
      source: evidence.teacherText != null
          ? ReadingSource.teacher
          : evidence.primary?.source ?? ReadingSource.trocr,
      uncertainSpans: evidence.uncertainSpans,
      enginesDisagree: evidence.teacherText == null && evidence.enginesDisagree,
      alternativeReading: alternative,
      illegible: evidence.isIllegible || evidence.failed,
    );
  }

  /// An equation cut out of a region of writing, rather than one the layout
  /// engine found on its own.
  static bool isDerivedEquation(PageRegion region) =>
      region.type == RegionType.equation &&
      region.origin == RegionOrigin.derived &&
      region.parentRegionId != null;

  /// How likely it is that a region's writing was struck through, 0..1.
  ///
  /// Local analysis suspects strikes from stroke geometry, with modest
  /// confidence. The vision reader looks at the crop and says yes or no, and
  /// its verdict decides: a confirmed strike leaves the answer, a rejected one
  /// stays in without a flag.
  static double strikeLikelihood(PageRegion region, HandwritingEvidence? evidence) {
    double likelihood = region.type == RegionType.crossedOut ? region.confidence : 0;
    switch (evidence?.crossedOutVerdict) {
      case true:
        likelihood = likelihood > 0.85 ? likelihood : 0.85;
      case false:
        likelihood = likelihood < 0.2 ? likelihood : 0.2;
      case null:
        break;
    }
    return likelihood;
  }

  /// True when [text] is essentially the question's own wording — perhaps
  /// behind its number and followed by its mark allocation.
  static bool isQuestionEcho(String text, String questionText) {
    final String printed = normaliseForComparison(questionText);
    if (printed.length < 16) return false;
    final String read = normaliseForComparison(
      text.replaceFirst(RegExp(r'^\s*(?:q(?:uestion)?\s*)?\d{1,3}\s*(?:\(\s*[a-z]+\s*\))*\s*[.):]?\s*', caseSensitive: false), ''),
    );
    if (read.length > printed.length * 1.4 + 30) return false;
    final int length = read.length < printed.length ? read.length : printed.length;
    if (length < 12) return false;
    return textSimilarity(read.substring(0, length), printed.substring(0, length)) >= 0.75;
  }

  /// Character-weighted reading confidence, capped when visual content could
  /// not be analysed or some of the writing could not be read at all.
  double _confidence(
    List<TextEvidenceItem> text,
    List<VisualEvidence> visuals,
    int visualCount,
    int illegible,
  ) {
    double weighted = 0;
    int weight = 0;
    for (final TextEvidenceItem item in text) {
      // Printing is not the student's writing; how well it read says nothing
      // about the answer.
      if (item.type == RegionType.printedText && item.source != ReadingSource.textLayer) {
        continue;
      }
      final int length = item.text.trim().isEmpty ? 1 : item.text.length;
      weighted += item.confidence * length;
      weight += length;
    }
    double confidence = weight == 0 ? 1 : weighted / weight;

    // An uncertain analysis pulls the answer down; a confident one cannot
    // lift a poorly read text.
    for (final VisualEvidence visual in visuals) {
      if (visual.analyzed) {
        confidence = math.min(confidence, (confidence + visual.confidence) / 2);
      }
    }
    if (visualCount > visuals.where((VisualEvidence v) => v.analyzed).length) {
      confidence = math.min(confidence, 0.65);
    }
    if (illegible > 0) confidence = math.min(confidence, 0.4);
    return confidence.clamp(0.0, 1.0);
  }
}
