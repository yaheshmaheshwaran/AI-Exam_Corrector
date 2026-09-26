import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/moderation.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/widgets/answer_key_dialog.dart';
import 'package:exam_corrector/widgets/marking_standard_dialog.dart';
import 'package:exam_corrector/widgets/moderation_chip.dart';

void big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> opener(WidgetTester tester, Future<void> Function(BuildContext context) open) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (BuildContext context) => TextButton(onPressed: () => open(context), child: const Text('open')),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the rules dialog turns each realistic-marking check on and off', (WidgetTester tester) async {
    big(tester);
    ({MarkingStandard standard, bool asDefault})? chosen;
    await opener(tester, (BuildContext context) async {
      chosen = await MarkingStandardDialog.show(context, const MarkingStandard());
    });

    expect(find.text('Realistic marking'), findsOneWidget);
    expect(find.textContaining('Weak 30%'), findsWidgets);
    await tester.ensureVisible(find.byKey(const Key('realism-length')));
    await tester.tap(find.byKey(const Key('realism-length')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('realism-words')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('realism-full-marks')));
    await tester.tap(find.byKey(const Key('realism-full-marks')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('dialog-apply')));
    await tester.pumpAndSettle();
    expect(chosen!.standard.realism.lengthCap, isFalse);
    expect(chosen!.standard.realism.fullMarksGate, isFalse);
    expect(chosen!.standard.realism.bandCap, isTrue);
    expect(chosen!.standard.realism.strictness, RealismStrictness.firm);
  });

  testWidgets('strictness is chosen in the rules dialog, with what it changes', (WidgetTester tester) async {
    big(tester);
    ({MarkingStandard standard, bool asDefault})? chosen;
    await opener(tester, (BuildContext context) async {
      chosen = await MarkingStandardDialog.show(context, const MarkingStandard());
    });
    expect(find.text('An incomplete full mark loses a step — a whole mark on a long question.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('realism-strictness')));
    await tester.tap(find.descendant(of: find.byKey(const Key('realism-strictness')), matching: find.text('Tough')));
    await tester.pumpAndSettle();
    expect(find.text('Always down.'), findsOneWidget);
    expect(find.textContaining('earns nothing.'), findsWidgets);
    await tester.tap(find.byKey(const Key('dialog-apply')));
    await tester.pumpAndSettle();
    expect(chosen!.standard.realism.strictness, RealismStrictness.tough);
    expect(chosen!.standard.changesJudgement, isFalse);
  });

  testWidgets('the answer key dialog shows the key, takes corrections, and resets them', (WidgetTester tester) async {
    big(tester);
    final QuestionPaper paper = QuestionPaper(
      documentId: 'p',
      questions: <Question>[
        Question(label: QuestionLabel.parse('11')!, questionText: 'Explain MQTT.', maximumMarks: 13, marksStated: true),
        Question(label: QuestionLabel.parse('12')!, questionText: 'Explain CoAP.', maximumMarks: 13, marksStated: true),
      ],
    );
    const AnswerKey key = AnswerKey(entries: <String, AnswerKeyEntry>{
      'Q11': AnswerKeyEntry(questionId: 'Q11', maximum: 13, expectedWords: 300, points: <AnswerKeyPoint>[
        AnswerKeyPoint(criterion: 'Publish–subscribe', marks: 13),
      ]),
    });
    Map<String, String>? saved;
    await opener(tester, (BuildContext context) async {
      saved = await AnswerKeyDialog.show(context, paper: paper, key: key);
    });

    expect(find.textContaining('Publish–subscribe [13]'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey<String>('answer-key-Q11')), matching: find.textContaining('about 300 words')),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const ValueKey<String>('answer-key-Q11')), 'My own key [13]');
    await tester.pump();
    expect(find.text('Your key — used in place of the AI’s.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('answer-key-reset-Q11')));
    await tester.pump();
    expect(find.textContaining('Publish–subscribe [13]'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey<String>('answer-key-Q12')), 'CoAP over UDP [13]');

    await tester.tap(find.byKey(const Key('answer-key-save')));
    await tester.pumpAndSettle();
    expect(saved!['Q12'], 'CoAP over UDP [13]');
    expect(saved!['Q11'], key.textFor('Q11'));
  });

  testWidgets('moderation: waiting, ready, in force', (WidgetTester tester) async {
    int applied = 0;
    int removed = 0;
    Future<void> show(Moderation active, Moderation? suggested, int samples) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: ModerationChip(
              applied: active,
              suggested: suggested,
              samples: samples,
              onApply: () => applied++,
              onRemove: () => removed++,
            ),
          ),
        ));
    const Moderation half = Moderation(shortFactor: 0.5, longFactor: 0.5, questions: 6, scripts: 3);

    await show(Moderation.none, null, 2);
    expect(find.text('Moderation: 2 of 6 questions marked'), findsOneWidget);

    await show(Moderation.none, half, 6);
    await tester.tap(find.byKey(const Key('moderation-apply')));
    expect(applied, 1);
    expect(find.text('Moderate to your marking (× 0.50)'), findsOneWidget);

    await show(half, half, 6);
    expect(find.text('Moderated × 0.50'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove moderation'));
    expect(removed, 1);
  });
}
