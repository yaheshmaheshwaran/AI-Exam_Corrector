# Marklume

A Flutter **Windows desktop** application that understands a student's
handwritten exam script — its answers, diagrams, graphs, tables and equations —
and marks it against the question paper it was sat from, showing the evidence
for every mark and letting the teacher review and override each one.

## Workflow

```
Upload answer sheet + question paper (+ optional marking guidance) → Correct
→ Question paper read: sections, questions, parts, marks
→ Answer sheet rendered page by page; blank pages skipped
→ Each page divided into regions: answers, question numbers, diagrams,
  graphs, tables, equations, crossed-out work, margin notes
→ Handwriting read region by region, with uncertainty kept
→ Answers found from label to label, across regions and pages,
  and matched to the paper's questions
→ Diagrams, graphs, tables and equations analysed from their images
→ Each question's complete answer reconstructed from its evidence
→ Marked from text and images together, every mark citing its evidence
→ Teacher reviews, corrects, overrides, exports
```

The design is described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- Flutter 3.41 or later with the Windows desktop target enabled
- Visual Studio with the “Desktop development with C++” workload
- A Google Gemini API key ([AI Studio](https://aistudio.google.com/apikey))

## Setup

```bat
flutter config --enable-windows-desktop
flutter pub get
```

### The API key

The simplest way is to run the application and use **Settings** — the key is
saved to your Windows user profile at
`%APPDATA%\Exam Corrector\settings.json`, so a packaged build needs no
environment setup at all.

Two other sources work, in this order of precedence:

| Source | Use it when |
| --- | --- |
| `GEMINI_API_KEY` environment variable (`setx GEMINI_API_KEY "..."`) | A shared or managed machine; it overrides everything else. |
| **Settings** in the application | Normal use. Saved per Windows user. |
| `.env` beside the executable, or at the project root while developing | Development, or shipping a preconfigured folder. Copy `.env.example` to `.env`. |

The key is never hard-coded, and `.env` is git-ignored.

### The college server (accounts and published results)

Accounts, colleges and the results students see live on a
[Supabase](https://supabase.com) project the college owns. Without one, a
teacher can still mark on their own computer ("Mark without an account").

1. **Create the project.** Sign up at supabase.com, then *New project* (the free
   tier is enough to start). Pick a region near the college.
2. **Set it up for Marklume.** In the dashboard open *SQL Editor → New query*,
   paste the whole of [`supabase/setup.sql`](supabase/setup.sql) and press
   *Run*. It creates the tables, the rules that decide who can see what, the
   sign-up checks and the private `answer-sheets` storage bucket. Running it
   again is safe.
3. **Sign-in settings** (*Authentication → Sign In / Providers → Email*):
   - Minimum password length **8**.
   - **Confirm email**: either turn it **off** (simplest for a college that
     shares its college ID only with its own people), or keep it on and change
     the *Confirm signup* email template (*Authentication → Emails*) to show the
     code, `{{ .Token }}` — people type that 6-digit code into Marklume; there is
     no link back into a desktop app.
   - Supabase's built-in email sender allows only a few emails an hour; for a
     whole class signing up, add your own SMTP server (*Authentication → Emails
     → SMTP Settings*) or turn confirmation off.
4. **Connect Marklume.** Copy the *Project URL* and the **anon / public** key
   from *Project Settings → API*. In Marklume choose **Connect…** on the
   sign-in screen, paste both, press *Test connection*, then *Save*. They are
   saved per user in `settings.json`; `SUPABASE_URL` and `SUPABASE_ANON_KEY`
   environment variables (or `--dart-define` at build time) override them, so a
   college can ship a build that is already connected.

Never put the **service_role** key in the app: the anon key is public by
design, and everything anyone may see or change is decided by the rules in
`setup.sql`.

To start over with test data, run [`supabase/reset_data.sql`](supabase/reset_data.sql)
in the SQL Editor: it deletes every row and every account but keeps the set-up.
Empty the `answer-sheets` bucket from *Storage* as well.

**Who does what**

| Role | Signs up with | Can |
| --- | --- | --- |
| College admin | "New college": college name + a college ID they choose | Approve, turn down, remove and restore teachers; everything a teacher can |
| Teacher | The college ID, a staff ID | Waits for the admin's approval, then marks and publishes; removes or restores students |
| Student | The college ID, their roll number | Is in at once; sees only results published to their roll number, asks for corrections, verifies marks |

Everyone signs in with their email or username. The admin shares the college
ID (shown under *College and members* in the account menu).

## Run

```bat
flutter run -d windows
```

To produce a distributable build, package the sidecar first so scans work
without a Python installation on the teacher's machine:

```bat
ocr_service\.venv\Scripts\python -m pip install -r ocr_service\requirements-build.txt
ocr_service\.venv\Scripts\python ocr_service\packaging\build_sidecar.py
flutter build windows --release
```

`build_sidecar.py` builds `ocr_service\dist\exam-corrector-ocr\` and smoke-tests
it (render, layout and handwriting recognition through the built binary);
`flutter build windows` copies it beside the executable as `ocr_service\`. The
result is in `build\windows\x64\runner\Release\`. Ship that folder; each
teacher enters their own key in Settings on first run. Recognition weights
(about 1.5 GB) download to the teacher's user cache on the first scan.

> Windows binaries can only be built on a Windows host — Flutter does not
> cross-compile the Windows target from macOS or Linux.

### Running it on macOS while developing

A macOS target is present for development on a Mac. Its **debug** build has the
App Sandbox turned off (`macos/Runner/DebugProfile.entitlements`) because the
sandbox blocks reading the project's `.env`; the release entitlements keep the
sandbox on. Windows has no equivalent restriction.

## Using it

Marking takes two documents. The question paper says what the questions are and
what they are worth; the answer sheet is what gets judged. They are joined on
question number.

1. **Student's answer sheet** — the completed script, as a PDF or a photograph.
   Select several files at once to mark a whole class against the same paper
   (the add button beside **Choose…** adds more).
   It is checked the moment it is chosen — readable, not encrypted, how many
   pages, typed or scanned — so an unreadable file is refused before any
   processing.
2. **Question paper** — the blank paper, with its sections and its printed mark
   allocations. This is the marking authority: the questions that get marked,
   which section each belongs to, and each question's maximum all come from
   here. Marks printed on the answer sheet are the student's own copy and are
   ignored.
3. **Marking guidance** *(optional)* — typed, or loaded from a text, Markdown or
   PDF file. When it covers a question, its points are what marking rewards;
   the question paper still decides what each question is worth.
4. **Correct paper** — processing shows the stage, pages, and what has been
   found so far, and can be cancelled. Results appear question by question;
   opening a question shows the student's original ink beside what was read
   from it, the marking points with the regions each was awarded for, the
   reasoning, the confidence, and a panel to accept or change the mark.

### Marking a class

With several scripts chosen, step 4 becomes a class table and the status bar
offers **Mark all _n_ scripts**. Scripts are marked one after another, each with
its own evidence, reviews and corrections; ones already marked are not repeated.
If the quota runs out partway, the marked scripts are kept and **Mark all**
continues from the one that stopped. Open a row to review that student; **All
scripts** returns to the table, which shows each student's mark (with your
changes), what is left to review and the class average. **Export class…**
writes one gradebook CSV with a column per question.

### What decides whether an answer is right

The question paper supplies the structure; the teacher's guidance, when given,
supplies the marking points; otherwise the model infers them from the question
and says so. Every point that awards marks names the regions of the script it
was awarded for — click one to see it highlighted on the scanned page — and
says whether it rests on what is plainly written, on a contextual reading of
unclear writing, or on something uncertain.

A question is flagged **Review** when its confidence is below the threshold
(Settings), when a mark rests on uncertain evidence, when the handwriting was
hard to read or two recognisers disagreed, when the answer's mapping to the
question is uncertain, or when the model asks for it. Your mark is recorded
beside the AI's, never over it; the total counts yours.

Two things are always surfaced rather than left implicit:

- **A maximum the question paper never printed** is flagged as a warning naming
  the question. An invented maximum silently changes what the student is marked
  out of.
- **An answer whose question number is not in the question paper** is not
  marked, and is listed by number. That is usually a mislabelled answer or two
  documents from different exams.

### If every question comes back "No answer found"

A result of 0 out of everything almost always means step 1 holds the wrong file
— it is easy to choose the blank question paper for both — rather than a student
who wrote nothing. The result says so above the marks, and two identical files
are refused before a request is spent. `flutter test tool/show_extracted.dart`
prints exactly what the application reads from a PDF.

### Free-tier quotas, and the model chain

A typed paper costs one or two requests. A handwritten one adds a request or
two for handwriting the local recogniser was unsure of, and one per page (or
two) only for pages with drawings, tables or graphs. Everything is cached, so
marking the same paper again — or resuming after a failure — costs only what
had not finished. Google's free tier allows as few as **20
requests per day** for a flagship model, counted **per project and per model**,
resetting at midnight Pacific — so a single model cannot mark a class set.

Each model has its own allowance, so marking walks down a chain:

```
gemini-3.6-flash → gemini-3.5-flash → gemini-3.5-flash-lite → gemini-3.7-flash
```

When a model's allowance is gone, the application says so in the status bar
(*"gemini-3.6-flash has no quota left today — marking with gemini-3.5-flash…"*),
continues on the next model, and records which model produced the marks — shown
beside the question count as *"Marked by …"*. Papers in one batch can therefore
be marked by different models; to prevent that, clear **Fallback models** in
Settings and every paper stays on one model.

Shorter interruptions are handled first: the service retries twice, waiting
exactly as long as the API asks (it states a delay such as *"Please retry in
34.7s"*) and showing that wait in the status bar. A rejected key or a bad
request is reported immediately, since neither retrying nor another model would
change the outcome.

`dart run tool/quota_probe.dart` reports which models the key can use right now:

```
gemini-3.6-flash           ok — quota available
gemini-3.5-flash           ok — quota available
gemini-3.5-flash-lite      ok — quota available
gemini-3.7-flash           EXHAUSTED — limit 20, retry in 35s
```

Per-model limits for your own key are listed at
[AI Studio → Rate limits](https://aistudio.google.com/rate-limit). Put a model
whose daily allowance covers a whole class set first, so the chain stays a
safety net rather than the normal path.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `GEMINI_API_KEY` | — | API credential. `GOOGLE_API_KEY` is accepted too. |
| `EXAM_CORRECTOR_MODEL` | `gemini-3.6-flash` | Marking model. |
| `EXAM_CORRECTOR_FALLBACK_MODELS` | `gemini-3.5-flash, gemini-3.5-flash-lite, gemini-3.7-flash` | Models to continue on as each daily quota runs out. Empty keeps every paper on one model. |
| `EXAM_CORRECTOR_VISION_MODEL` | the marking model | Reads pages: layout, handwriting second opinions, scanned question papers. |
| `EXAM_CORRECTOR_DIAGRAM_MODEL` | the vision model | Analyses diagrams, graphs, tables and equations. |
| `EXAM_CORRECTOR_EFFORT` | `high` | Marking reasoning level: `minimal`, `low`, `medium`, `high`. |
| `EXAM_CORRECTOR_MAX_TOKENS` | `32000` | Marking output ceiling. |
| `EXAM_CORRECTOR_LAYOUT_ENGINE` | `hybrid` | `hybrid` (local first, vision model for complex pages), `vision`, or `local` (offline). |
| `EXAM_CORRECTOR_VISUAL_ANALYSIS` | `true` | Structured analysis of diagrams, graphs, tables, equations. Their images reach the marker either way. |
| `EXAM_CORRECTOR_REVIEW_THRESHOLD` | `0.7` | Marking confidence below this flags a question for review. |
| `EXAM_CORRECTOR_OCR_ENABLED` | `true` | Read handwriting locally with TrOCR. Off relies on the vision model alone. |
| `EXAM_CORRECTOR_TROCR_MODEL` | `microsoft/trocr-large-handwritten` | Local handwriting model. |
| `EXAM_CORRECTOR_OCR_THRESHOLD` | `0.92` | Handwriting below this — any line, or the region — gets a second opinion and is flagged. |
| `EXAM_CORRECTOR_OCR_VISION_CHECK` | `true` | Allow that second opinion. Costs requests. |
| `EXAM_CORRECTOR_OCR_DPI` | `300` | Render resolution (100–400). |
| `EXAM_CORRECTOR_MAX_IMAGE_DIM` | `1600` | Longest side of any image sent to a model. |
| `EXAM_CORRECTOR_PAGES_PER_REQUEST` | `2` | Pages per vision request during page analysis. |
| `EXAM_CORRECTOR_QUESTIONS_PER_REQUEST` | `8` | Questions per marking request. |
| `EXAM_CORRECTOR_MAX_IMAGES_PER_REQUEST` | `16` | Images attached to one request. |
| `EXAM_CORRECTOR_TIMEOUT_SECONDS` | `300` | How long a request may go silent. |
| `EXAM_CORRECTOR_RETRIES` | `2` | Retries of a request that failed transiently. |
| `EXAM_CORRECTOR_API_ENDPOINT` | Gemini Interactions API | For a proxy or regional endpoint. |
| `EXAM_CORRECTOR_CACHE` | `true` | Reuse cached stage results. |
| `EXAM_CORRECTOR_DEBUG` | `false` | Developer mode: the page inspector. |
| `EXAM_CORRECTOR_OCR_DEVICE` | auto | Force the recogniser onto `cpu`, `mps` or `cuda`. |
| `EXAM_CORRECTOR_OCR_COMMAND` | — | A prebuilt sidecar binary, instead of the development environment. |
| `EXAM_CORRECTOR_OCR_ENDPOINT`, `EXAM_CORRECTOR_OCR_TOKEN` | — | Use an already-running sidecar instead of starting one. |

An invalid value stops the application at start-up with a message naming the
setting. Most of these are also in **Settings**.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the pipeline, the domain model, the
engine interfaces, caching, error handling, alignment and marking.

```
lib/
  domain/        pages, regions, evidence, questions, answers, marks, reviews, jobs
  pipeline/      the stages and their engines; exam_pipeline.dart runs them
  services/      model client (Gemini), sidecar, PDF, settings, export, reviews
  state/         the workflow controller
  screens/       home, question detail, page inspector
  widgets/       uploads, guidance, processing, results, page viewer, settings
ocr_service/     the local Python engines — see its README
```

Boundaries that matter:

- **The UI holds no marking logic.** It collects input, calls the controller,
  and renders what the pipeline and the validation layer produced.
- **Every model call goes through `ModelClient`.** `GeminiModelClient` is the
  only code that knows the provider; `main.dart` is the only place it is named.
- **Every stage is behind an interface** (`lib/pipeline/engines.dart`) and
  chosen by configuration in `pipeline_factory.dart`.
- **Nothing reaches the screen unvalidated.** Marks are capped at each
  question's maximum, totals are recomputed locally, evidence must belong to
  the answer, and any adjustment becomes a review reason.

## Tests

```bat
flutter test
ocr_service\.venv\Scripts\python -m pytest ocr_service\tests
```

Both suites are offline and fast. The Dart suite covers the domain model and
its JSON round trips, question-paper parsing, label detection, answer
boundaries and alignment (continuations, sub-parts, split blocks, unmatched
labels), the handwriting ensemble policy, vision page analysis parsing, hybrid
fallbacks, visual analysis and its failures, answer reconstruction, the marking
validator and engine, the pipeline end to end with caching, resume, teacher
corrections and cancellation, the Gemini transport (streaming, retries, the
model chain, every HTTP failure, timeouts), the controller, and the screens —
including a layout check at six window sizes. The Python suite covers
rendering, blank detection, local layout (text blocks, question numbers,
diagrams, graphs, tables, strikes, ruling), region recognition, word
confidences, cropping and the HTTP endpoints — with no model weights loaded.

Checks that use the real services live outside `test/`:

| Script | What it answers |
| --- | --- |
| `dart run tool/live_check.dart` | Does the key work? Marks two small answers. |
| `flutter test tool/sample_check.dart` | Does marking agree with `sample/expected_outcome.md`? Runs the typed sample through the whole pipeline. Add `EXAM_CORRECTOR_GUIDANCE=sample/mark_scheme.txt` to mark with the mark scheme as guidance. |
| `flutter test tool/pipeline_check.dart` | What does every stage make of a script? Pages, regions, readings, answers, marks. `EXAM_CORRECTOR_SCAN=…`, `EXAM_CORRECTOR_QUESTIONS=…`; `EXAM_CORRECTOR_CHECK_MARKING=0` skips marking. |
| `dart run tool/quota_probe.dart [model]` | Which models does this key have quota for? |
| `flutter test tool/show_extracted.dart` | What does the PDF text layer contain? |
| `ocr_service/.venv/bin/python ocr_service/tools/run_pipeline.py <file>` | The local engines alone: render, layout, recognition. |

They are cached like the application, so a second run is fast and free.

### Sample inputs

`sample/` holds a full worked example for trying the application by hand:

| File | Use |
| --- | --- |
| `student_paper.pdf` | **Choose PDF…** — a three-page Year 10 biology script with a text layer |
| `student_paper_handwritten.pdf` | The same answers in handwriting, degraded to look scanned — for exercising the OCR path |
| `question_paper.pdf` | **Question paper** — the same exam with no answers, in two sections of ten marks |
| `question_paper.txt` | The same question paper as text |
| `mark_scheme.pdf` | A worked mark scheme. Not an input any more; kept as a reference for what the marks should be |
| `mark_scheme.txt` | The same mark scheme, as text |
| `expected_outcome.md` | The marks each question should receive, and why |
| `visual_student_paper.pdf`, `visual_question_paper.pdf` | A two-page handwritten script whose answers are a labelled diagram, a table, a graph and working with a struck-out line |
| `visual_expected.md` | What the visual sample should score (9 / 11), and why |

The script is written so one paper exercises every marking rule: full credit,
partial credit, an accepted alternative wording, a calculation with method
marks and a wrong final answer, an unanswered question, a fluent but mostly
incorrect answer, a contradicted marking point, and an answer continued in the
extra answer space on a later page. A correct run scores **14/20 — 70%**.

Regenerate them with:

```bat
flutter test tool/make_sample_inputs.dart
ocr_service/.venv/bin/python ocr_service/tools/make_handwritten_sample.py
ocr_service/.venv/bin/python ocr_service/tools/make_visual_sample.py
```

Last measured with the real models: the typed sample scores 14 / 20 against the
expected 14 / 20 with the mark scheme loaded as guidance (15 / 20 without — the
inferred scheme is more lenient on Q2(b)); the visual sample scores 9 / 11 with
every question as expected. Run `pipeline_check.dart` with
`EXAM_CORRECTOR_SCAN=sample/visual_student_paper.pdf
EXAM_CORRECTOR_QUESTIONS=sample/visual_question_paper.pdf` to see every stage.

## Handwritten scripts

Scans and photographs are rendered and analysed by a local Python sidecar the
application starts on demand. See [`ocr_service/README.md`](ocr_service/README.md)
for its one-time setup. Typed PDFs need no sidecar: they are read from their
text layer (the sidecar, if present, adds page images for the evidence view).

```
page image
   ├─ PyMuPDF + OpenCV    render, keep the original, deskew a clean copy, skip blank pages
   ├─ layout              DBNet text + computer vision: answer blocks, question numbers,
   │                      diagrams, graphs, tables, crossed-out lines, margins
   ├─ vision model        only for pages with drawings or unexplained ink (hybrid)
   ├─ TrOCR               each region line by line, word-level confidence
   ├─ vision model        a second reading of anything uncertain
   └─ marking             text and images together, uncertainty shown to the model
```

What makes it trustworthy rather than a black box:

- **Nothing is overwritten.** Every reading of every region is kept; a teacher's
  correction sits beside the machine reading; the AI's mark beside the teacher's.
- **Uncertainty is measured and carried forward.** Low-confidence words are
  highlighted in the review and marked `{?like this?}` for the marking model,
  which is also shown the original image of every uncertain region.
- **Everything is traceable.** Every mark names the regions it was awarded for,
  and every region opens on the scanned page.

The honest limitations are listed in ARCHITECTURE.md; the main ones are that
local layout does not detect equations as such (their images reach the marker
through the uncertainty path, and vision-analysed pages detect them), and that
a scanned question paper needs the vision model.

## Note on dependencies

`supabase` (pure Dart, no platform plugins) talks to the college server:
sign-in, the results tables and the answer-sheet images.

`syncfusion_flutter_pdf` provides pure-Dart PDF text extraction on Windows. It
is distributed under the Syncfusion Community License, which is free for
qualifying individuals and small businesses — check that you qualify before
distributing a build.

## Previous implementation

The original Python/Tkinter version now lives in `legacy_python/`, with a table
mapping each old module to its Dart counterpart. It is not built or run; delete
it (and the root `.venv/`) once the Flutter version has settled.
