import 'dart:io';

import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/pipeline/cache/artifact_store.dart';

/// Persists what the teacher decided: mark reviews, transcription fixes, and
/// which writing answers which question.
///
/// Kept apart from the pipeline's artifacts, which it never touches, so the
/// AI's results stay exactly as produced and the teacher's decisions survive
/// a re-run, a restart and a cleared cache of stage results alike.
class TeacherWorkStore {
  const TeacherWorkStore(this._store);

  final ArtifactStore _store;

  static String _reviewsKey(String paperHash) => 'teacher-reviews-$paperHash';
  static const String _correctionsKey = 'teacher-transcriptions';

  Future<TeacherReviewBook> reviews(String answerHash, String paperHash) async {
    final JsonMap? saved = await _read(answerHash, _reviewsKey(paperHash));
    return saved == null ? const TeacherReviewBook() : TeacherReviewBook.fromJson(saved);
  }

  Future<void> saveReviews(
    String answerHash,
    String paperHash,
    TeacherReviewBook book,
  ) =>
      _store.write(answerHash, _reviewsKey(paperHash), book.toJson());

  /// The teacher's readings of regions, keyed by region ID.
  Future<Map<String, String>> transcriptions(String answerHash) async {
    final JsonMap? saved = await _read(answerHash, _correctionsKey);
    return <String, String>{
      for (final MapEntry<String, Object?> entry
          in (saved ?? const <String, Object?>{}).entries)
        if (readRawString(entry.value) case final String text) entry.key: text,
    };
  }

  Future<void> saveTranscriptions(String answerHash, Map<String, String> texts) =>
      _store.write(answerHash, _correctionsKey, Map<String, Object?>.of(texts));

  static String _assignmentsKey(String paperHash) => 'teacher-assignments-$paperHash';

  /// Writing the teacher chose as the answer to a question: region ID to
  /// question ID. Kept per question paper, whose questions they name.
  Future<Map<String, String>> assignments(String answerHash, String paperHash) async {
    final JsonMap? saved = await _read(answerHash, _assignmentsKey(paperHash));
    return <String, String>{
      for (final MapEntry<String, Object?> entry
          in (saved ?? const <String, Object?>{}).entries)
        if (readString(entry.value) case final String questionId) entry.key: questionId,
    };
  }

  Future<void> saveAssignments(
    String answerHash,
    String paperHash,
    Map<String, String> assignments,
  ) =>
      _store.write(answerHash, _assignmentsKey(paperHash), Map<String, Object?>.of(assignments));

  static const String _answerKeyKey = 'answer-key-latest';
  static const String _answerKeyEditsKey = 'answer-key-edits';
  static const String _moderationKey = 'moderation';
  static const String _teacherKeyKey = 'teacher-key';

  /// The answer key the paper was last marked against, as the pipeline
  /// saved it.
  Future<JsonMap?> answerKey(String paperHash) => _read(paperHash, _answerKeyKey);

  Future<void> saveAnswerKey(String paperHash, JsonMap key) => _store.write(paperHash, _answerKeyKey, key);

  /// The teacher's own key for questions, by question ID, in place of the
  /// AI's.
  Future<Map<String, String>> answerKeyEdits(String paperHash) async {
    final JsonMap? saved = await _read(paperHash, _answerKeyEditsKey);
    return <String, String>{
      for (final MapEntry<String, Object?> entry in (saved ?? const <String, Object?>{}).entries)
        if (readRawString(entry.value) case final String text when text.trim().isNotEmpty) entry.key: text,
    };
  }

  Future<void> saveAnswerKeyEdits(String paperHash, Map<String, String> edits) =>
      _store.write(paperHash, _answerKeyEditsKey, Map<String, Object?>.of(edits));

  /// The teacher's own answer key for the paper, as read and matched.
  Future<JsonMap?> teacherKey(String paperHash) => _read(paperHash, _teacherKeyKey);

  Future<void> saveTeacherKey(String paperHash, JsonMap key) => _store.write(paperHash, _teacherKeyKey, key);

  Future<void> removeTeacherKey(String paperHash) async {
    await _store.remove(paperHash, _teacherKeyKey);
    if (!_store.enabled) await ArtifactStore(_store.root).remove(paperHash, _teacherKeyKey);
  }

  /// The teacher's marks the paper is moderated by, and the moderation in
  /// force.
  Future<JsonMap?> moderation(String paperHash) => _read(paperHash, _moderationKey);

  Future<void> saveModeration(String paperHash, JsonMap value) => _store.write(paperHash, _moderationKey, value);

  /// Teacher work is read even when stage caching is turned off: it is the
  /// teacher's record, not a cache.
  Future<JsonMap?> _read(String hash, String key) async {
    if (_store.enabled) return _store.read(hash, key);
    return ArtifactStore(_store.root).read(hash, key);
  }

  Directory get root => _store.root;
}
