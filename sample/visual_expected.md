# Expected outcome — visual sample

`visual_student_paper.pdf` (two scanned pages) marked against
`visual_question_paper.pdf` should score about **9 / 11**. Every answer is a
drawing, a table, a graph or working, so the sample exercises the parts of the
pipeline prose does not. Regenerate with
`ocr_service/.venv/bin/python ocr_service/tools/make_visual_sample.py`.

| Q | Max | Expected | What is on the page | What it tests |
| --- | --- | --- | --- | --- |
| 1 | 3 | 2 | An animal cell: membrane, nucleus, small organelles. Labels on pointer lines: "nucleus" ✓, "cytoplasm" ✓, and "cell wall" pointing at the membrane ✗ — animal cells have no wall. | A diagram judged from its image; labels beside the drawing belong to it. |
| 2 | 2 | 2 | A ruled table: "Temperature (°C)" / "Time (s)", rows 20/60, 30/40, 40/25. | A table read cell by cell. |
| 3 | 3 | 2 | Axes; x-axis ticks 20/30/40 and title "Temperature (°C)"; y-axis ticks 20/40/60 but **no y-axis label**; three points plotted as crosses and a curve. | A graph: axes, ticks, points, trend — and a missing label noticed. |
| 4 | 3 | 3 | `speed = distance / time`, a struck-out `= 150 x 12 = 1800`, then `= 150 / 12`, `= 12.5 m/s`. | Working as equations; the struck-out line kept out of the answer. |

Points worth checking:

- Question 1 loses its mark for "cell wall" — the evidence for that point should
  be the diagram region, and the inspector should show the three labels as
  children of the diagram.
- Question 4's struck-out line appears under *Crossed out*, not in the answer.
- Both pages contain graphics, so in the default hybrid mode both are analysed
  by the vision model; in `local` mode the regions come from local layout alone.
