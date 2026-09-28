import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/services/ui_sound.dart';
import 'package:exam_corrector/state/app_session.dart';

import '../state/fakes.dart';

void main() {
  const MethodChannel channel = MethodChannel('exam_corrector/sound');
  final List<String> played = <String>[];
  final Finder launch = find.byKey(const Key('launch-screen'));
  final Finder roles = find.byKey(const Key('sign-in-screen'));

  setUp(() {
    played.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall call) async {
        if (call.method == 'play') played.add(call.arguments as String);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> open(WidgetTester tester, {bool sounds = true}) async {
    await tester.runAsync(() async {
      await UiSound.instance.load(store: RecordingSettingsStore());
      await UiSound.instance.setEnabled(sounds);
      // The chime may have played in the test before; let its repeat guard pass.
      await Future<void>.delayed(UiSoundKind.welcome.gap);
    });
    await tester.pumpWidget(ExamCorrectorApp(controller: fakeController(), session: AppSession(), showLaunch: true));
  }

  testWidgets('plays over the first screen, chimes as the beam settles, then leaves', (WidgetTester tester) async {
    await open(tester);
    expect(launch, findsOneWidget);
    expect(roles, findsOneWidget, reason: 'the first screen is built underneath from the start');

    await tester.pump(const Duration(milliseconds: 800));
    expect(played, isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    expect(played, <String>['welcome']);

    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(launch, findsNothing);
    expect(roles, findsOneWidget);
    expect(played, <String>['welcome'], reason: 'it chimes once');
  });

  testWidgets('a click skips it, quietly', (WidgetTester tester) async {
    await open(tester);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(launch, findsNothing);
    expect(played, isEmpty);
  });

  testWidgets('a key skips it', (WidgetTester tester) async {
    await open(tester);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(launch, findsNothing);
  });

  testWidgets('with reduced motion it shows the finished logo briefly and still chimes', (WidgetTester tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await open(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(played, <String>['welcome']);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(launch, findsNothing);
  });

  testWidgets('with sounds off it is silent', (WidgetTester tester) async {
    await open(tester, sounds: false);
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pump();

    expect(launch, findsNothing);
    expect(played, isEmpty);
    await tester.runAsync(() => UiSound.instance.setEnabled(true));
  });
}
