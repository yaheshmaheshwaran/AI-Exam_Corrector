import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';

/// One answer from the teacher's own answer key, matched to a question.
///
/// It holds only what the teacher wrote: the answer, the points and what
/// each is worth when the key says, answers they also accept, and — for a
/// multiple-choice question — the right option.
class TeacherKeyEntry {
  const TeacherKeyEntry({
    required this.questionId,
    this.answer = '',
    this.points = const <AnswerKeyPoint>[],
    this.alternatives = const <String>[],
    this.option,
    this.keyMarks,
    this.notes = '',
  });

  final String questionId;

  /// The answer as the teacher wrote it.
  final String answer;

  /// Points with the marks the key gives them, when it lists them.
  final List<AnswerKeyPoint> points;

  /// Other answers the teacher accepts: "Also accept: powerhouse".
  final List<String> alternatives;

  /// The right option of a multiple-choice question, lower-case: `b`.
  final String? option;

  /// The marks the key gives the question, when it says; the paper's
  /// maximum still wins.
  final double? keyMarks;
  final String notes;

  bool get isEmpty => answer.trim().isEmpty && points.isEmpty && option == null && alternatives.isEmpty;

  /// As the marker and the teacher read it.
  String get text {
    final StringBuffer out = StringBuffer();
    if (option != null) out.writeln('Correct option: ($option)');
    if (answer.trim().isNotEmpty) out.writeln(answer.trim());
    for (final AnswerKeyPoint point in points) {
      out.writeln('- ${point.criterion} [${formatMarks(point.marks)}]');
    }
    if (alternatives.isNotEmpty) out.writeln('Also accept: ${alternatives.join('; ')}');
    if (notes.trim().isNotEmpty) out.writeln('Note: ${notes.trim()}');
    return out.toString().trim();
  }

  JsonMap toJson() => <String, Object?>{
        'questionId': questionId,
        if (answer.isNotEmpty) 'answer': answer,
        if (points.isNotEmpty) 'points': <JsonMap>[for (final AnswerKeyPoint p in points) p.toJson()],
        if (alternatives.isNotEmpty) 'alternatives': alternatives,
        'option': ?option,
        'keyMarks': ?keyMarks,
        if (notes.isNotEmpty) 'notes': notes,
      };

  static TeacherKeyEntry? fromJson(JsonMap json) {
    final String? id = readString(json['questionId']);
    if (id == null) return null;
    return TeacherKeyEntry(
      questionId: id,
      answer: readRawString(json['answer']) ?? '',
      points: readObjects(json['points'], AnswerKeyPoint.fromJson),
      alternatives: readStringList(json['alternatives']),
      option: readString(json['option'])?.toLowerCase(),
      keyMarks: readDouble(json['keyMarks']),
      notes: readRawString(json['notes']) ?? '',
    );
  }
}

/// The teacher's own answer key for a question paper, as read from their
/// file and matched to the paper's questions.
///
/// It only ever adds to marking: a question it covers is marked against it,
/// and a question it does not cover is marked exactly as it would be
/// without one.
class TeacherKey {
  const TeacherKey({
    required this.fileName,
    required this.sourceHash,
    required this.text,
    this.entries = const <String, TeacherKeyEntry>{},
    this.unmatched = const <String>[],
    this.warnings = const <String>[],
    this.matched = true,
  });

  final String fileName;

  /// The key file's content hash: the same file read twice is the same key.
  final String sourceHash;

  /// The key's text as read, kept so it can be matched again.
  final String text;

  /// By question ID.
  final Map<String, TeacherKeyEntry> entries;

  /// Labels the key answers that are not questions on the paper.
  final List<String> unmatched;

  /// What the teacher should know: marks that disagree with the paper, and
  /// the like.
  final List<String> warnings;

  /// False until the key has been matched to the paper's questions — a
  /// scanned paper is read only when marking starts.
  final bool matched;

  bool get isEmpty => entries.isEmpty;

  /// How much of the paper the key covers. Questions the paper prints its
  /// own scheme for are not counted as covered: the printed scheme wins.
  ({int covered, int total, int printed}) coverage(QuestionPaper paper) {
    int covered = 0, printed = 0, total = 0;
    for (final Question question in paper.markable) {
      total++;
      if (!entries.containsKey(question.questionId)) continue;
      if (paper.markSchemeFor(question).trim().isNotEmpty) {
        printed++;
      } else {
        covered++;
      }
    }
    return (covered: covered, total: total, printed: printed);
  }

  TeacherKey copyWith({
    Map<String, TeacherKeyEntry>? entries,
    List<String>? unmatched,
    List<String>? warnings,
    bool? matched,
  }) =>
      TeacherKey(
        fileName: fileName,
        sourceHash: sourceHash,
        text: text,
        entries: entries ?? this.entries,
        unmatched: unmatched ?? this.unmatched,
        warnings: warnings ?? this.warnings,
        matched: matched ?? this.matched,
      );

  JsonMap toJson() => <String, Object?>{
        'fileName': fileName,
        'sourceHash': sourceHash,
        'text': text,
        'matched': matched,
        'entries': <JsonMap>[for (final TeacherKeyEntry e in entries.values) e.toJson()],
        if (unmatched.isNotEmpty) 'unmatched': unmatched,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };

  static TeacherKey? fromJson(JsonMap? json) {
    if (json == null) return null;
    final String? fileName = readString(json['fileName']);
    final String? hash = readString(json['sourceHash']);
    if (fileName == null || hash == null) return null;
    return TeacherKey(
      fileName: fileName,
      sourceHash: hash,
      text: readRawString(json['text']) ?? '',
      matched: readBool(json['matched']) ?? true,
      entries: <String, TeacherKeyEntry>{
        for (final TeacherKeyEntry e in readObjects(json['entries'], TeacherKeyEntry.fromJson)) e.questionId: e,
      },
      unmatched: readStringList(json['unmatched']),
      warnings: readStringList(json['warnings']),
    );
  }
}

/// A teacher's key file as read, before it is matched to any question.
class TeacherKeySource {
  const TeacherKeySource({required this.fileName, required this.hash, required this.text});

  final String fileName;
  final String hash;
  final String text;

  /// Stored as a key not yet matched to the paper.
  TeacherKey get unmatched => TeacherKey(fileName: fileName, sourceHash: hash, text: text, matched: false);
}
