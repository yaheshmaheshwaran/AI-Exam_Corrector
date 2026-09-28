import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/app/press_feedback.dart';
import 'package:exam_corrector/services/ui_sound.dart';

import '../state/fakes.dart';

void main() {
  const MethodChannel channel = MethodChannel('exam_corrector/sound');
  final List<String> played = <String>[];
  Object? loaded;

  setUp(() async {
    played.clear();
    loaded = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall call) async {
        if (call.method == 'load') loaded = call.arguments;
        if (call.method == 'play') played.add(call.arguments as String);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> pump(WidgetTester tester) {
    bool on = false;
    return tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) => Column(children: <Widget>[
            FilledButton(key: const Key('main'), onPressed: () {}, child: const Text('Correct paper')),
            OutlinedButton(key: const Key('secondary'), onPressed: () {}, child: const Text('Export…')),
            const FilledButton(key: Key('off'), onPressed: null, child: Text('Disabled')),
            ToggleRow(
              child: SwitchListTile(
                key: const Key('toggle'),
                value: on,
                onChanged: toggled((bool v) => setState(() => on = v)),
                title: const Text('Developer mode'),
              ),
            ),
          ]),
        ),
      ),
    ));
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('each kind of control has its own sound, played once', (WidgetTester tester) async {
    await tester.runAsync(() => UiSound.instance.load(store: RecordingSettingsStore()));
    expect((loaded! as Map<Object?, Object?>).keys, containsAll(<String>['tap', 'press', 'toggle', 'remove', 'done', 'problem', 'welcome']));

    await pump(tester);
    await tap(tester, 'main');
    await tap(tester, 'secondary');
    await tap(tester, 'off');
    await tap(tester, 'toggle');

    // The main action sounds fuller than a secondary one; a disabled button
    // is silent; a switch row plays its toggle and not a tap as well.
    expect(played, <String>['press', 'tap', 'toggle']);
  });

  testWidgets('turning sounds off silences them and is saved', (WidgetTester tester) async {
    final RecordingSettingsStore store = RecordingSettingsStore();
    await tester.runAsync(() => UiSound.instance.load(store: store));
    await tester.runAsync(() => UiSound.instance.setEnabled(false));
    expect(store.savedSounds, isFalse);

    await pump(tester);
    await tap(tester, 'main');
    expect(played, isEmpty);

    await tester.runAsync(() => UiSound.instance.setEnabled(true));
    expect(store.savedSounds, isTrue);
  });
}
