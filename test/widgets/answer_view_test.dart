import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/widgets/answer_view.dart';
import 'package:exam_corrector/widgets/page_viewer.dart';

void main() {
  late Directory dir;
  late List<PublishedPage> pages;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pages');
    final List<int> png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    pages = <PublishedPage>[
      for (int n = 1; n <= 3; n++)
        PublishedPage(
          number: n,
          imagePath: (File('${dir.path}/page_$n.png')..writeAsBytesSync(png)).path,
          width: 1000,
          height: 1400,
        ),
    ];
  });
  tearDown(() async => dir.delete(recursive: true));

  const PublishedQuestion question = PublishedQuestion(
    questionId: 'Q3',
    number: '3',
    marks: 2,
    maximum: 5,
    questionText: 'Calculate the magnification.',
    answerText: '100 / 0.05 = 2000',
    answerBoxes: <AnswerBox>[
      AnswerBox(page: 2, x: 0.1, y: 0.1, width: 0.8, height: 0.2),
      AnswerBox(page: 3, x: 0.1, y: 0.0, width: 0.8, height: 0.1),
    ],
  );

  testWidgets('a question shows what was asked, what was read, and its pages outlined', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: QuestionAnswerView(question: question, pages: pages, pageHeight: 200))),
    ));
    await tester.pump();

    expect(find.text('Calculate the magnification.'), findsOneWidget);
    expect(find.text('100 / 0.05 = 2000'), findsOneWidget);
    expect(find.text('Written on pages 2, 3 — outlined, click to enlarge'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('answer-page-Q3-2')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('answer-page-Q3-1')), findsNothing);
    final PageViewer viewer = tester.widget<PageViewer>(find.byType(PageViewer).first);
    expect(viewer.highlightBoxes.single.y, 0.1);
  });

  testWidgets('the whole answer sheet lists every page', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AnswerSheetView(pages: pages))));
    await tester.pump();
    expect(find.text('Page 1 of 3'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('sheet-page-3')), findsOneWidget);
  });

  testWidgets('a result published before pages were kept says so', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AnswerSheetView(pages: <PublishedPage>[]))));
    expect(find.byKey(const Key('sheet-not-kept')), findsOneWidget);
  });
}
