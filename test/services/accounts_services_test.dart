import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/correction_request.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/models/student_status.dart';
import 'package:exam_corrector/services/accounts/server_config.dart';
import 'package:exam_corrector/services/accounts/server_errors.dart';
import 'package:exam_corrector/services/accounts/session_file.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/results/session_results.dart';
import 'package:exam_corrector/services/results/supabase_results_repository.dart';

import '../state/fakes.dart';

void main() {
  group('server address', () {
    test('https only (or this computer), tidied', () {
      final ServerConfig server = ServerConfig.validated(
        url: ' https://abc.supabase.co/ ',
        anonKey: ' key-0123456789-0123456789 ',
      );
      expect(server.url, 'https://abc.supabase.co');
      expect(server.anonKey, 'key-0123456789-0123456789');
      expect(server.host, 'abc.supabase.co');
      expect(
        ServerConfig.validated(url: 'http://localhost:54321', anonKey: 'key-0123456789-0123456789').url,
        'http://localhost:54321',
      );
      expect(
        () => ServerConfig.validated(url: 'http://abc.supabase.co', anonKey: 'key-0123456789-0123456789'),
        throwsA(isA<AccountException>()),
      );
      expect(
        () => ServerConfig.validated(url: 'abc', anonKey: 'key-0123456789-0123456789'),
        throwsA(isA<AccountException>()),
      );
      expect(
        () => ServerConfig.validated(url: 'https://abc.supabase.co', anonKey: 'short'),
        throwsA(isA<AccountException>()),
      );
    });

    test('the environment first, then this computer’s settings', () async {
      final RecordingSettingsStore settings = RecordingSettingsStore()
        ..savedServerUrl = 'https://saved.supabase.co'
        ..savedServerKey = 'saved-key-0123456789';
      expect(
        (await ServerConfig.load(settings: settings, environment: const <String, String>{}))!.url,
        'https://saved.supabase.co',
      );
      expect(
        (await ServerConfig.load(
          settings: settings,
          environment: const <String, String>{
            'SUPABASE_URL': 'https://env.supabase.co',
            'SUPABASE_ANON_KEY': 'env-key-0123456789-01',
          },
        ))!.url,
        'https://env.supabase.co',
      );
      expect(
        await ServerConfig.load(settings: RecordingSettingsStore(), environment: const <String, String>{}),
        isNull,
      );
    });
  });

  group('the kept session', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('session'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('is kept per server, and gone once deleted or unreadable', () async {
      final File file = File('${dir.path}/account-session.json');
      final SessionFile sessions = SessionFile(file);
      expect(await sessions.read('https://a.co'), isNull);
      await sessions.write('https://a.co', '{"access_token":"t"}');
      expect(await sessions.read('https://a.co'), '{"access_token":"t"}');
      expect(await sessions.read('https://b.co'), isNull, reason: 'kept for another server');
      if (!Platform.isWindows) {
        final String mode = (await Process.run('stat', <String>['-f', '%Lp', file.path])).stdout.toString().trim();
        expect(mode, '600', reason: 'readable by this user only');
      }
      await sessions.delete();
      expect(file.existsSync(), isFalse);
      file.writeAsStringSync('not json');
      expect(await sessions.read('https://a.co'), isNull);
    });
  });

  group('server errors, in words', () {
    test('rule codes, sign-in failures and a server out of reach', () {
      String say(Object error, {bool results = false}) => describeServerError(error, results: results).message;
      expect(say(const PostgrestException(message: 'college_not_found')), contains('No college has that college ID'));
      expect(say(const PostgrestException(message: 'request_open'), results: true), contains('reply to your request'));
      expect(
        describeServerError(const PostgrestException(message: 'not_seen'), results: true),
        isA<ResultsException>(),
      );
      expect(
        say(AuthApiException('Invalid login credentials', code: 'invalid_credentials')),
        'Wrong email, username or password.',
      );
      expect(say(AuthApiException('Database error saving new user')), contains('could not be created'));
      expect(
        say(AuthApiException('Email signups are disabled', code: 'email_provider_disabled')),
        contains('Turn on the Email provider'),
      );
      expect(
        say(AuthApiException('Email address "a@example.com" is invalid', code: 'email_address_invalid')),
        contains('name@college.ac.in'),
      );
      expect(say(const PostgrestException(message: 'x', code: 'PGRST202')), contains('setup.sql'));
      final AppException offline = describeServerError(const SocketException('no route'));
      expect(offline, isA<AccountException>().having((AccountException e) => e.offline, 'offline', isTrue));
      expect(say(http.ClientException('reset')), contains('Can’t reach your college server'));
    });
  });

  group('results on the server', () {
    final PublishedResult result = PublishedResult(
      id: 'local',
      rollNo: '21CS045',
      subjectCode: 'CCS356',
      exam: 'CAT 1',
      student: 'Priya',
      paperTitle: 'Biology',
      fileName: 'priya.pdf',
      publishedAt: DateTime.utc(2026, 9, 1),
      total: 3,
      maximum: 4,
      percentage: 75,
      questions: const <PublishedQuestion>[
        PublishedQuestion(questionId: 'Q1', number: '1', marks: 1, maximum: 2, explanation: 'Names ATP.'),
        PublishedQuestion(questionId: 'Q2', number: '2', marks: 2, maximum: 2, explanation: 'Full.'),
      ],
      sections: const <PublishedSection>[PublishedSection(title: 'Part A', marks: 3, maximum: 4)],
      pages: const <PublishedPage>[PublishedPage(number: 1, imagePath: '/tmp/page_1.png', width: 800, height: 1100)],
    );

    test('a result survives the trip to a row and back, with its pages in the cache', () {
      final Map<String, Object?> row = SupabaseResultsRepository.rowFor(result, collegeId: 'c1');
      expect(row['college_id'], 'c1');
      expect(row['roll_no'], '21CS045');
      expect((row['payload']! as Map<String, Object?>).containsKey('pages'), isFalse);
      final String object = SupabaseResultsRepository.objectFor(
        collegeId: 'c1',
        resultId: '7',
        page: result.pages.single,
      );
      expect(object, 'c1/7/page_1.png');

      final Map<String, dynamic> stored = <String, dynamic>{
        ...row,
        'id': 7,
        'updated_at': '2026-09-02T10:00:00Z',
        'pages': <Map<String, Object?>>[
          <String, Object?>{'number': 1, 'width': 800, 'height': 1100, 'object': object},
        ],
        'first_seen_at': '2026-09-03T08:00:00Z',
        'seen_count': 2,
        'verified_at': null,
      };
      final Directory cache = Directory('/cache');
      final PublishedResult back = SupabaseResultsRepository.resultFrom(stored, cache: cache);
      expect(back.id, '7');
      expect(back.rollNo, '21CS045');
      expect(back.total, 3);
      expect(back.questions.map((PublishedQuestion q) => q.questionId), <String>['Q1', 'Q2']);
      expect(back.sections.single.title, 'Part A');
      expect(back.isSeen, isTrue);
      expect(back.seenCount, 2);
      expect(back.isVerified, isFalse);
      expect(back.pages.single.imagePath, startsWith('/cache${Platform.pathSeparator}7${Platform.pathSeparator}'));
      expect(back.pages.single.imagePath, endsWith('page_1.png'));
      expect(sameMarks(result, back), isTrue);
    });

    test('requests and the teacher’s table read from their rows', () {
      final Map<String, dynamic> request = <String, dynamic>{
        'id': 3,
        'result_id': 7,
        'question_id': 'Q1',
        'number': '1',
        'roll_no': '21CS045',
        'student_name': 'Priya',
        'subject_code': 'CCS356',
        'exam': 'CAT 1',
        'message': 'Look again',
        'status': 'accepted',
        'reply': 'Agreed',
        'old_marks': 1,
        'new_marks': 2,
        'marks': 2,
        'maximum': 2,
        'explanation': 'Names ATP.',
        'created_at': '2026-09-03T08:00:00Z',
        'resolved_at': '2026-09-04T08:00:00Z',
      };
      final CorrectionRequest parsed = SupabaseResultsRepository.requestFrom(request);
      expect(parsed.id, 3);
      expect(parsed.resultId, '7');
      expect(parsed.questionNumber, '1');
      expect(parsed.status, RequestStatus.accepted);
      expect(parsed.oldMarks, 1);
      expect(parsed.newMarks, 2);
      expect(parsed.reply, 'Agreed');
      expect(parsed.resolvedAt, isNotNull);

      final Map<String, dynamic> overview = <String, dynamic>{
        'id': 7,
        'roll_no': '21CS045',
        'student_name': 'Priya',
        'subject_code': 'CCS356',
        'exam': 'CAT 1',
        'total': 3,
        'maximum': 4,
        'percentage': 75,
        'published_at': '2026-09-01T00:00:00Z',
        'seen_count': 0,
        'open_requests': 1,
        'accepted_requests': 0,
        'declined_requests': 2,
        'badges': 1,
      };
      final StudentStatus status = SupabaseResultsRepository.statusFrom(overview);
      expect(status.resultId, '7');
      expect(status.openRequests, 1);
      expect(status.declinedRequests, 2);
      expect(status.badges, 1);
    });
  });

  group('whose results the app is using', () {
    test('nothing active: calls that show things stay empty, calls that change things say why', () async {
      final SessionResults results = SessionResults();
      expect(await results.openRequestCount(), 0);
      expect(await results.requests(), isEmpty);
      expect(await results.subjects(), isEmpty);
      expect(await results.registeredRolls(), isNull);
      await expectLater(results.all(), throwsA(isA<ResultsException>()));

      final SqliteResultsRepository db = SqliteResultsRepository.inMemory();
      addTearDown(db.close);
      results.use(db);
      expect(await results.all(), isEmpty);
      expect(await results.registeredRolls(), isNull, reason: 'this computer does not know who signed up');
    });
  });
}
