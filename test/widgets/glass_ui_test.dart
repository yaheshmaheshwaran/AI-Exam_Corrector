import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/window_chrome.dart';
import 'package:exam_corrector/shared/ui/ui.dart';

import '../state/fakes.dart';

Widget _host(Widget child, {MediaQueryData media = const MediaQueryData()}) => MaterialApp(
      theme: AppTheme.light,
      home: MediaQuery(data: media, child: Scaffold(body: child)),
    );

void main() {
  group('rail', () {
    testWidgets('shows each place, which one is chosen, and a waiting count', (WidgetTester tester) async {
      String? tapped;
      await tester.pumpWidget(_host(AppRail(
        items: <Widget>[
          AppRailItem(icon: Icons.fact_check_outlined, label: 'Marking', selected: true, onPressed: () => tapped = 'marking'),
          AppRailItem(icon: Icons.rate_review_outlined, label: 'Requests', count: 3, onPressed: () => tapped = 'requests'),
        ],
        footer: <Widget>[
          AppRailItem(icon: Icons.settings_outlined, label: 'Settings', onPressed: () => tapped = 'settings'),
        ],
      )));

      expect(find.text('Marking'), findsOneWidget);
      expect(find.text('3'), findsOneWidget, reason: 'the badge');
      expect(tester.getSemantics(find.byType(AppRailItem).first), matchesSemantics(
        label: 'Marking',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ));

      await tester.tap(find.text('Requests'));
      expect(tapped, 'requests');
      await tester.tap(find.text('Settings'));
      expect(tapped, 'settings');
    });

    testWidgets('carries the logo at its head, in line with the bars and the sections', (WidgetTester tester) async {
      await tester.pumpWidget(_host(AppRail(
        items: <Widget>[
          AppRailItem(icon: Icons.fact_check_outlined, label: 'Marking', onPressed: () {}),
        ],
      )));

      final Finder logo = find.descendant(of: find.byType(AppRail), matching: find.byType(AppLogo));
      expect(logo, findsOneWidget);
      expect(find.byTooltip('Marklume'), findsOneWidget);
      // The glass starts level with the floating bars' top.
      expect(tester.getTopLeft(find.byType(Frosted)).dy, AppTheme.floatInset);
      final Rect mark = tester.getRect(logo);
      final double firstPlace = tester.getTopLeft(find.byType(AppRailItem)).dy;
      if (WindowChrome.integratedTitleBar) {
        // Under the window's buttons, level with the first section card.
        expect(mark.top, AppTheme.underBar);
      } else {
        // On the bars' centre line, with the places from the first card.
        expect(mark.center.dy, AppTheme.floatInset + AppTheme.barHeight / 2);
        expect(firstPlace, AppTheme.underBar);
      }
      expect(firstPlace, greaterThan(mark.bottom));
    });

    testWidgets('in full screen, with the window buttons hidden, the logo rises into the bars\' row',
        (WidgetTester tester) async {
      WindowChrome.buttonsShownForTesting = false;
      addTearDown(() => WindowChrome.buttonsShownForTesting = WindowChrome.integratedTitleBar);
      await tester.pumpWidget(_host(AppRail(
        items: <Widget>[
          AppRailItem(icon: Icons.fact_check_outlined, label: 'Marking', onPressed: () {}),
        ],
      )));

      final Rect mark = tester.getRect(find.descendant(of: find.byType(AppRail), matching: find.byType(AppLogo)));
      expect(tester.getTopLeft(find.byType(Frosted)).dy, AppTheme.floatInset);
      // Within the bars' row, on their centre line.
      expect(mark.top, greaterThanOrEqualTo(AppTheme.floatInset));
      expect(mark.bottom, lessThanOrEqualTo(AppTheme.floatInset + AppTheme.barHeight));
      expect(mark.center.dy, AppTheme.floatInset + AppTheme.barHeight / 2);
      // The places follow from the first section card.
      expect(tester.getTopLeft(find.byType(AppRailItem)).dy, AppTheme.underBar);
    });

    testWidgets('opens Students beside the rail, which stays and follows', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final SqliteResultsRepository results = SqliteResultsRepository.inMemory();
      addTearDown(results.close);
      await tester.pumpWidget(ExamCorrectorApp(controller: fakeController(results: results)));
      await tester.pumpAndSettle();

      bool chosen(String key) => tester.widget<AppRailItem>(find.byKey(Key(key))).selected;
      expect(chosen('open-marking'), isTrue);

      await tester.tap(find.byKey(const Key('open-students')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('export-students')), findsOneWidget);
      expect(find.byType(AppRail), findsOneWidget, reason: 'the rail stays beside it');
      expect(chosen('open-students'), isTrue);
      expect(chosen('open-marking'), isFalse);

      await tester.tap(find.byKey(const Key('open-marking')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('export-students')), findsNothing);
      expect(chosen('open-marking'), isTrue);
    });
  });

  testWidgets('a toolbar shows a way back and its actions', (WidgetTester tester) async {
    bool back = false;
    await tester.pumpWidget(_host(AppToolbar(
      title: 'Question 4',
      subtitle: 'Section A',
      onBack: () => back = true,
      backLabel: 'Results',
      actions: const <Widget>[Text('4 / 5')],
    )));

    expect(find.text('Question 4'), findsOneWidget);
    expect(find.text('Section A'), findsOneWidget);
    expect(find.text('4 / 5'), findsOneWidget);
    await tester.tap(find.byKey(const Key('toolbar-back')));
    expect(back, isTrue);
  });

  testWidgets('a segmented control reports the choice', (WidgetTester tester) async {
    String chosen = 'waiting';
    await tester.pumpWidget(_host(StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) => AppSegmented<String>(
        segments: const <({String value, String label, Key? key})>[
          (value: 'waiting', label: 'Waiting', key: null),
          (value: 'all', label: 'All', key: Key('segment-all')),
        ],
        selected: chosen,
        onChanged: (String value) => setState(() => chosen = value),
      ),
    )));

    await tester.tap(find.byKey(const Key('segment-all')));
    await tester.pumpAndSettle();
    expect(chosen, 'all');
  });

  group('raised buttons', () {
    /// How far the pill has moved from where it rests.
    Offset lift(WidgetTester tester) {
      final Matrix4 moved = tester
          .widget<Transform>(find.descendant(of: find.byType(FilledButton), matching: find.byType(Transform)).first)
          .transform;
      return Offset(moved.storage[12], moved.storage[13]);
    }

    testWidgets('press down when clicked', (WidgetTester tester) async {
      await tester.pumpWidget(_host(Center(child: FilledButton(onPressed: () {}, child: const Text('Mark all')))));
      expect(lift(tester), Offset.zero);

      final TestGesture press = await tester.startGesture(tester.getCenter(find.text('Mark all')));
      await tester.pump();
      expect(lift(tester).dy, greaterThan(0));
      await press.up();
      await tester.pump();
      expect(lift(tester), Offset.zero);
    });

    testWidgets('only change colour under reduced motion', (WidgetTester tester) async {
      await tester.pumpWidget(_host(
        Center(child: FilledButton(onPressed: () {}, child: const Text('Mark all'))),
        media: const MediaQueryData(disableAnimations: true),
      ));
      final TestGesture press = await tester.startGesture(tester.getCenter(find.text('Mark all')));
      await tester.pump();
      expect(lift(tester), Offset.zero);
      await press.up();
    });
  });

  testWidgets('the Warm mist is painted once, on its own layer', (WidgetTester tester) async {
    await tester.pumpWidget(ExamCorrectorApp(controller: fakeController()));
    final Finder mist = find.byKey(const Key('warm-mist'));
    expect(mist, findsOneWidget);
    expect(find.ancestor(of: mist, matching: find.byType(RepaintBoundary)), findsWidgets);
  });
}
