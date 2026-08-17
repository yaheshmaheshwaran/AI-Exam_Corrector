// Generates the sample inputs in `sample/`: a student's completed exam paper
// as a PDF with a real text layer, and the matching mark scheme as both a PDF
// and plain text.
//
// Run with:  flutter test tool/make_sample_inputs.dart
//
// It is a test file only so that it can use `syncfusion_flutter_pdf`, which
// needs `dart:ui` and therefore cannot run under plain `dart run`. It asserts
// nothing about the application; it just writes files.
//
// The paper is written so that every marking rule in the prompt is exercised:
// full credit, partial credit, an accepted alternative wording, a method-mark
// calculation with a wrong final answer, an unanswered question, a fluent but
// wrong answer, a contradicted marking point, and an answer continued on a
// later page. See sample/expected_outcome.md.
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

const String _rule =
    '--------------------------------------------------------------------';

/// The student's script, one entry per printed page.
const List<String> _paperPages = <String>[
  '''
NORTHGATE ACADEMY
Year 10 Combined Science - Biology Paper 1
Cell Biology, Transport and Respiration

Candidate: A. Whitfield              Candidate number: 4172
Date: 12 June 2026                   Time allowed: 40 minutes
Total marks available: 20

Answer ALL questions in the space provided.

$_rule
1  Name the organelle that carries out aerobic respiration, and state
   the molecule it produces.                                [2 marks]

   Answer: The mitochondrion. It makes ATP.

$_rule
2 (a)  Write the word equation for aerobic respiration.     [1 mark]

   Answer: glucose + oxygen -> carbon dioxide + water

2 (b)  Explain why muscle cells contain a large number of
       mitochondria.                                        [2 marks]

   Answer: Because muscle cells need a lot of energy, especially when
   you are exercising.

$_rule
3  A cell is 50 micrometres long. In a drawing of the cell, the same
   cell measures 100 mm. Calculate the magnification of the drawing.
   Show your working.                                       [3 marks]

   Answer: 50 micrometres = 0.05 mm

           magnification = size of image / size of real object
                         = 100 / 0.05
                         = 200

           Magnification = x200
''',
  '''
$_rule
4  Describe two ways a root hair cell is adapted for taking up mineral
   ions from the soil.                                      [2 marks]

   Answer: It has a long thin extension that sticks out into the soil,
   which increases the surface area. It also has lots of mitochondria
   to provide the energy for taking minerals in by active uptake.

$_rule
5  State one function of the cell membrane.                 [1 mark]

   Answer:

$_rule
6  Describe how the structure of an alveolus makes it efficient for
   gas exchange.                                            [4 marks]

   Answer: The alveoli are extremely well designed for the job they do
   and they are one of the most impressive structures in the whole of
   the human body. There are millions of them in each lung, which
   gives the lungs a huge surface area for gases to pass across. Each
   alveolus is also surrounded by a thick layer of muscle which
   squeezes the oxygen into the blood so that it gets there quickly.
   Because the alveoli are kept moist, gases can dissolve first and
   then diffuse.

$_rule
7  Define osmosis.                                          [3 marks]

   Answer: Osmosis is when water moves from a dilute solution to a
   more concentrated solution.
''',
  '''
$_rule
8  Name the product of anaerobic respiration in human muscle cells and
   state one effect it has on the muscle.                   [2 marks]

   Answer: see extra answer space below.

$_rule
EXTRA ANSWER SPACE
Write the question number next to any answer continued here.

   Q8: Lactic acid is made. It builds up in the muscle and causes
       muscle fatigue, so the muscle stops contracting as well as it
       did before.

$_rule
END OF PAPER
''',
];

/// The question paper: the same exam with no answers on it.
///
/// This is the marking authority now — it is where the questions, the sections
/// and the marks come from. Divided into two sections of ten marks each so that
/// section-scoped guidance ("Section A: one mark each") has something real to
/// apply to.
const List<String> _questionPaperPages = <String>[
  '''
NORTHGATE ACADEMY
Year 10 Combined Science - Biology Paper 1
Cell Biology, Transport and Respiration

Time allowed: 40 minutes
Total marks available: 20

Answer ALL questions in the space provided.

$_rule
SECTION A - Short answer                                    [10 marks]
$_rule

1  Name the organelle that carries out aerobic respiration, and state
   the molecule it produces.                                [2 marks]

2 (a)  Write the word equation for aerobic respiration.     [1 mark]

2 (b)  Explain why muscle cells contain a large number of
       mitochondria.                                        [2 marks]

3  A cell is 50 micrometres long. In a drawing of the cell, the same
   cell measures 100 mm. Calculate the magnification of the drawing.
   Show your working.                                       [3 marks]

4  Describe two ways a root hair cell is adapted for taking up mineral
   ions from the soil.                                      [2 marks]
''',
  '''
$_rule
SECTION B - Extended answer                                 [10 marks]
$_rule

5  State one function of the cell membrane.                 [1 mark]

6  Describe how the structure of an alveolus makes it efficient for
   gas exchange.                                            [4 marks]

7  Define osmosis.                                          [3 marks]

8  Name the product of anaerobic respiration in human muscle cells and
   state one effect it has on the muscle.                   [2 marks]

$_rule
END OF PAPER
''',
];

/// The marking authority. Pasted into the application, or loaded from the
/// generated PDF.
const String _markScheme = '''
NORTHGATE ACADEMY
Year 10 Combined Science - Biology Paper 1
MARK SCHEME (total 20 marks)

GENERAL MARKING GUIDANCE
- Award one mark for each marking point that is met. A question's marks
  are the sum of its satisfied marking points and must never exceed the
  stated maximum.
- Accept any wording listed after "Accept"; the exact phrasing is not
  required.
- Do not award a marking point that the candidate contradicts elsewhere
  in the same answer.
- Ignore spelling errors where the intended term is unambiguous.
- Where no answer has been given, award 0 marks.

Question 1 (2 marks)
  1. Names the mitochondrion. Accept "mitochondria". (1 mark)
  2. States that ATP is produced. Accept "energy in the form of ATP".
     Do not accept "energy" on its own. (1 mark)

Question 2a (1 mark)
  1. glucose + oxygen -> carbon dioxide + water. Accept the reactants
     and the products in either order. Accept a correct symbol
     equation. (1 mark)

Question 2b (2 marks)
  1. Muscle cells have a high energy demand / contract frequently.
     (1 mark)
  2. Links that demand to aerobic respiration in the mitochondria
     releasing more ATP. (1 mark)
     Do not award point 2 for a general statement about needing
     energy; the answer must refer to respiration or to ATP release.

Question 3 (3 marks) - calculation, method marks apply
  1. Both measurements converted to the same unit, e.g. 50 micrometres
     given as 0.05 mm. (1 mark)
  2. Correct method shown: magnification = size of image / size of
     real object, with the candidate's own figures substituted.
     (1 mark)
  3. Correct answer: x2000. (1 mark)
  Partial credit: award marking points 1 and 2 for correct conversion
  and correct method even when the final value is wrong (error carried
  forward). Award point 3 only for x2000. A bare correct answer of
  x2000 with no working scores all 3 marks.

Question 4 (2 marks) - award any two of the following, maximum 2
  1. A long, thin extension increases the surface area for uptake.
     Accept "sticks out into the soil so there is a bigger surface
     area". (1 mark)
  2. Many mitochondria release the ATP needed for active transport of
     mineral ions. Accept "active uptake" for active transport, and
     accept "energy" here. (1 mark)
  3. Thin cell wall gives a short diffusion distance. (1 mark)

Question 5 (1 mark)
  1. Any one of: controls what enters and leaves the cell; acts as a
     partially permeable barrier; separates the cell contents from the
     surroundings. (1 mark)

Question 6 (4 marks)
  1. Large surface area, from the very large number of alveoli.
     (1 mark)
  2. The alveolus wall is one cell thick, giving a short diffusion
     path. (1 mark)
     Do not award this point where the candidate describes the wall as
     thick or muscular.
  3. A dense capillary network / good blood supply maintains the
     concentration gradient. (1 mark)
  4. The surface is moist, so gases dissolve before diffusing.
     (1 mark)

Question 7 (3 marks)
  1. The movement of water. Do not accept "movement of particles".
     (1 mark)
  2. From a dilute solution (high water potential) to a concentrated
     solution (low water potential). Accept the equivalent statement
     made in terms of solute concentration. (1 mark)
  3. Through a partially permeable membrane. Accept "semi-permeable".
     (1 mark)

Question 8 (2 marks)
  1. Lactic acid. (1 mark)
  2. Any one effect: muscle fatigue; the muscle stops contracting
     efficiently; pain or cramp. (1 mark)
  Answers continued in the extra answer space are marked in full.

TOTAL: 20 marks
''';

/// What a correct marking run should produce. Written beside the inputs so a
/// test run can be checked without re-deriving it.
const String _expectedOutcome = '''
# Expected outcome

Marking `student_paper.pdf` against `question_paper.pdf` should give
**14 / 20 — 70%**. Each question is in the paper to exercise one marking rule.

The marks come from the question paper and the judgement from the model, so no
mark scheme is supplied. `mark_scheme.txt` is kept alongside as the reference
for what a human marker would have written — it is what the expectations below
were derived from, not an input to the application.

| Q | Max | Expected | What it tests |
| --- | --- | --- | --- |
| 1 | 2 | 2 | A clean full-credit answer. |
| 2a | 1 | 1 | An equation accepted in either order. |
| 2b | 2 | 1 | Partial credit: "needs energy" earns point 1, but point 2 needs respiration or ATP, which the answer never mentions. |
| 3 | 3 | 2 | Method marks: the conversion and the method are right, the arithmetic (200 instead of 2000) is not. |
| 4 | 2 | 2 | Accepted alternatives: the candidate says "sticks out into the soil" and "active uptake", both listed under Accept. |
| 5 | 1 | 0 | Unanswered. Marks 0, and the student answer should read "No answer found". |
| 6 | 4 | 2 | Fluent but largely wrong. Surface area and the moist surface score; "thick layer of muscle" contradicts the one-cell-thick point, and no capillary network is described. |
| 7 | 3 | 2 | An incomplete definition: the partially permeable membrane is missing. |
| 8 | 2 | 2 | The answer lives in the extra answer space on page 3, not under the question. |

Points worth checking in the result:

- Question 5 scores zero with the wording "No answer found", rather than being
  skipped.
- Question 6 is not rewarded for reading well, and marking point 2 is shown as
  unsatisfied (contradicted) rather than satisfied.
- Question 3 shows two satisfied marking points and one unsatisfied, not a flat
  zero for a wrong final answer.
- The pinned total is 14/20 and 70%. The totals are recomputed locally, so a
  mismatch between the model's own total and this one appears as an adjustment
  warning above the result.
- Every question appears, in mark scheme order, including both parts of
  question 2.

Regenerate these files with:

```
flutter test tool/make_sample_inputs.dart
```
''';

Future<void> _writePdf(File file, List<String> pages) async {
  final PdfDocument document = PdfDocument();
  // Courier keeps the aligned working in question 3 aligned, and a standard
  // font needs no embedding, so the text layer extracts cleanly.
  final PdfFont font = PdfStandardFont(PdfFontFamily.courier, 10);

  for (final String content in pages) {
    final PdfPage page = document.pages.add();
    final Size size = page.getClientSize();
    PdfTextElement(text: content.trim(), font: font).draw(
      page: page,
      bounds: Rect.fromLTWH(0, 0, size.width, size.height),
      // Safety net: any block longer than a page flows onto a new one rather
      // than being clipped away.
      format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
    );
  }

  final List<int> bytes = await document.save();
  document.dispose();
  await file.writeAsBytes(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('writes the sample documents into sample/', () async {
    final Directory output = Directory('sample');
    await output.create(recursive: true);

    String path(String name) => '${output.path}${Platform.pathSeparator}$name';

    String joined(List<String> pages) =>
        pages.map((String page) => page.trim()).join('\n\n');

    await _writePdf(File(path('student_paper.pdf')), _paperPages);
    await _writePdf(File(path('question_paper.pdf')), _questionPaperPages);
    await _writePdf(File(path('mark_scheme.pdf')), <String>[_markScheme]);

    await File(path('question_paper.txt'))
        .writeAsString(joined(_questionPaperPages));
    await File(path('mark_scheme.txt')).writeAsString(_markScheme);
    await File(path('student_paper.txt')).writeAsString(joined(_paperPages));
    await File(path('expected_outcome.md')).writeAsString(_expectedOutcome);

    for (final String name in <String>[
      'student_paper.pdf',
      'question_paper.pdf',
      'mark_scheme.pdf',
      'question_paper.txt',
      'mark_scheme.txt',
      'student_paper.txt',
      'expected_outcome.md',
    ]) {
      expect(await File(path(name)).exists(), isTrue, reason: name);
      // ignore: avoid_print
      print('wrote ${path(name)}');
    }
  });
}
