import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';

bool _gemini(String model) => model.startsWith('gemini/');

void main() {
  test('the quota day resets at midnight Pacific time, daylight saving or not', () {
    // 26 Sep 2026, 16:00 IST = 10:30 UTC = 03:30 PDT.
    final DateTime summer = DateTime.utc(2026, 9, 26, 10, 30);
    expect(UsageMonitor.nextQuotaReset(summer).toUtc(), DateTime.utc(2026, 9, 27, 7));
    expect(UsageMonitor.quotaDay(summer), '2026-09-26');

    // 10 Jan 2026, 12:00 UTC = 04:00 PST.
    final DateTime winter = DateTime.utc(2026, 1, 10, 12);
    expect(UsageMonitor.nextQuotaReset(winter).toUtc(), DateTime.utc(2026, 1, 11, 8));
    expect(UsageMonitor.quotaDay(DateTime.utc(2026, 1, 10, 6)), '2026-01-09');
  });

  test('counts per model and starts afresh on a new provider day', () {
    DateTime now = DateTime.utc(2026, 9, 26, 10);
    final UsageMonitor usage = UsageMonitor(clock: () => now);
    final ModelCall call = usage.started('gemini/flash', 'marking');
    usage
      ..attempted(call)
      ..attempted(call)
      ..succeeded(call);
    expect(usage.today['gemini/flash']!.requests, 2);

    now = DateTime.utc(2026, 9, 27, 8); // After midnight Pacific.
    expect(usage.requestsToday, 0);
  });

  test('a spent daily allowance lasts until the reset; an unstated one a few minutes', () {
    DateTime now = DateTime.utc(2026, 9, 26, 10);
    final UsageMonitor usage = UsageMonitor(clock: () => now, dailyAllowance: _gemini);
    usage.failed(usage.started('gemini/flash', 'marking'),
        const CorrectionException('out', quotaExhausted: true, dailyQuota: true));
    usage.failed(usage.started('gemini/lite', 'marking'), const CorrectionException('out', quotaExhausted: true));

    expect(usage.exhaustedUntil('gemini/flash'), UsageMonitor.nextQuotaReset(now));
    expect(usage.isExhausted('gemini/lite'), isTrue);
    now = now.add(const Duration(minutes: 6));
    expect(usage.isExhausted('gemini/lite'), isFalse);
    expect(usage.isExhausted('gemini/flash'), isTrue);

    // Any other failure is counted but does not block the model.
    usage.failed(usage.started('gemini/pro', 'marking'), const CorrectionException('The key was rejected.'));
    expect(usage.isExhausted('gemini/pro'), isFalse);
    expect(usage.today['gemini/pro']!.failures, 1);
  });

  test('a new key forgets only its own provider\'s spent allowances', () {
    final DateTime now = DateTime.utc(2026, 9, 26, 10);
    final UsageMonitor usage = UsageMonitor(clock: () => now, dailyAllowance: (String model) => true);
    const CorrectionException spent = CorrectionException('out', quotaExhausted: true, dailyQuota: true);
    usage.failed(usage.started('gemini/flash', 'marking'), spent);
    usage.failed(usage.started('nvidia/kimi', 'marking'), spent);

    usage.keyChanged('gemini');

    expect(usage.isExhausted('gemini/flash'), isFalse);
    expect(usage.today['gemini/flash']!.quotaRefusals, 0);
    expect(usage.today['gemini/flash']!.failures, 1, reason: 'what happened today is still shown');
    expect(usage.isExhausted('nvidia/kimi'), isTrue);
  });

  test('a second unstated refusal the same day lasts until the reset', () {
    DateTime now = DateTime.utc(2026, 9, 26, 10);
    final UsageMonitor usage = UsageMonitor(clock: () => now, dailyAllowance: _gemini);
    const CorrectionException out = CorrectionException('out', quotaExhausted: true, quotaLimit: 20);

    usage.failed(usage.started('gemini/flash', 'marking'), out);
    expect(usage.exhaustedUntil('gemini/flash'), now.add(const Duration(minutes: 5)));

    now = now.add(const Duration(minutes: 6));
    usage.modelFailed(usage.started('gemini/flash', 'marking'), 'gemini/flash', out);
    expect(usage.exhaustedUntil('gemini/flash'), UsageMonitor.nextQuotaReset(now));
    expect(usage.today['gemini/flash']!.limit, 20);
    expect(usage.today['gemini/flash']!.quotaRefusals, 2);
  });

  test('a provider without a daily allowance is only rested a while', () {
    final DateTime now = DateTime.utc(2026, 9, 26, 10);
    final UsageMonitor usage = UsageMonitor(clock: () => now, dailyAllowance: _gemini);
    usage.failed(usage.started('server/qwen', 'reading'),
        const CorrectionException('out', quotaExhausted: true, dailyQuota: true));
    expect(usage.exhaustedUntil('server/qwen'), now.add(const Duration(minutes: 5)));
  });

  test("today's counts and spent allowances survive a restart", () async {
    final Directory dir = await Directory.systemTemp.createTemp('usage');
    addTearDown(() => dir.delete(recursive: true));
    final File file = File('${dir.path}/ai-usage.json');
    final DateTime now = DateTime.now();

    final UsageMonitor first = UsageMonitor(file: file, clock: () => now, dailyAllowance: _gemini);
    final ModelCall call = first.started('gemini/flash', 'marking');
    first
      ..attempted(call)
      ..failed(call, const CorrectionException('out', quotaExhausted: true, dailyQuota: true));
    await first.saved;

    final UsageMonitor second = UsageMonitor(file: file, clock: () => now);
    await second.load();
    expect(second.today['gemini/flash']!.requests, 1);
    expect(second.isExhausted('gemini/flash'), isTrue);
  });

  test('listeners hear every change', () {
    final UsageMonitor usage = UsageMonitor();
    int heard = 0;
    void listener() => heard++;
    usage.addListener(listener);
    final ModelCall call = usage.started('gemini/flash', 'marking');
    usage.succeeded(call);
    usage.removeListener(listener);
    usage.started('gemini/flash', 'marking');
    expect(heard, 2);
  });
}
