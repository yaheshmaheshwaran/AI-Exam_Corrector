# Architecture

Marklume marks a student's handwritten answer script against a question
paper: it reads every page, finds each question's answer, and marks it with
evidence for every mark — then the teacher reviews.

Since October 2026 it is built around **one pipeline**, with one way to talk to
any AI model. The decision and the measurements behind it are in
[`docs/decisions/2026-10-06-one-pipeline.md`](docs/decisions/2026-10-06-one-pipeline.md).

## 1. Layers

```
lib/
  main.dart          wiring: settings → AI client → pipeline → controller → window
  ai/                one client for every model, and which model does each job
  marking/           the pipeline — plain Dart, no Flutter
  features/          the app's features: state (a mixin each) + their screens
  screens/           the app shell: home window and launch screen
  shared/ui/         the design system: cards, rail, dialogs, pills…
  app/               theme, colours, glass, the app widget
  domain/            the data everything shares: papers, pages, answers, evidence
  models/            results as the screens and exports show them
  services/          files, PDFs (text layer), settings, results database, accounts
  state/             the controller (the features put together), app session
  core/              errors, cancellation, formatting, app settings, .env
```

Two rules hold the layers apart:

- **`lib/ai` and `lib/marking` import no Flutter.** PDFium (the PDF engine) does
  not load under Flutter's test runner, and the tools run the pipeline with
  `dart run`. The screens watch plain-Dart state through
  `app/observable_listenable.dart`.
- **Screens never call the AI or the pipeline.** They talk to the controller;
  the controller runs the pipeline.

## 2. The pipeline (`lib/marking/`)

`MarkingPipeline` is the front door. The controller calls `readQuestionPaper`,
`alignTeacherKey`, `run` and `lastJob`; everything else is behind it.

```
once per exam   question paper → questions and marks · answer key (AI, or the teacher's)
every student   PDF → pages → read (whole pages) → answers matched to questions
                → answers cleaned → marked by one model → checked
```

| Stage (`ProcessingStage`) | Code | What it does | Measured, 14-page script |
|---|---|---|---|
| Reading the question paper | `exam/question_paper/` | A text PDF is parsed directly; a photo-PDF, or one the parser cannot trust, is read by the exam-prep model | 25–50 s, once per exam |
| Rendering pages | `script/pages.dart` | PDFium renders each page to a 200 dpi JPEG | 0.5 s (7 s first time) |
| Reading the pages | `script/page_reader.dart` | A vision model reads 3 whole pages per request, 3 requests at once: every block's place, type, the student's label, its lines, uncertain words, crossed-out writing, and diagrams as boxes and arrows | ~25 s, 5 requests |
| Matching answers to questions | `script/matching/` | The student's own labels (`17.`, `21. b)`) mark where each answer starts; stray numbers and the student's own lists are told apart; a mislabelled answer moves to the question it answers | < 1 s |
| Cleaning up the answers | `script/answer_cleaner.dart` | Each question's answer, page by page; crossed-out writing apart; doubtful lines flagged | < 1 s |
| Marking | `script/marker/`, `script/checks/` | One model marks the whole script against the answer key, citing evidence for every mark; then fixed rules: maximums, repeated points, "answer any two", the marking standard, moderation | ~290 s, 1 request |

**Every stage saves its result** in `StageStore` (`stage_store.dart`), under a
key built from everything it depends on — the document's hash, the model, the
prompt version, the teacher's corrections. So an unchanged script is never read
twice, a stopped run resumes at the stage it stopped in, and correcting one
reading re-marks only that question.

### Reading, in detail

The reader's prompt (`PageReader.systemPrompt`, versioned `page-reader:v4`)
holds what the tests found:

- **Examiner marks are not the student's work.** Ticks, slashes, scores in red
  or maroon are never transcribed, and the answer has no field a score could go
  in. `script/examiner_marks.dart` reports any line that still looks like one.
- **The student's spelling is kept.** A reader that "corrects" `recived` to
  `received` hides what the marker must judge (this ruled out gemini-3.5-flash).
- **Crossed-out writing** is its own block, with who struck it: the student
  (`student_line`, `scribble`), an examiner, or unsure. Only the student's
  crossing-out leaves the answer; anything unsure is kept and flagged, and the
  marker is told which line (`TextEvidenceItem.possiblyStruck`). A word the
  reader both kept and "crossed out" is an examiner's tick, and the strike is
  dropped.
- **Answer grids**: an option letter written in printed brackets (`[ b ]`) is
  part of the answer.

What the reader returns is mapped into the same `PageRegion`,
`HandwritingEvidence` and `VisualEvidence` the screens draw, so the page
inspector and the evidence on the page work as before. Drawings and doubtful
writing get a crop of their own ink, which is what the marker sees as images.

### Marking, in detail

- **One model marks a whole script.** The first model to mark any of it is the
  judge, and only it marks the rest (`ModelMarkingEngine`).
- **A backup marks only on request**: when the first-choice marker is out of
  its allowance, the controller runs the script again with `backup: true` —
  the marker list without its first — and every mark is flagged for review.
- **The answer key** is written once per paper, from the questions alone, and
  shared by every script. The teacher's own key, and their edits, win over it.
- `MarkingHook` (`hooks.dart`) is where something may add to what the marker is
  told, just before marking — the memory of the teacher's past corrections will
  go here. A hook may never remove anything, nor hand the marker a mark.

## 3. The AI layer (`lib/ai/`)

Every model is reached the same way: OpenAI-compatible chat completions,
streamed. A model's name says where it runs — `gemini/…`, `nvidia/…`,
`server/…` (a GPU server such as a Kaggle notebook), `ollama/…` — and
`providers.dart` holds each provider's address, key and limits.

| File | Holds |
|---|---|
| `llm_client.dart` | The one client: retries, model fallback, quota handling, time limits |
| `providers.dart` | Gemini, NVIDIA, GPU server, Ollama — address, key, timeouts |
| `model_roles.dart` | Which models do each job: `prep` (paper and key), `reader`, `marker` — first choice first |
| `ai_settings.dart` | Reads keys and roles from the environment, saved settings and `.env`; never fails |
| `usage.dart` | Requests per model per day, and models out of their allowance until they reset |
| `provider_health.dart` | Which of our own servers is down; checked again before each script |

What the client does with a failure:

| Failure | Behaviour |
|---|---|
| Per-minute limit (Gemini says when to retry) | Waits and retries the same model, up to 6 times |
| Daily allowance spent | Remembered until midnight Pacific; the next model is asked |
| Server busy or overloaded | Retried twice, then the next model |
| A hosted provider hangs (accepts, never answers) | Left for 10 minutes; the next model is asked at once |
| Our own server gone (Cloudflare 520–530, refused) | Marked down and skipped until it answers again |
| Answer cut off at the output limit | Reported as truncated; the caller asks for less at once |
| Not valid JSON | Asked once more |

## 4. Features (`lib/features/`)

The controller is the features put together:

```dart
class CorrectionController extends Workspace
    with InputsFeature, AnswerKeyFeature, SyllabusFeature, PublishingFeature,
         StandardFeature, ModerationFeature, MarkingRunFeature, ReviewFeature,
         ExportFeature, SettingsFeature
```

- `workspace.dart` holds what every feature shares — the services, the scripts
  and the paper, the run in progress, the status line — and **declares as
  abstract hooks what one feature asks of another** (`prepareSyllabus`,
  `loadTeacherKey`, `runScript`…). All the coupling between features is
  visible there.
- Each feature is a mixin in its own folder, with its own private state, and
  its screens and widgets beside it in `ui/`:

| Feature | State | Screens and widgets |
|---|---|---|
| `exam_setup/` | Choosing scripts and the paper, guidance, saved work, the answer key | answer key section and dialog, guidance input, PDF drop |
| `syllabus/` | Saved syllabi, the paper's syllabus | library dialog, section, badge |
| `marking_style/` | Marking standard, moderation | standard dialog, moderation chip |
| `marking_run/` | Single and class runs, background runs, backup hand-off, resume | processing panel, model usage indicator |
| `results/` | Teacher review, exports | results, class results, question detail, page viewer, page inspector |
| `accounts/` | Publishing, students' correction requests | account, college, requests, student and student-status screens |
| `settings/` | Saving settings, Test connection, clearing the cache | settings dialog |

## 5. Teacher review

- **Results**: one row per question — final mark, review state, confidence.
  The total counts the teacher's marks where they overrode, with the AI total
  beside it.
- **Question detail**: the student's answer region by region — the crop of the
  ink, the reading with uncertain words marked, crossed-out work apart — then
  the marking points with ✓/✗, evidence chips, reasoning and review reasons.
- **Evidence on the page**: every chip opens the page with that region outlined.
- **Corrections**: a reading can be corrected; the machine reading is kept, and
  re-marking re-marks only the affected question. Writing can be moved to
  another question.
- **Overrides**: accept, or set a mark with a comment — stored as a
  `TeacherReview` beside the AI's, never over it.
- **Page inspector** (developer mode): every region the reader found, with its
  type, order, confidence and question.
- **Export**: CSV, HTML and JSON, each with both marks for every question.

**Class sets**: choosing several scripts makes a class. Mark all runs them one
after another — reading the next while the current one is marked — skipping
those already marked. A script whose own marker ran out waits for it while the
class goes on; when every marker is out, every script is still read, and
marking resumes by itself when the allowance is back.

## 6. Errors

Every layer throws an `AppException` with a message written for a teacher.
A failure before marking stops the run and names the stage; a marking failure
keeps everything read and shows it, and marking again resumes there. Reading
settings never fails: a value that cannot be used is defaulted and reported.

## 7. Accounts and the college server

Who is using the app is decided in `AppSession` (`lib/state/app_session.dart`):
signed out, awaiting approval, closed, signed in, or offline (a teacher marking
without an account). Accounts sit behind `AccountRepository`;
`SupabaseAccountRepository` talks to the college's Supabase project, and
everything anyone may see or change is enforced on the server by
`supabase/setup.sql` (row level security, checked functions). Results keep one
interface, `ResultsRepository`: the college's results when signed in, the
SQLite database on this computer otherwise. Marks are only ever worked out in
Dart.

## 8. Tools and tests

| Tool | For |
|---|---|
| `dart run tool/mark_one_script.dart` | Mark one script end to end; prints every stage's time and the marks. `--reader`, `--marker`, `--prep` choose models; `--tag` marks again |
| `dart run tool/compare_examiner.dart <runs>` | Compare a run's marks with an examiner's, after marking. The examiner's marks never reach a model |
| `dart run tool/quota_probe.dart <models>` | One small request per model, through the app's own client |
| `dart run tool/provider_probe.dart [nvidia]` | What a provider accepts: models, images, JSON schema |
| `dart run tool/render_check.dart` | Render a PDF with PDFium and time it |

`flutter test` runs everything; `test/ai` and `test/marking` cover the AI layer
and the pipeline, including `marking_pipeline_test.dart` for caching, resume,
backup marking, teacher corrections and cancelling.

## 9. Packaging

PDF pages are rendered by PDFium, bundled by `pdfrx` (on macOS through
CocoaPods, which downloads the PDFium framework on the first build). Nothing
else is started beside the app. The Python service that used to render pages
and run TrOCR is archived in `~/Documents/marklume-archive/`.

## 10. Decisions

| Date | Decision | Why |
|---|---|---|
| 2026-10-06 | One pipeline; whole pages read by a vision model | Region-by-region reading took ~20 min a script and lost content between stages; whole pages take ~25 s |
| 2026-10-06 | Reader: gemini-3.1-flash-lite | Keeps the student's spelling and follows the prompt; 98% on handwritten exams in published tests |
| 2026-10-06 | Exam prep: Kimi K3 (NVIDIA), then GLM-5.3, then Gemini | Strongest free open models for writing a key; prep is a few requests an exam |
| 2026-10-06 | Marker: Gemini Flash, by test against an examiner | 20/23 questions within tolerance, consistent run to run; stricter than the examiner on long answers |
| 2026-10-06 | One OpenAI-compatible client | Five clients and a router collapsed into one; a provider is now a setting |
| 2026-10-06 | Features as mixins on a shared `Workspace` | A 2,300-line controller split by feature, with the coupling made explicit |
