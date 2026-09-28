import 'dart:io';

import 'package:supabase/supabase.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/models/account.dart';
import 'package:exam_corrector/models/correction_request.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/models/student_status.dart';
import 'package:exam_corrector/services/accounts/server_errors.dart';
import 'package:exam_corrector/services/results/results_repository.dart';

/// A college's published results on its server, as one signed-in account
/// may see them.
///
/// The server's rules decide what that is — a teacher sees the college's
/// results, a student only their own roll number's — so this asks for
/// everything and gets what it is allowed. What a student may change (seen,
/// verified, a request) goes through the server's functions, which check it
/// again there.
///
/// A result is stored as its JSON beside the columns it is found by; its
/// answer sheet pages are files in the `answer-sheets` bucket, fetched into
/// [pageCache] before they are shown, so a page is always a file here.
class SupabaseResultsRepository implements ResultsRepository, StudentDirectory {
  SupabaseResultsRepository(this.client, this.account, {this.pageCache});

  final SupabaseClient client;
  final Account account;
  final Directory? pageCache;

  static const String bucket = 'answer-sheets';

  StorageFileApi get _pages => client.storage.from(bucket);

  Future<T> _call<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on AppException {
      rethrow;
    } catch (error) {
      throw describeServerError(error, results: true);
    }
  }

  String _now() => DateTime.now().toUtc().toIso8601String();

  // --------------------------------------------------------------------------
  // Rows and results
  // --------------------------------------------------------------------------

  /// The columns a result is stored in; seen and verified are the server's.
  static Map<String, Object?> rowFor(PublishedResult result, {required String collegeId}) {
    final JsonMap payload = result.toJson()
      ..remove('id')
      ..remove('pages');
    return <String, Object?>{
      'college_id': collegeId,
      'roll_no': result.rollNo,
      'subject_code': result.subjectCode,
      'exam': result.exam,
      'student_name': result.student,
      'paper_hash': result.paperHash,
      'script_hash': result.scriptHash,
      'total': result.total,
      'maximum': result.maximum,
      'percentage': result.percentage,
      'payload': payload,
      'published_at': result.publishedAt.toUtc().toIso8601String(),
    };
  }

  /// Where a page of a result is stored in the bucket.
  static String objectFor({required String collegeId, required String resultId, required PublishedPage page}) =>
      '$collegeId/$resultId/page_${page.number}.${_extension(page.imagePath)}';

  static String _extension(String path) {
    final String extension = path.split('.').last.toLowerCase();
    return const <String>{'png', 'jpg', 'jpeg', 'webp'}.contains(extension) ? extension : 'png';
  }

  /// Where a stored page is kept on this computer; the result's last change
  /// is part of the path, so a republished page is never shown stale.
  static String cachePath(
    Directory cache, {
    required String resultId,
    required String updatedAt,
    required String object,
  }) {
    final String stamp = (DateTime.tryParse(updatedAt)?.millisecondsSinceEpoch ?? 0).toString();
    final String sep = Platform.pathSeparator;
    return '${cache.path}$sep$resultId$sep$stamp$sep${object.split('/').last}';
  }

  /// A result from its row. Pages point into [cache] when there is one.
  static PublishedResult resultFrom(Map<String, dynamic> row, {Directory? cache}) {
    final String id = '${row['id']}';
    final JsonMap payload = <String, Object?>{...?(readMap(row['payload'])), 'id': id};
    final PublishedResult base =
        PublishedResult.fromJson(payload) ??
        PublishedResult(
          id: id,
          student: '',
          paperTitle: '',
          fileName: '',
          publishedAt: DateTime(2000),
          total: 0,
          maximum: 0,
          percentage: 0,
        );
    final String updatedAt = '${row['updated_at'] ?? ''}';
    final List<PublishedPage> pages = <PublishedPage>[
      for (final Object? entry in (row['pages'] as List<Object?>? ?? const <Object?>[]))
        if (readMap(entry) case final JsonMap page)
          if (readInt(page['number']) case final int number)
            if (readString(page['object']) case final String object)
              PublishedPage(
                number: number,
                imagePath: cache == null
                    ? object
                    : cachePath(cache, resultId: id, updatedAt: updatedAt, object: object),
                width: readInt(page['width']) ?? 1000,
                height: readInt(page['height']) ?? 1400,
              ),
    ];
    DateTime? date(Object? value) => value is String ? DateTime.tryParse(value)?.toLocal() : null;
    return PublishedResult(
      id: id,
      rollNo: '${row['roll_no'] ?? base.rollNo}',
      subjectCode: '${row['subject_code'] ?? base.subjectCode}',
      exam: '${row['exam'] ?? base.exam}',
      student: '${row['student_name'] ?? base.student}',
      paperTitle: base.paperTitle,
      fileName: base.fileName,
      publishedAt: date(row['published_at']) ?? base.publishedAt,
      total: readDouble(row['total']) ?? base.total,
      maximum: readDouble(row['maximum']) ?? base.maximum,
      percentage: readDouble(row['percentage']) ?? base.percentage,
      totalRounding: base.totalRounding,
      paperHash: base.paperHash,
      scriptHash: base.scriptHash,
      standard: base.standard,
      sections: base.sections,
      questions: base.questions,
      pages: pages,
      firstSeenAt: date(row['first_seen_at']),
      lastSeenAt: date(row['last_seen_at']),
      seenCount: readInt(row['seen_count']) ?? 0,
      verifiedAt: date(row['verified_at']),
    );
  }

  Future<Map<String, dynamic>?> _row(String id) async {
    final int? key = int.tryParse(id);
    if (key == null) return null;
    return client.from('results').select().eq('id', key).maybeSingle();
  }

  /// Fetches the pages of [result] that are not on this computer yet. A page
  /// that cannot be fetched is left out, so the rest still show.
  Future<PublishedResult> _withPages(PublishedResult result, Map<String, dynamic> row) async {
    final Directory? cache = pageCache;
    if (cache == null || result.pages.isEmpty) return result;
    final List<Object?> stored = row['pages'] as List<Object?>? ?? const <Object?>[];
    final List<PublishedPage> kept = <PublishedPage>[];
    for (int i = 0; i < result.pages.length && i < stored.length; i++) {
      final PublishedPage page = result.pages[i];
      final File file = File(page.imagePath);
      if (!await file.exists()) {
        final String? object = readString(readMap(stored[i])?['object']);
        if (object == null) continue;
        try {
          await file.parent.create(recursive: true);
          await file.writeAsBytes(await _pages.download(object), flush: true);
        } on Exception {
          continue;
        }
      }
      kept.add(page);
    }
    return PublishedResult(
      id: result.id,
      rollNo: result.rollNo,
      subjectCode: result.subjectCode,
      exam: result.exam,
      student: result.student,
      paperTitle: result.paperTitle,
      fileName: result.fileName,
      publishedAt: result.publishedAt,
      total: result.total,
      maximum: result.maximum,
      percentage: result.percentage,
      totalRounding: result.totalRounding,
      paperHash: result.paperHash,
      scriptHash: result.scriptHash,
      standard: result.standard,
      sections: result.sections,
      questions: result.questions,
      pages: kept,
      firstSeenAt: result.firstSeenAt,
      lastSeenAt: result.lastSeenAt,
      seenCount: result.seenCount,
      verifiedAt: result.verifiedAt,
    );
  }

  // --------------------------------------------------------------------------
  // Results
  // --------------------------------------------------------------------------

  @override
  Future<PublishedResult> publish(PublishedResult result) => _call(() async {
    if (result.rollNo.isEmpty) throw const ResultsException('A roll number is needed to publish a result.');
    if (result.subjectCode.isEmpty) {
      throw const ResultsException('A subject code is needed to publish a result.');
    }
    final String college = account.college.id;
    // Marks that changed must be seen, and agreed to, afresh.
    final Map<String, dynamic>? before = await client
        .from('results')
        .select()
        .eq('college_id', college)
        .eq('roll_no', result.rollNo)
        .eq('subject_code', result.subjectCode)
        .eq('exam', result.exam)
        .maybeSingle();
    final bool unchanged = before != null && sameMarks(resultFrom(before), result);

    final Map<String, dynamic> saved = await client
        .from('results')
        .upsert(<String, Object?>{
          ...rowFor(result, collegeId: college),
          'updated_at': _now(),
          if (!unchanged) ...<String, Object?>{
            'first_seen_at': null,
            'last_seen_at': null,
            'seen_count': 0,
            'verified_at': null,
          },
        }, onConflict: 'college_id,roll_no,subject_code,exam')
        .select()
        .single();
    final String id = '${saved['id']}';

    // The answer sheet, page by page, into the college's folder — and a
    // copy kept here, so it shows without fetching it back.
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    final Set<String> objects = <String>{};
    for (final PublishedPage page in result.pages) {
      final File source = File(page.imagePath);
      if (!await source.exists()) continue;
      final String object = objectFor(collegeId: college, resultId: id, page: page);
      final String extension = object.split('.').last;
      await _pages.uploadBinary(
        object,
        await source.readAsBytes(),
        fileOptions: FileOptions(upsert: true, contentType: extension == 'jpg' ? 'image/jpeg' : 'image/$extension'),
      );
      objects.add(object);
      pages.add(<String, Object?>{'number': page.number, 'width': page.width, 'height': page.height, 'object': object});
    }
    final List<String> stale = <String>[
      for (final Object? entry in (before?['pages'] as List<Object?>? ?? const <Object?>[]))
        if (readString(readMap(entry)?['object']) case final String object)
          if (!objects.contains(object)) object,
    ];
    if (stale.isNotEmpty) await _pages.remove(stale);
    final Map<String, dynamic> row = await client
        .from('results')
        .update(<String, Object?>{'pages': pages})
        .eq('id', saved['id'])
        .select()
        .single();

    final Directory? cache = pageCache;
    final PublishedResult published = resultFrom(row, cache: cache);
    if (cache != null) {
      for (final PublishedPage page in result.pages) {
        final PublishedPage? kept = published.pages.where((PublishedPage p) => p.number == page.number).firstOrNull;
        if (kept == null) continue;
        final File target = File(kept.imagePath);
        await target.parent.create(recursive: true);
        await File(page.imagePath).copy(target.path);
      }
    }
    return published;
  });

  @override
  Future<PublishedResult?> result(String id) => _call(() async {
    final Map<String, dynamic>? row = await _row(id);
    if (row == null) return null;
    return _withPages(resultFrom(row, cache: pageCache), row);
  });

  @override
  Future<List<PublishedResult>> resultsFor({required String rollNo, String? subjectCode}) => _call(() async {
    final String roll = PublishedResult.normaliseRoll(rollNo);
    if (roll.isEmpty) return const <PublishedResult>[];
    PostgrestFilterBuilder<List<Map<String, dynamic>>> query = client.from('results').select().eq('roll_no', roll);
    if (subjectCode != null && subjectCode.trim().isNotEmpty) {
      query = query.eq('subject_code', PublishedResult.normaliseRoll(subjectCode));
    }
    final List<Map<String, dynamic>> rows = await query.order('published_at', ascending: false);
    return <PublishedResult>[for (final Map<String, dynamic> row in rows) resultFrom(row, cache: pageCache)];
  });

  @override
  Future<List<PublishedResult>> all() => _call(() async {
    final List<Map<String, dynamic>> rows = await client
        .from('results')
        .select()
        .order('published_at', ascending: false);
    return <PublishedResult>[for (final Map<String, dynamic> row in rows) resultFrom(row, cache: pageCache)];
  });

  @override
  Future<void> unpublish(String id) => _call(() async {
    final Map<String, dynamic>? row = await _row(id);
    if (row == null) return;
    await client.from('results').delete().eq('id', row['id']);
    final List<String> objects = <String>[
      for (final Object? entry in (row['pages'] as List<Object?>? ?? const <Object?>[]))
        if (readString(readMap(entry)?['object']) case final String object) object,
    ];
    if (objects.isNotEmpty) await _pages.remove(objects);
  });

  // --------------------------------------------------------------------------
  // Correction requests
  // --------------------------------------------------------------------------

  @override
  Future<CorrectionRequest> requestCorrection({
    required String resultId,
    required String questionId,
    required String message,
  }) => _call(() async {
    if (message.trim().isEmpty) throw const ResultsException('Say why the mark should be looked at again.');
    final Object? id = await client.rpc(
      'request_correction',
      params: <String, Object?>{
        'p_result': int.tryParse(resultId) ?? -1,
        'p_question': questionId,
        'p_message': message.trim(),
      },
    );
    return (await requests(resultId: resultId)).firstWhere((CorrectionRequest r) => r.id == readInt(id));
  });

  static CorrectionRequest requestFrom(Map<String, dynamic> row) {
    DateTime? date(Object? value) => value is String ? DateTime.tryParse(value)?.toLocal() : null;
    return CorrectionRequest(
      id: readInt(row['id']) ?? 0,
      resultId: '${row['result_id']}',
      questionId: '${row['question_id']}',
      questionNumber: readString(row['number']) ?? '${row['question_id']}',
      rollNo: '${row['roll_no']}',
      studentName: readRawString(row['student_name']) ?? '',
      subjectCode: '${row['subject_code']}',
      exam: readRawString(row['exam']) ?? '',
      message: readRawString(row['message']) ?? '',
      status: readEnum(RequestStatus.values, row['status'], RequestStatus.open),
      reply: readRawString(row['reply']) ?? '',
      oldMarks: readDouble(row['old_marks']),
      newMarks: readDouble(row['new_marks']),
      currentMarks: readDouble(row['marks']) ?? 0,
      maximum: readDouble(row['maximum']) ?? 0,
      explanation: readRawString(row['explanation']) ?? '',
      createdAt: date(row['created_at']) ?? DateTime.now(),
      resolvedAt: date(row['resolved_at']),
    );
  }

  @override
  Future<List<CorrectionRequest>> requests({
    String? rollNo,
    String? subjectCode,
    String? resultId,
    bool openOnly = false,
  }) => _call(() async {
    PostgrestFilterBuilder<List<Map<String, dynamic>>> query = client.from('request_details').select();
    if (rollNo != null) query = query.eq('roll_no', PublishedResult.normaliseRoll(rollNo));
    if (subjectCode != null && subjectCode.trim().isNotEmpty) {
      query = query.eq('subject_code', PublishedResult.normaliseRoll(subjectCode));
    }
    if (resultId != null) query = query.eq('result_id', int.tryParse(resultId) ?? -1);
    if (openOnly) query = query.eq('status', 'open');
    final List<Map<String, dynamic>> rows = await query.order('created_at', ascending: false);
    final List<CorrectionRequest> found = <CorrectionRequest>[
      for (final Map<String, dynamic> row in rows) requestFrom(row),
    ];
    // Open first, then newest first — as on this computer.
    return <CorrectionRequest>[
      ...found.where((CorrectionRequest r) => r.isOpen),
      ...found.where((CorrectionRequest r) => !r.isOpen),
    ];
  });

  @override
  Future<int> openRequestCount() =>
      _call(() => client.from('correction_requests').count(CountOption.exact).eq('status', 'open'));

  Future<CorrectionRequest> _openRequest(int id) async {
    final CorrectionRequest? request = (await requests()).where((CorrectionRequest r) => r.id == id).firstOrNull;
    if (request == null) throw const ResultsException('That request no longer exists.');
    if (!request.isOpen) throw const ResultsException('That request has already been answered.');
    return request;
  }

  @override
  Future<PublishedResult> acceptRequest(int id, {required double marks, required String reply}) => _call(() async {
    final CorrectionRequest request = await _openRequest(id);
    if (marks < 0 || marks > request.maximum) {
      throw ResultsException('The mark must be between 0 and ${request.maximum}.');
    }
    final Map<String, dynamic>? row = await _row(request.resultId);
    if (row == null) throw const ResultsException('That result is no longer published.');
    // The new totals are worked out here, by the same rules as ever; the
    // server stores them with the request's answer, in one go.
    final PublishedResult changed = resultFrom(row).withMark(request.questionId, marks);
    final JsonMap payload = changed.toJson()
      ..remove('id')
      ..remove('pages');
    await client.rpc(
      'accept_request',
      params: <String, Object?>{
        'p_request': id,
        'p_marks': marks,
        'p_reply': reply.trim(),
        'p_payload': payload,
        'p_total': changed.total,
        'p_percentage': changed.percentage,
      },
    );
    return (await result(request.resultId))!;
  });

  @override
  Future<void> declineRequest(int id, {required String reply}) => _call(() async {
    if (reply.trim().isEmpty) throw const ResultsException('Tell the student why the mark stays as it is.');
    await _openRequest(id);
    await client.rpc('decline_request', params: <String, Object?>{'p_request': id, 'p_reply': reply.trim()});
  });

  // --------------------------------------------------------------------------
  // Seen and verified
  // --------------------------------------------------------------------------

  @override
  Future<void> markSeen(String resultId) => _call(() async {
    await client.rpc('mark_seen', params: <String, Object?>{'p_result': int.tryParse(resultId) ?? -1});
  });

  @override
  Future<PublishedResult> verify(String resultId) => _call(() async {
    await client.rpc('verify_result', params: <String, Object?>{'p_result': int.tryParse(resultId) ?? -1});
    final PublishedResult? verified = await result(resultId);
    if (verified == null) throw const ResultsException('That result is no longer published.');
    return verified;
  });

  static StudentStatus statusFrom(Map<String, dynamic> row) {
    DateTime? date(Object? value) => value is String ? DateTime.tryParse(value)?.toLocal() : null;
    return StudentStatus(
      resultId: '${row['id']}',
      rollNo: '${row['roll_no']}',
      studentName: readRawString(row['student_name']) ?? '',
      subjectCode: '${row['subject_code']}',
      exam: readRawString(row['exam']) ?? '',
      total: readDouble(row['total']) ?? 0,
      maximum: readDouble(row['maximum']) ?? 0,
      percentage: readDouble(row['percentage']) ?? 0,
      publishedAt: date(row['published_at']) ?? DateTime.now(),
      firstSeenAt: date(row['first_seen_at']),
      lastSeenAt: date(row['last_seen_at']),
      seenCount: readInt(row['seen_count']) ?? 0,
      verifiedAt: date(row['verified_at']),
      openRequests: readInt(row['open_requests']) ?? 0,
      acceptedRequests: readInt(row['accepted_requests']) ?? 0,
      declinedRequests: readInt(row['declined_requests']) ?? 0,
      badges: readInt(row['badges']) ?? 0,
    );
  }

  @override
  Future<List<StudentStatus>> overview({String? subjectCode, String? exam}) => _call(() async {
    PostgrestFilterBuilder<List<Map<String, dynamic>>> query = client.from('result_overview').select();
    if (subjectCode != null && subjectCode.trim().isNotEmpty) {
      query = query.eq('subject_code', PublishedResult.normaliseRoll(subjectCode));
    }
    if (exam != null) query = query.eq('exam', exam);
    final List<Map<String, dynamic>> rows = await query.order('subject_code').order('exam').order('roll_no');
    return <StudentStatus>[for (final Map<String, dynamic> row in rows) statusFrom(row)];
  });

  @override
  Future<List<String>> subjects() => _call(() async {
    final List<Map<String, dynamic>> rows = await client.from('results').select('subject_code');
    return (<String>{for (final Map<String, dynamic> row in rows) '${row['subject_code']}'}.toList())..sort();
  });

  @override
  Future<List<String>> exams({String? subjectCode}) => _call(() async {
    PostgrestFilterBuilder<List<Map<String, dynamic>>> query = client.from('results').select('exam');
    if (subjectCode != null && subjectCode.trim().isNotEmpty) {
      query = query.eq('subject_code', PublishedResult.normaliseRoll(subjectCode));
    }
    final List<Map<String, dynamic>> rows = await query;
    return (<String>{for (final Map<String, dynamic> row in rows) '${row['exam']}'}.toList())..sort();
  });

  // --------------------------------------------------------------------------
  // What a paper was last published under
  // --------------------------------------------------------------------------

  @override
  Future<({String subjectCode, String exam})?> paperDefaults(String paperHash) => _call(() async {
    final Map<String, dynamic>? row = await client
        .from('paper_defaults')
        .select()
        .eq('paper_hash', paperHash)
        .maybeSingle();
    if (row == null) return null;
    return (subjectCode: '${row['subject_code']}', exam: '${row['exam']}');
  });

  @override
  Future<void> savePaperDefaults(String paperHash, {required String subjectCode, required String exam}) =>
      _call(() async {
        await client.from('paper_defaults').upsert(<String, Object?>{
          'paper_hash': paperHash,
          'subject_code': PublishedResult.normaliseRoll(subjectCode),
          'exam': exam.trim(),
        }, onConflict: 'owner,paper_hash');
      });

  @override
  Future<Set<String>> registeredRolls() => _call(() async {
    final List<Map<String, dynamic>> rows = await client
        .from('profiles')
        .select('roll_no')
        .eq('role', 'student')
        .eq('status', 'active');
    return <String>{
      for (final Map<String, dynamic> row in rows)
        if (row['roll_no'] case final String roll) roll,
    };
  });

  @override
  void close() {}
}
