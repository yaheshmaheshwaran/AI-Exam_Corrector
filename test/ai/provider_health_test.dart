import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/provider_health.dart';
import 'package:exam_corrector/ai/providers.dart';

void main() {
  final AiSettings settings = AiSettings.fromMap(const <String, String>{
    Providers.geminiKeyName: 'g',
    Providers.serverAddressName: 'http://gpu.local:8000/v1',
  });

  test('down, then up again when it answers', () {
    final ProviderHealth health = ProviderHealth();
    health.markDown('server', 'not reachable');
    expect(health.isDown('server'), isTrue);
    expect(health.downDescriptions(settings), <String>['GPU server: not reachable']);
    health.markUp('server');
    expect(health.isDown('server'), isFalse);
  });

  test("a recheck probes only our own servers that are down, and not too often", () async {
    DateTime now = DateTime(2026, 10, 6, 12);
    final List<String> probed = <String>[];
    final ProviderHealth health = ProviderHealth(
      clock: () => now,
      client: MockClient((http.Request request) async {
        probed.add(request.url.toString());
        return http.Response('{"data": []}', 200);
      }),
    );

    await health.recheck(settings);
    expect(probed, isEmpty, reason: 'nothing is down');

    health.markDown('server', 'not reachable');
    await health.recheck(settings);
    expect(probed, isEmpty, reason: 'it was just found down');

    now = now.add(const Duration(minutes: 2));
    await health.recheck(settings);
    expect(probed, <String>['http://gpu.local:8000/v1/models']);
    expect(health.isDown('server'), isFalse);
  });

  test('a probe that cannot connect leaves it down with a reason', () async {
    final ProviderHealth health = ProviderHealth(
      client: MockClient((http.Request request) async => throw const SocketException('refused')),
    );
    expect(await health.probe(settings.providers.byId('server')!), isFalse);
    expect(health.statusOf('server').reason, 'not reachable');
  });

  test('a status is described in a few words, never as a whole page', () {
    expect(ProviderHealth.describeStatus(530, '<html>…</html>'), contains('tunnel'));
    expect(ProviderHealth.describeStatus(500, '<html>…</html>'), 'it answered with an error page (500)');
    expect(ProviderHealth.describeStatus(400, '[{"error": {"message": "Bad model"}}]'), 'Bad model (400)');
  });
}
