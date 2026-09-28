import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/widgets/ui/skeleton.dart';

void main() {
  Widget app({required bool still}) => MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: still),
          child: const Scaffold(body: SkeletonRows(count: 3, label: 'Starting to mark')),
        ),
      );

  testWidgets('a skeleton sweeps while content loads, and says so', (WidgetTester tester) async {
    await tester.pumpWidget(app(still: false));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    expect(find.bySemanticsLabel('Starting to mark'), findsOneWidget);
  });

  testWidgets('with reduce-motion on, the skeleton stays still', (WidgetTester tester) async {
    await tester.pumpWidget(app(still: true));
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byType(Bone), findsWidgets);
  });
}
