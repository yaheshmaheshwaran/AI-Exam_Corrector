import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/widgets/guidance_input.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    ({int withScheme, int questions})? paperScheme,
  }) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GuidanceInput(
              controller: TextEditingController(),
              onChanged: (_) {},
              onClear: null,
              paperScheme: paperScheme,
            ),
          ),
        ),
      );

  testWidgets('says when the question paper carries its own mark scheme',
      (WidgetTester tester) async {
    await pump(tester, paperScheme: (withScheme: 9, questions: 9));
    expect(
      find.textContaining('includes a mark scheme for every question'),
      findsOneWidget,
    );

    await pump(tester, paperScheme: (withScheme: 3, questions: 9));
    expect(find.textContaining('for 3 of 9 questions'), findsOneWidget);
  });

  testWidgets('says nothing about a scheme the paper does not print',
      (WidgetTester tester) async {
    await pump(tester);
    expect(find.textContaining('includes a mark scheme'), findsNothing);
  });
}
