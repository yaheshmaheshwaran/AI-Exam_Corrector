import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/ai/ai_settings.dart';
import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/ai/providers.dart';
import 'package:exam_corrector/ai/usage.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/features/marking_run/ui/model_usage_indicator.dart';

AiSettings _ai({String markers = 'gemini/flash, gemini/lite', String? key = 'k'}) => AiSettings.fromMap(<String, String>{
      Providers.geminiKeyName: ?key,
      ModelRole.marker.settingName: markers,
    });

void main() {
  Future<void> pump(WidgetTester tester, UsageMonitor usage, {AiSettings? ai}) => tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: ModelUsageIndicator(ai: ai ?? _ai(), usage: usage))),
      ));

  String text(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('model-usage-text'))).textSpan!.toPlainText();

  testWidgets('idle, working, waiting, then the backup marker, then out of allowance', (WidgetTester tester) async {
    DateTime now = DateTime(2026, 9, 26, 16);
    final UsageMonitor usage = UsageMonitor(clock: () => now, dailyAllowance: (String m) => m.startsWith('gemini/'));
    await pump(tester, usage);
    expect(text(tester), 'flash · 0 requests today');

    final ModelCall call = usage.started('gemini/flash', 'syllabus reading');
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
    expect(text(tester), 'flash out of allowance · using lite');

    usage.failed(usage.started('gemini/lite', 'marking'),
        const CorrectionException('out', quotaExhausted: true, dailyQuota: true));
    await tester.pump();
    expect(text(tester), startsWith('Out of allowance · back at '));

    await tester.tap(find.byKey(const Key('model-usage')));
    await tester.pumpAndSettle();
    expect(find.text('Model usage'), findsOneWidget);
    expect(find.textContaining('Out of allowance until'), findsNWidgets(2));
    expect(tester.widget<Text>(find.byKey(const ValueKey<String>('usage-requests-gemini/flash'))).data, '1');
    expect(find.textContaining('gemini/lite  (marking, backup)'), findsOneWidget);
  });

  test('the bar shortens a model name to the model itself', () {
    expect(ModelStatus.shortName('server/Qwen/Qwen3-VL-30B-A3B-Instruct-AWQ'), 'Qwen3-VL-30B');
    expect(ModelStatus.shortName('ollama/qwen3-vl:8b-instruct'), 'qwen3-vl:8b');
    expect(ModelStatus.shortName('nvidia/moonshotai/kimi-k3'), 'kimi-k3');
    expect(ModelStatus.shortName('gemini/gemini-3.6-flash'), 'gemini-3.6-flash');
  });

  testWidgets('the full name stays on hover', (WidgetTester tester) async {
    await pump(tester, UsageMonitor(), ai: _ai(markers: 'nvidia/moonshotai/kimi-k3'));
    expect(text(tester), startsWith('kimi-k3 · '));
    expect(find.byTooltip('nvidia/moonshotai/kimi-k3 is idle. 0 requests have been sent today.\nClick for model usage.'),
        findsOneWidget);
  });

  testWidgets('without a key it says so', (WidgetTester tester) async {
    await pump(tester, UsageMonitor(), ai: _ai(key: null));
    expect(text(tester), 'AI not set up');
  });
}
