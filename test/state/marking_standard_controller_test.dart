import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/screens/home/home_screen.dart';
import 'package:exam_corrector/services/review/marking_standard_store.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'fakes.dart';

void main() {
  late Directory dir;
  late MarkingStandardStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('standard');
    store = MarkingStandardStore(File('${dir.path}/marking-standards.json'));
  });
  tearDown(() async => dir.delete(recursive: true));

  Future<({CorrectionController controller, FakeMarker marker})> marked() async {
    final FakeMarker marker = FakeMarker();
    final CorrectionController controller =
        fakeController(marker: marker, standards: store, store: MemoryArtifactStore());
    await controller.chooseAnswerSheet();
    await controller.chooseQuestionPaper();
    await controller.startCorrection();
    return (controller: controller, marker: marker);
  }

  test('rounding and penalties apply at once, with no re-marking', () async {
    final (:CorrectionController controller, :FakeMarker marker) = await marked();
    marker.marked.clear();

    await controller.setMarkingStandard(
      controller.markingStandard.copyWith(totalRounding: TotalRounding.up, markStep: 1),
    );

    expect(marker.marked, isEmpty);
    expect(controller.hasPendingCorrections, isFalse);
    expect(controller.result!.totalRounding, TotalRounding.up);
    expect(controller.statusMessage, contains('no re-marking needed'));
  });

  test('a stricter level asks for re-marking, and says what it costs', () async {
    final (:CorrectionController controller, :FakeMarker marker) = await marked();

    await controller.setMarkingStandard(controller.markingStandard.copyWith(level: MarkingLevel.strict));

    expect(controller.hasPendingCorrections, isTrue);
    expect(controller.statusMessage, allOf(contains('re-mark to apply it'), contains('request')));

    // Kept for the paper.
    final CorrectionController reopened = fakeController(standards: store);
    await reopened.chooseAnswerSheet();
    await reopened.chooseQuestionPaper();
    expect(reopened.markingStandard.level, MarkingLevel.strict);
  });

  testWidgets('the guidance card offers the levels and the rules', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late CorrectionController controller;
    await tester.runAsync(() async {
      controller = fakeController(standards: store);
      await controller.chooseAnswerSheet();
      await controller.chooseQuestionPaper();
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: controller)));
    await tester.pump();

    expect(find.byKey(const Key('marking-level')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('marking-summary'))).data, 'Balanced · half marks · Firm');

    await tester.tap(find.byKey(const Key('marking-rules')));
    await tester.pumpAndSettle();
    expect(find.text('Marking standard'), findsWidgets);
    await tester.tap(find.descendant(of: find.byKey(const Key('dialog-level')), matching: find.text('Strict')));
    await tester.pumpAndSettle();
    expect(find.text('A missing or wrong unit loses the answer mark.'), findsOneWidget);
    expect(find.textContaining('need re-marking'), findsOneWidget);
  });
}
