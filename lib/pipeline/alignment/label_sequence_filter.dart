import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/alignment/question_label_detector.dart';

/// A place on the answer sheet where a numbered label could start an answer:
/// the opening of a region, or a line partway down a block.
class LabelCandidate {
  const LabelCandidate({
    required this.regionId,
    required this.line,
    required this.label,
    required this.opensRegion,
    this.x,
    this.indented = false,
  });

  final String regionId;

  /// The line within the region's reading; 0 for its opening.
  final int line;
  final DetectedLabel label;

  /// The label starts a region of its own, rather than a line inside one.
  final bool opensRegion;

  /// Where the line starts across the page, 0..1, when that is known.
  final double? x;

  /// The line starts well to the right of the page's writing — where a
  /// student's own list sits, not where question numbers are written.
  final bool indented;

  String get key => LabelSelection.keyOf(regionId, line);
}

/// Which numbered labels start answers, as decided by [LabelSequenceFilter]
/// — and, for a question that would otherwise have no answer, recovered
/// afterwards by the boundary detector.
class LabelSelection {
  LabelSelection({
    required Set<String> considered,
    required Set<String> accepted,
    Map<String, String> notes = const <String, String>{},
    Set<String> inLists = const <String>{},
  })  : _considered = considered,
        _accepted = accepted,
        _notes = Map<String, String>.of(notes),
        _inLists = Set<String>.of(inLists);

  final Set<String> _considered;
  final Set<String> _accepted;

  /// Why each set-aside label was set aside, keyed by its position.
  final Map<String, String> _notes;

  /// Positions set aside as part of a student's numbered list.
  final Set<String> _inLists;

  /// Labels found only by a closer look, which the ordinary detector does
  /// not see: `S.` read for `5.`.
  final Map<String, DetectedLabel> _forced = <String, DetectedLabel>{};
  final List<String> _recovered = <String>[];

  /// What was set aside or recovered, and why, for the teacher.
  List<String> get warnings => <String>[..._notes.values, ..._recovered];

  static String keyOf(String regionId, int line) => '$regionId#$line';

  /// Accepts everything: for a caller that does not filter.
  factory LabelSelection.all() =>
      LabelSelection(considered: <String>{}, accepted: <String>{});

  /// Whether a numbered label at this position may start an answer. A
  /// position the filter never saw is let through, as before it existed.
  bool admits(String regionId, int line) {
    final String key = keyOf(regionId, line);
    return !_considered.contains(key) || _accepted.contains(key);
  }

  bool isAccepted(String key) => _accepted.contains(key);

  bool inList(String key) => _inLists.contains(key);

  /// A label recovered at this position, if one was.
  DetectedLabel? forcedAt(String regionId, int line) => _forced[keyOf(regionId, line)];

  /// Takes back a label that was set aside.
  void restore(String key, String note) {
    _accepted.add(key);
    _notes.remove(key);
    _recovered.add(note);
  }

  /// Accepts a label the ordinary detector could not read.
  void force(String key, DetectedLabel label, String note) {
    _considered.add(key);
    _accepted.add(key);
    _forced[key] = label;
    _recovered.add(note);
  }

  /// A block split at a label: its part's opening inherits the decision made
  /// about the line it starts at.
  void carry(String regionId, int line, String toRegionId, int toLine) {
    final String from = keyOf(regionId, line);
    if (!_considered.contains(from)) return;
    final String to = keyOf(toRegionId, toLine);
    _considered.add(to);
    if (_accepted.contains(from)) _accepted.add(to);
    final DetectedLabel? forced = _forced[from];
    if (forced != null) _forced[to] = forced;
  }
}

/// Tells question labels from the student's own numbered points.
///
/// Students number the points of a single answer — `1. … 2. … 3. …` — and
/// every one of those looks like a question label the paper has. Taken as
/// labels, they cut the answer short and hand its points to questions 1, 2
/// and 3. What gives them away is where they sit in the sequence:
///
/// - A label written unmistakably — `Q2`, the question's own wording, `3
///   cont.` — is always a label.
/// - A number that moves forward through the paper is a label.
/// - A run counting up from 1 that begins by going backwards — `1, 2, 3`
///   inside the answer to 5 — is the student's list, all of it.
/// - Any other number that goes backwards is a label only when it starts a
///   block of its own at the margin, which is how an answer written out of
///   order looks; inside a block, or indented, it is part of the answer.
///
/// Deterministic, and decided once for the whole answer sheet.
class LabelSequenceFilter {
  const LabelSequenceFilter();

  LabelSelection select(List<LabelCandidate> candidates, QuestionPaper paper) {
    final List<Question> order = paper.markable;
    final Set<String> accepted = <String>{};
    final Map<String, String> notes = <String, String>{};
    final Set<String> inLists = <String>{};

    int indexOf(QuestionLabel label) {
      for (int i = 0; i < order.length; i++) {
        final QuestionLabel leaf = order[i].label;
        if (leaf.isWithin(label) || label.isWithin(leaf)) return i;
      }
      return -1;
    }

    bool follows(QuestionLabel next, QuestionLabel last) {
      final int a = indexOf(next);
      final int b = indexOf(last);
      if (a < 0 || b < 0) return true;
      if (a != b) return a > b;
      if (next == last || last.isWithin(next)) return false;
      if (next.isWithin(last)) return true;
      return _laterPart(next, last);
    }

    LabelCandidate? last;

    void accept(LabelCandidate candidate) {
      accepted.add(candidate.key);
      if (candidate.label.inPaper) last = candidate;
    }

    int i = 0;
    while (i < candidates.length) {
      final LabelCandidate candidate = candidates[i];
      final DetectedLabel label = candidate.label;
      final LabelCandidate? before = last;

      if (label.strong ||
          !label.inPaper ||
          before == null ||
          follows(label.label, before.label.label)) {
        accept(candidate);
        i++;
        continue;
      }

      // Backwards, or the same question again.
      final List<LabelCandidate> run = _listRun(candidates, i, before, follows);
      if (run.length >= 2) {
        inLists.addAll(run.map((LabelCandidate c) => c.key));
        notes[run.first.key] = 'Numbered points ${run.first.label.label.display}–'
            '${run.last.label.label.display} in the answer to '
            '${before.label.label.display} were taken as the student\'s own '
            'points, not as question numbers.';
        i += run.length;
        continue;
      }
      if (candidate.opensRegion && !candidate.indented) {
        accept(candidate);
      } else {
        notes[candidate.key] =
            '"${label.observed}" in the answer to ${before.label.label.display} '
            'was taken as part of that answer, not as question '
            '${label.label.display}.';
      }
      i++;
    }

    return LabelSelection(
      considered: <String>{for (final LabelCandidate c in candidates) c.key},
      accepted: accepted,
      notes: notes,
      inLists: inLists,
    );
  }

  /// The student's list starting at [start]: `1`, then `2`, `3`… for as long
  /// as the count goes on and the numbers do not return to the margin where
  /// the question labels are written.
  static List<LabelCandidate> _listRun(
    List<LabelCandidate> candidates,
    int start,
    LabelCandidate last,
    bool Function(QuestionLabel next, QuestionLabel last) follows,
  ) {
    final LabelCandidate first = candidates[start];
    if (!_isNumber(first.label.label, 1)) return <LabelCandidate>[first];

    final List<LabelCandidate> run = <LabelCandidate>[first];
    for (int j = start + 1; j < candidates.length; j++) {
      final LabelCandidate next = candidates[j];
      if (next.label.strong || !_isNumber(next.label.label, run.length + 1)) break;
      if (follows(next.label.label, last.label.label) &&
          _backAtTheMargin(next, run, last)) {
        break;
      }
      run.add(next);
    }
    return run;
  }

  /// Whether [next], which would continue the list, looks instead like the
  /// next question: it starts a block, and sits where the last question label
  /// did rather than where the list does.
  static bool _backAtTheMargin(
    LabelCandidate next,
    List<LabelCandidate> run,
    LabelCandidate last,
  ) {
    if (!next.opensRegion) return false;
    final double? x = next.x;
    final double? labelX = last.x;
    final double? listX = run.first.x;
    if (x != null && labelX != null && listX != null) {
      return (x - labelX).abs() < (x - listX).abs();
    }
    // No geometry: the list was written inside blocks, and this starts one.
    return run.every((LabelCandidate c) => !c.opensRegion);
  }

  static bool _isNumber(QuestionLabel label, int number) =>
      label.depth == 1 && label.major == '$number';

  static const List<String> _romans = <String>[
    'i', 'ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix', 'x',
  ];

  /// Two labels below the same markable question: whether [next] names a
  /// later part than [last] — `3(b)` after `3(a)`.
  static bool _laterPart(QuestionLabel next, QuestionLabel last) {
    final int shared = next.depth < last.depth ? next.depth : last.depth;
    for (int k = 0; k < shared; k++) {
      final String a = next.parts[k];
      final String b = last.parts[k];
      if (a == b) continue;
      final int ra = _romans.indexOf(a);
      final int rb = _romans.indexOf(b);
      if (a.length > 1 || b.length > 1) {
        if (ra >= 0 && rb >= 0) return ra > rb;
      }
      return a.compareTo(b) > 0;
    }
    return next.depth > last.depth;
  }
}
