import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/services/settings_store.dart';
import 'package:exam_corrector/state/appearance.dart';
import 'package:exam_corrector/widgets/ui/frosted.dart';

import '../state/fakes.dart';

double _luminance(Color c) {
  double lin(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

double _contrast(Color a, Color b) {
  final double x = _luminance(a), y = _luminance(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// The glass colour laid over whatever is beneath it.
Color _over(Color tint, double alpha, Color under) => Color.lerp(under, tint, alpha)!;

void main() {
  Widget host({required double strength, MediaQueryData media = const MediaQueryData()}) => MaterialApp(
    theme: AppTheme.light,
    home: TransparencyScope(
      transparency: Transparency(store: RecordingSettingsStore())..value = strength,
      child: MediaQuery(
        data: media,
        child: const Scaffold(body: Frosted(top: true, child: Text('Correct paper'))),
      ),
    ),
  );

  /// The surface's own colour: the box around the content that carries one.
  Color glassColour(WidgetTester tester) => tester
      .widgetList<DecoratedBox>(find.ancestor(of: find.text('Correct paper'), matching: find.byType(DecoratedBox)))
      .map((DecoratedBox box) => (box.decoration as BoxDecoration).color)
      .whereType<Color>()
      .first;

  testWidgets('frosts when transparency is up, more clearly the higher it is', (WidgetTester tester) async {
    await tester.pumpWidget(host(strength: 0.3));
    expect(find.byType(BackdropFilter), findsOneWidget);
    final double faint = glassColour(tester).a;
    await tester.pumpWidget(host(strength: 1));
    final double clear = glassColour(tester).a;
    expect(clear, lessThan(faint));
    expect(clear, closeTo(Frosted.clearestLight, 0.01));
  });

  testWidgets('is solid when switched off, or the system asks for less motion or more contrast', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(strength: 0));
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.pumpWidget(host(strength: 1, media: const MediaQueryData(disableAnimations: true)));
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.pumpWidget(host(strength: 1, media: const MediaQueryData(highContrast: true)));
    expect(find.byType(BackdropFilter), findsNothing);
    // Solid means the surface's own colour, fully opaque.
    expect(glassColour(tester).a, 1);
  });

  test('text on glass stays readable over any blurred content beneath it', () {
    for (final (AppColors c, bool dark) in <(AppColors, bool)>[(AppColors.light, false), (AppColors.dark, true)]) {
      for (final (Color tint, bool tinted) in <(Color, bool)>[(c.surface, false), (c.primarySoft, true)]) {
        // Blurred content is at most half as dark (or light) as the
        // strongest colours the app draws, laid on the surface.
        for (final Color ink in <Color>[
          c.text,
          c.primary,
          c.success,
          c.warning,
          c.danger,
          c.bonus,
          c.bg,
          c.borderStrong,
          const Color(0xFF000000),
          const Color(0xFFFFFFFF),
        ]) {
          final Color under = Color.lerp(tint, ink, 0.5)!;
          final Color frost = _over(tint, Frosted.alphaFor(dark: dark, tinted: tinted, strength: 1), under);
          // With the sheen at its brightest, as it is along the top.
          final Color glass = Color.lerp(
            frost,
            const Color(0xFFFFFFFF),
            dark ? Frosted.sheenDark : Frosted.sheenLight,
          )!;
          expect(_contrast(c.text, glass), greaterThanOrEqualTo(7), reason: 'text over $under');
          expect(_contrast(c.textMuted, glass), greaterThanOrEqualTo(4.5), reason: 'secondary text over $under');
          expect(_contrast(c.primary, glass), greaterThanOrEqualTo(4.5), reason: 'accent over $under');
        }
      }
    }
  });

  test('reads the saved setting, including the on/off of earlier versions', () async {
    Future<double> loaded(String? saved) async {
      final Transparency t = Transparency(store: _Saved(saved));
      await t.load();
      return t.value;
    }

    expect(await loaded(null), Transparency.standard);
    expect(await loaded('true'), Transparency.standard);
    expect(await loaded('false'), 0);
    expect(await loaded('0.40'), 0.4);
    expect(await loaded('7'), 1);
    expect(await loaded('nonsense'), Transparency.standard);
  });

  testWidgets('the Settings slider changes glass at once, and Off is saved', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final RecordingSettingsStore store = RecordingSettingsStore();
    final Transparency transparency = Transparency(store: store);
    await tester.pumpWidget(ExamCorrectorApp(controller: fakeController(), transparency: transparency));
    expect(find.byType(BackdropFilter), findsWidgets);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-transparency-value')), findsOneWidget);
    expect(find.text('80%'), findsWidgets);

    // Drag the slider all the way to Off.
    await tester.drag(find.byKey(const Key('settings-transparency')), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(transparency.value, 0);
    expect(store.savedTransparency, 0);
    expect(find.text('Off'), findsWidgets);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
  });
}

class _Saved extends SettingsStore {
  const _Saved(this.value);

  final String? value;

  @override
  Future<Map<String, String>> read() async => <String, String>{
    if (value case final String v) SettingsStore.transparencyField: v,
  };
}
