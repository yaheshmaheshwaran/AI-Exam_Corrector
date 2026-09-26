import 'dart:io';

import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/pipeline/cache/artifact_store.dart';

/// Persists what the teacher decided: mark reviews and transcription fixes.
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

  /// Teacher work is read even when stage caching is turned off: it is the
  /// teacher's record, not a cache.
  Future<JsonMap?> _read(String hash, String key) async {
    if (_store.enabled) return _store.read(hash, key);
    return ArtifactStore(_store.root).read(hash, key);
  }

  Directory get root => _store.root;
}
