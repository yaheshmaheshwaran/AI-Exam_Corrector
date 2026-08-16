# Expected outcome

Marking `student_paper.pdf` against `mark_scheme.txt` (or `mark_scheme.pdf`)
should give **14 / 20 — 70%**. Each question is in the paper to exercise one
marking rule.

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
