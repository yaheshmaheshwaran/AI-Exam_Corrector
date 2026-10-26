# Decision: one clean pipeline (Marklume v2)

Status: **accepted and implemented** (2026-10-06), on branch `rewrite/one-pipeline`.
This is the proposal as approved; how the code stands now is in
[`ARCHITECTURE.md`](../../ARCHITECTURE.md). Where tests changed a choice made
here, the change is recorded in that file's Decisions table.
Backup of the old project: `~/Documents/exam-corrector-backup-2026-10-06`.

## Goal

Mark **one student's whole answer script** (a PDF of about 15 pages) as fast as
possible, at the best accuracy we can get, using free resources only.
Two or three scripts a day later, only if needed.

## Rules for all work on v2

1. **One pipeline.** Each stage has one job, one interface and one implementation.
   A second implementation exists only as a named backup (for example, Kaggle reading when Gemini is busy).
2. **No parallel experiments in the app.** Experiments live in `~/Documents/marklume-vision-lab`.
   A result moves into the app only after it wins a test.
3. **Losing code is deleted, not hidden behind a setting.** Git and the backup keep the history.
4. **New features fit into an existing stage or feature folder.** Nothing is added as a side route.
5. **Every stage saves its result**, so a stopped run continues from the last finished stage.

## Models (accepted 2026-10-06)

| Job | Model | Backup |
|---|---|---|
| Read the question paper, write the answer key, read the teacher's key | Kimi K3 (NVIDIA NIM, free) | GLM-5.3 (NIM), then Gemini |
| Read the student's pages (handwriting, diagrams, equations) | Gemini Flash-Lite or Flash, chosen by test | Qwen3-VL-8B on Kaggle |
| Mark against the key | Gemini Flash or Kimi K3, chosen by test against the examiner's marks | the other one |

Each provider is only a setting: an address, a key and a model name. Every provider uses
the same OpenAI-compatible connection: Gemini, NVIDIA NIM, Kaggle vLLM and Ollama.

## Folder layout

```
lib/
  main.dart
  app/                     theme, colours, app shell                      (kept)
  core/                    errors, cancellation, formatting, settings     (config split by feature)
  domain/                  data shared by everything: paper, answers,     (kept, trimmed)
                           pages, marks
  ai/                      ONE way to talk to any model
    llm_client.dart          text + images in, text or JSON out, retries, timeouts
    providers.dart           Gemini, NVIDIA NIM, Kaggle (vLLM), Ollama
    model_roles.dart         which model does which job, and its backup
    usage.dart               daily limits and what is used
  marking/                 THE pipeline (replaces lib/pipeline)
    marking_pipeline.dart    front door used by the app: readQuestionPaper,
                             matchTeacherKey, run, lastJob
    stage_store.dart         saves each stage's result; resume after a stop
    exam/                    once per exam
      question_paper_reader.dart
      answer_key_writer.dart
      teacher_key_reader.dart
    script/                  every student, in this order
      pages.dart               1  PDF → page images
      page_reader.dart         3  pages → lines, diagrams, equations, positions
      answer_matcher.dart      4  student's labels → questions
      answer_cleaner.dart      5  crossed-out lines, equations, doubtful words
      marker.dart              6  one model marks the whole script
      mark_checker.dart        7  maximums, repeated points, "answer any two"
    hooks.dart               extra context before marking: syllabus and
                             marking standard now, memory layer later
  features/                each feature owns its state, screens and widgets
    exam_setup/              question paper, answer key, syllabus choice
    marking_run/             one script or a class, background runs
    results/                 results, question detail, teacher review, page inspector
    syllabus/                syllabus library
    marking_style/           marking standard + moderation
    accounts/                sign-in, college, requests, publishing to students
    settings/                models, keys, Kaggle address
  shared/ui/               common widgets (cards, rail, dialogs, pills)
```

Stage 2 from the workflow page (finding the parts of a page with doctr/OpenCV) is **not in
this layout**. Gemini reads whole pages and reports where each line is. The stage 1 test
confirms this. If doctr turns out to be needed, it comes back as one file in `script/`.

## Features: where each one goes

| Feature | v2 home | How it connects |
|---|---|---|
| Syllabus library | `features/syllabus/` | Feeds context to the answer key writer and the marker through `hooks.dart` |
| Marking standard | `features/marking_style/` | Feeds the marker through `hooks.dart` |
| Moderation | `features/marking_style/` | Adjusts marks after `mark_checker`, shown in results |
| Page inspector | `features/results/` | Shows the pages with what the reader found on each |
| Class runs, background | `features/marking_run/` | Calls the pipeline once per script |
| Accounts, college, requests, publishing | `features/accounts/` | Unchanged behaviour, own state instead of the shared controller |

`state/correction_controller.dart` (2,314 lines that run every feature) is split into one
small controller per feature folder.

## Deleted

| What | Why |
|---|---|
| `lib/pipeline/` (6 region detectors, TrOCR, ensemble and vision readers, visual evidence engine, reconstructor, old alignment and marking wiring) | Replaced by `lib/marking/` |
| Old AI clients (`gemini_client`, `gemini_model_client`, `open_model_client`, `routing_model_client`, `model_client`) | Replaced by `lib/ai/` |
| `legacy_python/` | Not used |
| Tests of deleted code | Replaced by one test file per new stage |

Carried over (rewritten into the new files): answer matching with the 2026-10-04 fixes,
the crossed-out-line rule, mark validator and rules, choice questions, question tree,
equation cleanup, teacher key parser, report export.

## Python service

`ocr_service/` (doctr, OpenCV, TrOCR; about 2 GB with its environment and package) moves out
of the project once the app renders PDF pages itself:

```
~/Documents/marklume-archive/
  python-ocr-service-doctr-trocr/   README.md: what it does, why it left, how to run it
  legacy-python-app/                README.md
```

It stays available for lab tests. The app no longer starts it.

## Build order

1. `lib/ai/` with tests: one client and the four providers.
2. `tool/mark_one_script.dart`: marks one PDF end to end from the command line and prints the time for each stage.
   This is the stage 1 test: Gemini Flash-Lite vs Flash vs Kaggle for reading, and Gemini vs Kimi K3 for marking.
3. The rest of `lib/marking/` with tests per stage, using the winners.
4. Connect the app to the new front door; split the controller into `features/`.
5. Delete the old code, move the Python service to the archive, update `ARCHITECTURE.md` and `README.md`.

## Done when

- One real student PDF is read and marked in the app, with stage times shown.
- Marks are compared with the examiner's marks for that script.
- Nothing in `lib/` refers to the old pipeline, and all tests pass.
