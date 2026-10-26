import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/marking/script/matching/label_sequence_filter.dart';
import 'package:exam_corrector/marking/script/matching/question_label_detector.dart';
import 'package:exam_corrector/marking/contracts.dart';

/// Splits the answer sheet into logical answers, from label to label.
///
/// Walks every region in reading order across the whole document. A region
/// that opens with a question label — or a question-number region beside it —
/// starts a new answer; everything after it belongs to that answer until the
/// next label, across diagrams, equations and page breaks alike.
///
/// Two things real scripts do that a simple walk would get wrong:
/// - A student writes the next question straight under the last answer, so a
///   single text block holds the end of one answer and the start of the next.
///   Such a block is split at the line where the new label appears.
/// - A page starts mid-answer, with no label. It opens a continuation segment
///   that the aligner joins to the answer before it — with slightly lower
///   confidence, because the page break is where answers most often get
///   confused.
///
/// And one thing students do that a label detector alone gets wrong: they
/// number the points of an answer `1, 2, 3`. Every numbered label is first
/// checked against the sequence of the whole script by the
/// [LabelSequenceFilter], and only the ones it accepts start answers.
class LabelBoundaryDetector implements AnswerBoundaryDetector {
  const LabelBoundaryDetector({
    QuestionLabelDetector labels = const QuestionLabelDetector(),
    LabelSequenceFilter sequence = const LabelSequenceFilter(),
  })  : _labels = labels,
        _sequence = sequence;

  final QuestionLabelDetector _labels;
  final LabelSequenceFilter _sequence;

  /// A line starting this far right of the page's writing, as a fraction of
  /// the page width, is indented.
  static const double indentThreshold = 0.04;

  static const double continuationConfidence = 0.85;

  @override
  BoundaryResult detect(
    ExamDocument document,
    EvidenceSet evidence,
    QuestionPaper paper,
  ) {
    final List<LabelCandidate> found = candidates(document, evidence, paper);
    final LabelSelection selection = _sequence.select(found, paper);
    _recover(document, evidence, paper, found, selection);
    final ({ExamDocument document, EvidenceSet evidence}) split =
        _splitAtLabels(document, evidence, paper, selection);
    final Map<String, PageRegion> regions = <String, PageRegion>{
      for (final ExamPage page in split.document.pages)
        for (final PageRegion region in page.regions) region.regionId: region,
    };
    final ({List<AnswerSegment> segments, List<String> warnings}) placed = placeMisnumbered(
      _segments(split.document, split.evidence, paper, selection),
      paper,
      (AnswerSegment segment) => <String>[
        for (final String id in segment.regionIds)
          if (regions[id] case final PageRegion region) ...linesOf(region, split.evidence),
      ].join(' '),
    );
    return BoundaryResult(
      document: split.document,
      evidence: split.evidence,
      segments: placed.segments,
      warnings: <String>[...selection.warnings, ...placed.warnings],
    );
  }

  // ------------------------------------------------------------------------
  // An answer numbered as a question already answered
  // ------------------------------------------------------------------------

  /// Words that say nothing about which question an answer answers.
  static const Set<String> _instructionWords = <String>{
    'justify', 'mention', 'identify', 'explain', 'describe', 'discuss', 'write', 'give', 'using', 'used',
    'with', 'which', 'this', 'that', 'their', 'from', 'into', 'about', 'what', 'when', 'where', 'does',
    'have', 'will', 'these', 'those', 'also', 'each', 'then', 'than', 'them', 'they', 'your', 'suitable',
    'develop', 'prepare', 'illustrate', 'outline', 'interpret', 'draw', 'list', 'state', 'define', 'neat',
  };

  /// The words of [text] that can tell questions apart: four letters or
  /// more, hyphens closed up (`green-house` is `greenhouse`), a plural `s`
  /// dropped.
  static Set<String> terms(String text) => <String>{
        for (final String word in text.toLowerCase().replaceAll('-', '').split(RegExp('[^a-z0-9]+')))
          if (word.length >= 4 && RegExp('[a-z]').hasMatch(word) && !_instructionWords.contains(word))
            word.length > 4 && word.endsWith('s') ? word.substring(0, word.length - 1) : word,
      };

  /// An answer the student numbered as a question answered earlier, when its
  /// words clearly answer a question nothing else does, is placed under that
  /// question — and the teacher told. On a real script, "17. Temperature
  /// sensor…" was written for question 19 after 17 and 18: question 19
  /// showed no answer, and 17 held two.
  ///
  /// Clearly: at least two telling words shared with the unanswered
  /// question, and at least twice as many (plus one) as with the question
  /// the student wrote. Two, not more: handwriting is misread ("gun-house"
  /// for "green-house"), and the other conditions — a label written twice, a
  /// question with no answer, the same section — already make a chance
  /// match unlikely. Words most questions of the paper use ("Arduino",
  /// "system") tell nothing and are not counted. Only questions of the same
  /// section are considered, and the placement lowers the answer's
  /// confidence, so it goes to the teacher.
  static ({List<AnswerSegment> segments, List<String> warnings}) placeMisnumbered(
    List<AnswerSegment> segments,
    QuestionPaper paper,
    String Function(AnswerSegment segment) textOf,
  ) {
    Question? questionOf(AnswerSegment segment) {
      final String? key = segment.labelKey;
      if (key == null) return null;
      final Question? question = paper.byLabel(QuestionLabel.fromKey(key));
      return question != null && question.isLeaf ? question : null;
    }

    final List<Question> markable = paper.markable;
    final Map<String, Set<String>> questionTerms = <String, Set<String>>{
      for (final Question q in markable) q.questionId: terms(q.questionText),
    };
    final Map<String, int> usage = <String, int>{};
    for (final Set<String> set in questionTerms.values) {
      for (final String term in set) {
        usage[term] = (usage[term] ?? 0) + 1;
      }
    }
    // A word one question uses always tells; one most questions use never does.
    bool telling(String term) => (usage[term] ?? 0) <= 1 || (usage[term] ?? 0) < 0.3 * markable.length;
    int shared(Set<String> answer, Question question) =>
        questionTerms[question.questionId]!.where((String t) => telling(t) && answer.contains(t)).length;

    final Set<String> answered = <String>{
      for (final AnswerSegment segment in segments) ?questionOf(segment)?.questionId,
    };
    final Set<String> seen = <String>{};
    final List<AnswerSegment> out = List<AnswerSegment>.of(segments);
    final List<String> warnings = <String>[];

    for (int i = 0; i < out.length; i++) {
      final AnswerSegment segment = out[i];
      final Question? written = questionOf(segment);
      if (written == null || segment.continuesPrevious) continue;
      if (seen.add(written.questionId)) continue;
      final String opening = textOf(segment);
      // "2 contd." continues the earlier answer: it is never moved.
      if (RegExp(r'\bcont', caseSensitive: false).hasMatch(opening.substring(0, opening.length.clamp(0, 40)))) {
        continue;
      }

      final StringBuffer text = StringBuffer(opening);
      for (int j = i + 1; j < out.length && out[j].continuesPrevious && out[j].labelKey == null; j++) {
        text.write(' ${textOf(out[j])}');
      }
      final Set<String> answer = terms(text.toString());
      final int own = shared(answer, written);
      Question? best;
      int bestShared = 0;
      for (final Question candidate in markable) {
        if (answered.contains(candidate.questionId) ||
            candidate.sectionId != written.sectionId ||
            (candidate.maximumMarks ?? 0) <= 0) {
          continue;
        }
        final int score = shared(answer, candidate);
        if (score > bestShared) {
          bestShared = score;
          best = candidate;
        }
      }
      if (best == null || bestShared < 2 || bestShared < 2 * own + 1) continue;

      answered.add(best.questionId);
      out[i] = AnswerSegment(
        segmentId: segment.segmentId,
        regionIds: segment.regionIds,
        pageNumbers: segment.pageNumbers,
        label: segment.label,
        labelKey: best.label.key,
        labelRegionId: segment.labelRegionId,
        confidence: segment.confidence * 0.8,
      );
      warnings.add('An answer labelled "${segment.label ?? written.label.display}" was placed under question '
          '${best.label.display}: question ${written.label.display} is answered earlier, and this '
          "answer's words match question ${best.label.display}, which had no answer. Please check.");
    }
    return (segments: out, warnings: warnings);
  }

  // ------------------------------------------------------------------------
  // Candidates for the sequence filter
  // ------------------------------------------------------------------------

  /// Every place, in reading order, where a numbered label could start an
  /// answer: region openings, and lines partway down a block.
  List<LabelCandidate> candidates(
    ExamDocument document,
    EvidenceSet evidence,
    QuestionPaper paper,
  ) {
    final List<LabelCandidate> found = <LabelCandidate>[];
    for (final ExamPage page in document.pages) {
      if (page.isBlank) continue;
      final List<PageRegion> regions =
          _ordered(page.regions).where(_readsAsAnswer).toList();
      final double? margin = _leftMargin(regions);

      LabelCandidate candidate(PageRegion region, int line, DetectedLabel label, double? x, String text) =>
          LabelCandidate(
            regionId: region.regionId,
            line: line,
            label: label,
            opensRegion: line == 0,
            x: x,
            indented: x != null && margin != null && x - margin > indentThreshold,
            followedByWords: wordsAfter(text, label),
          );

      for (final PageRegion region in regions) {
        final HandwritingEvidence? reading = evidence.handwriting[region.regionId];
        final DetectedLabel? opening = labelOf(region, evidence, paper, null);
        if (opening != null && opening.numbered) {
          final List<String> first = linesOf(region, evidence);
          found.add(candidate(region, 0, opening, _lineX(region, reading, 0), first.isEmpty ? '' : first.first));
        }
        if (!_splittable(region, reading)) continue;
        final List<String> lines = _primaryLines(reading!);
        for (int index = 1; index < lines.length; index++) {
          final DetectedLabel? label = _labels.detect(lines[index], paper: paper);
          if (label == null || !label.numbered) continue;
          found.add(candidate(region, index, label, _lineX(region, reading, index), lines[index]));
        }
      }
    }
    return found;
  }

  /// Whether words follow [label] on [line]: `17. Temperature sensor` does,
  /// a stray `9` or `1 | r` does not.
  static bool wordsAfter(String line, DetectedLabel label) {
    String rest = line.trimLeft();
    final String observed = label.observed.trim();
    final int at = observed.isEmpty ? -1 : rest.indexOf(observed);
    if (at >= 0) rest = rest.substring(at + observed.length);
    return RegExp('[A-Za-z]{3,}').hasMatch(rest);
  }

  // ------------------------------------------------------------------------
  // Recovering a question the sheet seems not to answer
  // ------------------------------------------------------------------------

  /// Every place a label could start, in reading order, with its text.
  List<({String key, String text, int page})> _positions(
    ExamDocument document,
    EvidenceSet evidence,
  ) {
    final List<({String key, String text, int page})> positions =
        <({String key, String text, int page})>[];
    for (final ExamPage page in document.pages) {
      if (page.isBlank) continue;
      for (final PageRegion region in _ordered(page.regions).where(_readsAsAnswer)) {
        final HandwritingEvidence? reading = evidence.handwriting[region.regionId];
        final List<String> lines = linesOf(region, evidence);
        final String? reported = region.detectedLabel;
        final String opening = reported != null && reported.isNotEmpty
            ? reported
            : lines.isEmpty
                ? ''
                : region.type == RegionType.questionNumber
                    ? lines.join(' ')
                    : lines.first;
        positions.add((
          key: LabelSelection.keyOf(region.regionId, 0),
          text: opening,
          page: region.pageNumber,
        ));
        if (!_splittable(region, reading)) continue;
        final List<String> primary = _primaryLines(reading!);
        for (int index = 1; index < primary.length; index++) {
          positions.add((
            key: LabelSelection.keyOf(region.regionId, index),
            text: primary[index],
            page: region.pageNumber,
          ));
        }
      }
    }
    return positions;
  }

  /// Gives a question with no label on the sheet a second, closer look —
  /// but only where its answer must sit: after the label of the answered
  /// question before it in the paper, and before the label of the one after.
  ///
  /// First a label the sequence filter set aside is taken back, unless it
  /// was part of a student's list; then each line in that window is read
  /// again allowing for a misread number (`S.` for `5.`, `Q. No. l`).
  void _recover(
    ExamDocument document,
    EvidenceSet evidence,
    QuestionPaper paper,
    List<LabelCandidate> found,
    LabelSelection selection,
  ) {
    final List<String> majors = <String>[];
    for (final Question question in paper.markable) {
      if (!majors.contains(question.label.major)) majors.add(question.label.major);
    }
    final List<({String key, String text, int page})> positions =
        _positions(document, evidence);
    final Map<String, int> at = <String, int>{
      for (int i = 0; i < positions.length; i++) positions[i].key: i,
    };

    // Where each question's accepted labels sit on the sheet.
    final Map<String, List<int>> answered = <String, List<int>>{};
    for (final LabelCandidate candidate in found) {
      final int? index = at[candidate.key];
      if (index == null || !candidate.label.inPaper) continue;
      if (!selection.isAccepted(candidate.key)) continue;
      answered.putIfAbsent(candidate.label.label.major, () => <int>[]).add(index);
    }

    for (int m = 0; m < majors.length; m++) {
      final String major = majors[m];
      if (answered.containsKey(major)) continue;

      int start = -1;
      for (int j = m - 1; j >= 0; j--) {
        final List<int>? before = answered[majors[j]];
        if (before != null) {
          start = before.reduce((int a, int b) => a > b ? a : b);
          break;
        }
      }
      int end = positions.length;
      for (int j = m + 1; j < majors.length; j++) {
        final List<int>? after = answered[majors[j]];
        if (after != null) {
          end = after.reduce((int a, int b) => a < b ? a : b);
          break;
        }
      }
      if (start + 1 >= end) continue;
      bool within(int index) => index > start && index < end;

      // A label set aside that names this question after all.
      final LabelCandidate? setAside = found
          .where((LabelCandidate c) =>
              c.label.label.major == major &&
              !selection.isAccepted(c.key) &&
              !selection.inList(c.key) &&
              within(at[c.key] ?? -1))
          .firstOrNull;
      if (setAside != null) {
        final int index = at[setAside.key]!;
        selection.restore(
          setAside.key,
          'Question $major had no other answer, so "${setAside.label.observed}" '
          'on page ${positions[index].page} was taken as its label after all.',
        );
        answered[major] = <int>[index];
        continue;
      }

      // A label the ordinary reading missed.
      for (int index = start + 1; index < end; index++) {
        final ({String key, String text, int page}) position = positions[index];
        if (selection.isAccepted(position.key)) continue;
        final DetectedLabel? label =
            _labels.detectRelaxed(position.text, paper: paper, major: major);
        if (label == null) continue;
        final String opening = position.text.length > 40
            ? '${position.text.substring(0, 40)}…'
            : position.text;
        selection.force(
          position.key,
          label,
          'Question $major had no label the app could read; the writing '
          'starting "$opening" on page ${position.page} was taken as its answer.',
        );
        answered[major] = <int>[index];
        break;
      }
    }
  }

  static bool _readsAsAnswer(PageRegion region) {
    if (region.type == RegionType.header || region.type == RegionType.footer) {
      return false;
    }
    if (region.origin == RegionOrigin.derived &&
        region.type == RegionType.equation &&
        region.parentRegionId != null) {
      return false;
    }
    return !(region.parentRegionId != null && region.type == RegionType.label);
  }

  /// Where the page's writing starts: its leftmost answer region.
  static double? _leftMargin(List<PageRegion> regions) {
    double? left;
    for (final PageRegion region in regions) {
      if (region.type == RegionType.marginNote) continue;
      if (left == null || region.box.x < left) left = region.box.x;
    }
    return left;
  }

  /// Where line [index] of [region] starts across the page, if known.
  static double? _lineX(PageRegion region, HandwritingEvidence? reading, int index) {
    if (index == 0) {
      return region.lineBoxes.isNotEmpty ? region.lineBoxes.first.x : region.box.x;
    }
    final int count = reading == null ? 0 : _primaryLines(reading).length;
    if (region.lineBoxes.length == count && index < count) {
      return region.lineBoxes[index].x;
    }
    final List<RecognizedLine> lines = reading?.primary?.lines ?? const <RecognizedLine>[];
    if (lines.length == count && index < count) return lines[index].box.x;
    return null;
  }

  /// Whether a block may be split at a label partway down it.
  static bool _splittable(PageRegion region, HandwritingEvidence? reading) =>
      reading != null &&
      reading.teacherText == null &&
      region.type.isTextual &&
      region.type != RegionType.questionNumber;

  /// [label], unless it is a number the sequence filter set aside.
  static DetectedLabel? _admitted(
    DetectedLabel? label,
    LabelSelection selection,
    String regionId,
    int line,
  ) =>
      label == null || !label.numbered || selection.admits(regionId, line)
          ? label
          : null;

  // ------------------------------------------------------------------------
  // Segments
  // ------------------------------------------------------------------------

  List<AnswerSegment> _segments(
    ExamDocument document,
    EvidenceSet evidence,
    QuestionPaper paper,
    LabelSelection selection,
  ) {
    final List<AnswerSegment> segments = <AnswerSegment>[];
    _Open? open;
    QuestionLabel? current;

    void close() {
      final _Open? building = open;
      if (building != null && building.regionIds.isNotEmpty) {
        segments.add(building.build('seg${segments.length}'));
      }
      open = null;
    }

    for (final ExamPage page in document.pages) {
      if (page.isBlank) continue;
      bool pageStarted = false;

      for (final PageRegion region in _ordered(page.regions)) {
        if (region.type == RegionType.header || region.type == RegionType.footer) {
          continue;
        }
        // Equations cut out of a paragraph belong wherever the paragraph does.
        if (region.origin == RegionOrigin.derived &&
            region.type == RegionType.equation &&
            region.parentRegionId != null) {
          continue;
        }

        final DetectedLabel? label = region.parentRegionId != null &&
                region.type == RegionType.label
            ? null
            : selection.forcedAt(region.regionId, 0) ??
                _admitted(
                  labelOf(region, evidence, paper, current),
                  selection,
                  region.regionId,
                  0,
                );

        if (label != null) {
          close();
          current = label.label;
          open = _Open(
            label: label.observed,
            labelKey: label.label.key,
            labelRegionId: region.regionId,
            confidence: label.confidence *
                _readingFactor(evidence.handwriting[region.regionId]),
          );
        } else if (!pageStarted && open != null && open!.regionIds.isNotEmpty) {
          // A new page that does not open with a label.
          close();
          open = _Open(continuesPrevious: true, confidence: continuationConfidence);
        }
        open ??= _Open(confidence: 1);
        open!.add(region);
        pageStarted = true;
      }
    }
    close();
    return segments;
  }

  /// The label a region opens with, if any.
  DetectedLabel? labelOf(
    PageRegion region,
    EvidenceSet evidence,
    QuestionPaper paper,
    QuestionLabel? current,
  ) {
    final bool standalone = region.type == RegionType.questionNumber;
    final List<String> lines = linesOf(region, evidence);

    // The vision model reports the label it saw; the transcription is checked
    // too, because the model may have left the label field empty.
    final String? reported = region.detectedLabel;
    if (reported != null && reported.isNotEmpty) {
      final DetectedLabel? label = _labels.detect(
        reported,
        paper: paper,
        current: current,
        standalone: true,
      );
      if (label != null) return label;
    }
    if (lines.isEmpty) return null;
    if (!region.type.isTextual && region.type != RegionType.unknown) return null;
    return _labels.detect(
      standalone ? lines.join(' ') : lines.first,
      paper: paper,
      current: current,
      standalone: standalone,
    );
  }

  /// A region's text as lines, from its best reading.
  static List<String> linesOf(PageRegion region, EvidenceSet evidence) {
    final HandwritingEvidence? handwriting = evidence.handwriting[region.regionId];
    final String text = handwriting?.effectiveText ??
        region.detectedText ??
        '';
    return text
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList();
  }

  /// A label read with low confidence is itself uncertain.
  static double _readingFactor(HandwritingEvidence? evidence) {
    if (evidence == null) return 1;
    return 0.5 + 0.5 * evidence.confidence;
  }

  static List<PageRegion> _ordered(List<PageRegion> regions) =>
      List<PageRegion>.of(regions)
        ..sort((PageRegion a, PageRegion b) => a.readingOrder.compareTo(b.readingOrder));

  // ------------------------------------------------------------------------
  // Splitting a block at a label partway down it
  // ------------------------------------------------------------------------

  ({ExamDocument document, EvidenceSet evidence}) _splitAtLabels(
    ExamDocument document,
    EvidenceSet evidence,
    QuestionPaper paper,
    LabelSelection selection,
  ) {
    final Map<String, HandwritingEvidence> handwriting =
        Map<String, HandwritingEvidence>.of(evidence.handwriting);
    final List<ExamPage> pages = <ExamPage>[];
    QuestionLabel? current;

    for (final ExamPage page in document.pages) {
      final List<PageRegion> updated = <PageRegion>[];
      for (final PageRegion region in _ordered(page.regions)) {
        final HandwritingEvidence? found = handwriting[region.regionId];
        final DetectedLabel? opening = selection.forcedAt(region.regionId, 0) ??
            _admitted(
              labelOf(region, evidence, paper, current),
              selection,
              region.regionId,
              0,
            );
        if (opening != null) current = opening.label;

        if (!_splittable(region, found)) {
          updated.add(region);
          continue;
        }

        final List<String> lines = _primaryLines(found!);
        final List<int> cuts = <int>[];
        for (int index = 1; index < lines.length; index++) {
          final DetectedLabel? label = selection.forcedAt(region.regionId, index) ??
              _admitted(
                _labels.detect(lines[index], paper: paper, current: current),
                selection,
                region.regionId,
                index,
              );
          if (label != null) {
            cuts.add(index);
            current = label.label;
          }
        }
        if (cuts.isEmpty) {
          updated.add(region);
          continue;
        }

        final List<({PageRegion region, HandwritingEvidence evidence})> parts =
            splitRegion(region, found, cuts);
        final List<int> starts = <int>[0, ...cuts];
        for (int k = 0; k < parts.length; k++) {
          updated.add(parts[k].region);
          handwriting[parts[k].region.regionId] = parts[k].evidence;
          selection.carry(region.regionId, starts[k], parts[k].region.regionId, 0);
        }
      }

      // Reading order renumbered so the new parts sit where their parent was.
      pages.add(page.copyWith(regions: <PageRegion>[
        for (int i = 0; i < updated.length; i++) updated[i].copyWith(readingOrder: i),
      ]));
    }

    return (
      document: document.withPages(pages),
      evidence: evidence.copyWith(handwriting: handwriting),
    );
  }

  static List<String> _primaryLines(HandwritingEvidence evidence) {
    final HandwritingReading? reading = evidence.primary;
    if (reading == null) return const <String>[];
    if (reading.lines.isNotEmpty) {
      return reading.lines.map((RecognizedLine line) => line.text).toList();
    }
    return reading.text.split('\n');
  }

  /// Splits [region] before each line index in [cuts]. The parent's evidence
  /// stays in the evidence set; each part gets the slice of the primary
  /// reading that belongs to it.
  static List<({PageRegion region, HandwritingEvidence evidence})> splitRegion(
    PageRegion region,
    HandwritingEvidence evidence,
    List<int> cuts,
  ) {
    final HandwritingReading reading = evidence.primary!;
    final List<String> lines = _primaryLines(evidence);
    final int count = lines.length;

    List<NormalizedBox> boxes;
    if (region.lineBoxes.length == count) {
      boxes = region.lineBoxes;
    } else if (reading.lines.length == count) {
      boxes = reading.lines.map((RecognizedLine line) => line.box).toList();
    } else {
      // No per-line geometry: slice the block evenly. Approximate, but the
      // parts still cover exactly the parent's ink.
      boxes = <NormalizedBox>[
        for (int i = 0; i < count; i++)
          NormalizedBox(
            x: region.box.x,
            y: region.box.y + region.box.height * i / count,
            width: region.box.width,
            height: region.box.height / count,
          ),
      ];
    }

    final List<int> bounds = <int>[0, ...cuts, count];
    final List<({PageRegion region, HandwritingEvidence evidence})> parts =
        <({PageRegion region, HandwritingEvidence evidence})>[];

    // Character offset of each line's start within the joined text.
    final List<int> offsets = <int>[];
    int offset = 0;
    for (final String line in lines) {
      offsets.add(offset);
      offset += line.length + 1;
    }

    for (int k = 0; k + 1 < bounds.length; k++) {
      final int from = bounds[k];
      final int to = bounds[k + 1];
      final String text = lines.sublist(from, to).join('\n');
      final int start = offsets[from];
      final int end = start + text.length;
      final String id = '${region.regionId}.$k';

      final HandwritingReading part = HandwritingReading(
        source: reading.source,
        text: text,
        confidence: reading.lines.length == count
            ? _meanConfidence(reading.lines.sublist(from, to))
            : reading.confidence,
        engine: reading.engine,
        illegible: reading.illegible,
        lines: reading.lines.length == count
            ? reading.lines.sublist(from, to)
            : const <RecognizedLine>[],
        uncertainSpans: <UncertainSpan>[
          for (final UncertainSpan span in reading.uncertainSpans)
            if (span.start != null && span.start! >= start && span.start! < end)
              UncertainSpan(
                text: span.text,
                confidence: span.confidence,
                start: span.start! - start,
                end: span.end == null ? null : span.end! - start,
                box: span.box,
              ),
        ],
      );

      parts.add((
        region: region.copyWith(
          regionId: id,
          parentRegionId: () => region.regionId,
          box: boxes
              .sublist(from, to)
              .reduce((NormalizedBox a, NormalizedBox b) => a.union(b)),
          origin: RegionOrigin.derived,
          cropPath: () => null,
          detectedLabel: () => null,
          detectedText: region.detectedText == null ? null : () => text,
          lineBoxes: region.lineBoxes.length == count
              ? region.lineBoxes.sublist(from, to)
              : const <NormalizedBox>[],
          lineWords: region.lineWords.length == count
              ? region.lineWords.sublist(from, to)
              : const <List<NormalizedBox>>[],
        ),
        evidence: HandwritingEvidence(
          regionId: id,
          readings: <HandwritingReading>[part],
          agreement: evidence.agreement,
        ),
      ));
    }
    return parts;
  }

  static double _meanConfidence(List<RecognizedLine> lines) {
    if (lines.isEmpty) return 0;
    double weighted = 0;
    int weight = 0;
    for (final RecognizedLine line in lines) {
      weighted += line.confidence * line.text.length;
      weight += line.text.length;
    }
    return weight == 0 ? 0 : weighted / weight;
  }
}

class _Open {
  _Open({
    this.label,
    this.labelKey,
    this.labelRegionId,
    this.continuesPrevious = false,
    required this.confidence,
  });

  final String? label;
  final String? labelKey;
  final String? labelRegionId;
  final bool continuesPrevious;
  final double confidence;
  final List<String> regionIds = <String>[];
  final List<int> pages = <int>[];

  void add(PageRegion region) {
    regionIds.add(region.regionId);
    if (!pages.contains(region.pageNumber)) pages.add(region.pageNumber);
  }

  AnswerSegment build(String id) => AnswerSegment(
        segmentId: id,
        regionIds: List<String>.of(regionIds),
        pageNumbers: List<int>.of(pages),
        label: label,
        labelKey: labelKey,
        labelRegionId: labelRegionId,
        continuesPrevious: continuesPrevious,
        confidence: confidence.clamp(0.0, 1.0),
      );
}
