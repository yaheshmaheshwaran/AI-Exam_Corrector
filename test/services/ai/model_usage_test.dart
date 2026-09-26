import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/ai/model_usage.dart';
import 'package:exam_corrector/widgets/model_usage_indicator.dart';

void main() {
  group('the quota day', () {
    test('resets at midnight Pacific time, daylight saving or not', () {
      // 26 Sep 2026, 16:00 IST = 10:30 UTC = 03:30 PDT.
      final DateTime summer = DateTime.utc(2026, 9, 26, 10, 30);
      expect(ModelUsageMonitor.nextQuotaReset(summer).toUtc(), DateTime.utc(2026, 9, 27, 7));
      expect(ModelUsageMonitor.quotaDay(summer), '2026-09-26');

      // 10 Jan 2026, 12:00 UTC = 04:00 PST.
      final DateTime winter = DateTime.utc(2026, 1, 10, 12);
      expect(ModelUsageMonitor.nextQuotaReset(winter).toUtc(), DateTime.utc(2026, 1, 11, 8));
      // 06:00 UTC is still the previous day in California.
      expect(ModelUsageMonitor.quotaDay(DateTime.utc(2026, 1, 10, 6)), '2026-01-09');
    });
  });

  group('the monitor', () {
    test('counts per model, starts afresh on a new provider day', () {
      DateTime now = DateTime.utc(2026, 9, 26, 10);
      final ModelUsageMonitor usage = ModelUsageMonitor(clock: () => now);
      final ModelCall call = usage.started('flash', 'marking');
      usage
        ..attempted(call)
        ..attempted(call)
        ..succeeded(call);
      expect(usage.today['flash']!.requests, 2);

      now = DateTime.utc(2026, 9, 27, 8); // After midnight Pacific.
      expect(usage.requestsToday, 0);
    });

    test('a spent daily quota lasts until the reset; an unstated one a few minutes', () {
      DateTime now = DateTime.utc(2026, 9, 26, 10);
      final ModelUsageMonitor usage = ModelUsageMonitor(clock: () => now);
      final ModelCall call = usage.started('flash', 'marking');
      usage.failed(call, const CorrectionException('out', quotaExhausted: true, dailyQuota: true));
      final ModelCall other = usage.started('lite', 'marking');
      usage.failed(other, const CorrectionException('out', quotaExhausted: true));

      expect(usage.exhaustedUntil('flash'), ModelUsageMonitor.nextQuotaReset(now));
      expect(usage.isExhausted('lite'), isTrue);
      now = now.add(const Duration(minutes: 6));
      expect(usage.isExhausted('lite'), isFalse);
      expect(usage.isExhausted('flash'), isTrue);

      // Any other failure is counted but does not block the model.
      final ModelCall third = usage.started('pro', 'marking');
      usage.failed(third, const CorrectionException('The API key was rejected.'));
      expect(usage.isExhausted('pro'), isFalse);
      expect(usage.today['pro']!.failures, 1);
    });

    test("today's counts and spent quotas survive a restart", () async {
      final Directory dir = await Directory.systemTemp.createTemp('usage');
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}/model-usage.json');
      final DateTime now = DateTime.now();

      final ModelUsageMonitor first = ModelUsageMonitor(file: file, clock: () => now);
      final ModelCall call = first.started('flash', 'marking');
      first
        ..attempted(call)
        ..failed(call, const CorrectionException('out', quotaExhausted: true, dailyQuota: true));
      await first.saved;

      final ModelUsageMonitor second = ModelUsageMonitor(file: file, clock: () => now);
      await second.load();
      expect(second.today['flash']!.requests, 1);
      expect(second.isExhausted('flash'), isTrue);
    });
  });

  group('the indicator', () {
    const AppConfig config = AppConfig(
      apiKey: 'k',
      model: 'flash',
      effort: 'low',
      maxTokens: 1000,
      fallbackModels: <String>['lite'],
    );

    Future<void> pump(WidgetTester tester, ModelUsageMonitor usage, {AppConfig with_ = config}) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(body: Center(child: ModelUsageIndicator(config: with_, usage: usage))),
        ));

    String text(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('model-usage-text'))).data!;

    testWidgets('idle, working, waiting, out of quota', (WidgetTester tester) async {
      DateTime now = DateTime(2026, 9, 26, 16);
      final ModelUsageMonitor usage = ModelUsageMonitor(clock: () => now);
      await pump(tester, usage);
      expect(text(tester), 'flash · 0 requests today');

      final ModelCall call = usage.started('flash', 'syllabus reading');
      usage.attempted(call);
      now = now.add(const Duration(seconds: 75));
      await tester.pump(const Duration(seconds: 1));
      expect(text(tester), 'AI: syllabus reading · 1m 15s');

      usage.waiting(call, const Duration(seconds: 30),
          const CorrectionException('Too many requests.', transient: true, retryAfter: Duration(seconds: 29)));
      await tester.pump(const Duration(seconds: 1));
      expect(text(tester), 'Rate limited · retrying in 30s');

      usage.failed(call, const CorrectionException('out', quotaExhausted: true, dailyQuota: true));
      await tester.pump();
      expect(text(tester), 'flash out of quota · using lite');

      final ModelCall second = usage.started('lite', 'marking');
      usage.failed(second, const CorrectionException('out', quotaExhausted: true, dailyQuota: true));
      await tester.pump();
      expect(text(tester), startsWith('Out of quota · back at'));

      await tester.tap(find.byKey(const Key('model-usage')));
      await tester.pumpAndSettle();
      expect(find.text('Model usage'), findsOneWidget);
      expect(find.textContaining('Out of quota until'), findsNWidgets(2));
      expect(tester.widget<Text>(find.byKey(const ValueKey<String>('usage-requests-flash'))).data, '1');
    });

    testWidgets('without a key it says so', (WidgetTester tester) async {
      await pump(tester, ModelUsageMonitor(),
          with_: const AppConfig(apiKey: null, model: 'flash', effort: 'low', maxTokens: 1000));
      expect(text(tester), 'No API key');
    });
  });
}
