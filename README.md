# Exam Corrector

A Flutter **Windows desktop** application that marks a student's answer sheet
against the question paper it was sat from, using Google Gemini, and shows the
result question by question. Handwritten scripts are read locally with Microsoft
TrOCR.

## Workflow

```
Upload answer sheet + question paper → Correct
→ Content extraction, or handwriting recognition and teacher review
→ Questions, sections and marks read from the question paper
→ Each answer matched to its question by question number
→ AI marks it, declaring the marking points it rewarded
→ Structured result, validated locally
→ Question-by-question marks, reasoning and marking points
→ Total marks and percentage
```

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

## Run

```bat
flutter run -d windows
```

To produce a distributable build:

```bat
flutter build windows --release
```

The result is in `build\windows\x64\runner\Release\`. Ship that folder; each
teacher enters their own key in Settings on first run.

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

1. **Student's answer sheet** — the completed script. Text is extracted
   immediately on a background isolate, or recognised if it is handwritten, so
   an unreadable file is caught before any API call.
2. **Question paper** — the blank paper, with its sections and its printed mark
   allocations. This is the marking authority: the questions that get marked,
   which section each belongs to, and each question's maximum all come from
   here. Marks printed on the answer sheet are the student's own copy and are
   ignored.
3. **Marking guidance** *(optional)* — notes such as *"Section A: one mark each.
   Section B: award marks based on the required points."* Use it only where the
   question paper leaves something unsaid. Where the two disagree, the question
   paper wins and the evaluation says so.
4. **Correct paper** — enabled once both documents are present; the guidance is
   never required. The result appears in section 4 with per-question marks, the
   student's answer, a short evaluation, satisfied (✓) and unsatisfied (✗)
   marking points, and a pinned total with percentage.

### What decides whether an answer is right

There is no mark scheme. The question paper supplies the structure, and the
model supplies the subject knowledge — so for each question it must also report
the marking points it decided to reward and how it split the marks between them.
Those are the ✓/✗ lines on each result card, and they are the thing to read
before trusting a mark: they are the model's reasoning made checkable, not a
scheme you supplied.

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

One correction is one API request. Google's free tier allows as few as **20
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
| `GEMINI_API_KEY` | — | Required. API credential. `GOOGLE_API_KEY` is accepted too. |
| `EXAM_CORRECTOR_MODEL` | `gemini-3.6-flash` | Model marking starts on. |
| `EXAM_CORRECTOR_FALLBACK_MODELS` | `gemini-3.5-flash, gemini-3.5-flash-lite, gemini-3.7-flash` | Comma-separated models to continue on as each daily quota runs out. Set it empty to keep every paper on one model. |
| `EXAM_CORRECTOR_EFFORT` | `high` | Gemini thinking level: `minimal`, `low`, `medium`, `high`. |
| `EXAM_CORRECTOR_MAX_TOKENS` | `32000` | Output ceiling; raise for very long papers. |
| `EXAM_CORRECTOR_OCR_ENABLED` | `true` | Read scans with no text layer. Set false to reject them instead. |
| `EXAM_CORRECTOR_TROCR_MODEL` | `microsoft/trocr-large-handwritten` | Recognition model. `trocr-base-handwritten` is faster and less accurate. |
| `EXAM_CORRECTOR_OCR_THRESHOLD` | `0.92` | Below this confidence a line is cross-checked and flagged for review. |
| `EXAM_CORRECTOR_OCR_VISION_CHECK` | `true` | Ask the vision model for a second opinion on uncertain lines. Costs API requests. |
| `EXAM_CORRECTOR_OCR_DPI` | `300` | Resolution pages are rendered at before recognition (100–400). |
| `EXAM_CORRECTOR_OCR_DEVICE` | auto | Force the recogniser onto `cpu`, `mps` or `cuda`. |
| `EXAM_CORRECTOR_OCR_COMMAND` | — | Path to a prebuilt sidecar binary, instead of the development virtual environment. |

## Architecture

```
lib/
  main.dart                          entry point: config → service → controller → window
  app/
    app.dart                         application shell and startup-error screen
    app_theme.dart                   desktop theme
  core/
    config/app_config.dart           environment- and .env-based configuration
    constants/app_constants.dart     defaults, limits, API endpoint
    errors/app_exception.dart        failures carrying teacher-facing messages
    utils/marks_format.dart          mark, percentage and count formatting
  models/
    exam_paper.dart                  extracted paper, and how it was extracted
    marking_guidance.dart            the teacher's optional notes
    correction_result.dart           validated correction + adjustments
    question_result.dart             per-question marks and marking points
    ocr/                             transcript, pages, lines with boxes and confidence
  services/
    pdf_service.dart                 PDF validation and text extraction
    file_picker_service.dart         native open dialog
    settings_store.dart              the API key, saved in the user profile
    correction_validation_service.dart  validates the AI response before it becomes marks
    ai/
      correction_service.dart        CorrectionService interface
      correction_prompt.dart         correction prompt + JSON response schema
      gemini_client.dart             shared REST transport: streaming, retries, errors
      gemini_correction_service.dart   Gemini implementation of the interface
      vision_transcription_service.dart  second opinion on low-confidence lines
    ocr/
      ocr_service.dart               OcrService interface
      sidecar_ocr_service.dart       talks to the local TrOCR process
      sidecar_process_service.dart   starts, health-checks and stops that process
      transcript_parser.dart         validates the sidecar's response
      document_ingest_service.dart   routes a file to the text layer or to OCR
      answer_normalizer.dart         repairs recognition artefacts, never spelling
      question_anchor_service.dart   ties questions to the lines they were read from
  state/
    correction_controller.dart       ChangeNotifier driving the workflow
  screens/
    home/home_screen.dart            two uploads, guidance, correct, results
    review/transcript_review_screen.dart  check the transcript before marking
  widgets/                           section shell, uploads, guidance, progress,
                                     question card, results view, transcript line
ocr_service/                         the Python handwriting recogniser — see its README
```

Each boundary is deliberate:

- **The UI holds no marking logic.** It collects input, calls the controller,
  and renders whatever the validation layer approves.
- **State management is a plain `ChangeNotifier`** rendered with
  `ListenableBuilder`. A single-window tool does not need more, and the widgets
  stay free of workflow logic.
- **The AI is behind `CorrectionService`.**
  `lib/services/ai/gemini_correction_service.dart` is the only file that
  knows which model or provider is in use; swapping it means writing one new
  implementation of the interface. There is no official Gemini SDK for Dart, so
  it speaks the Interactions REST API directly, streamed so a long correction
  cannot hit an HTTP timeout. Requests are sent with `store: false`, so papers
  are not retained server-side.
- **PDF handling is independent of both.** It turns a path into text, or throws
  an error message written for a teacher. Parsing runs on a background isolate
  so the window stays responsive. It has no opinion about, and no dependency on,
  handwriting recognition: the choice between the two lives one level up, in
  `DocumentIngestService`.
- **Handwriting recognition is behind `OcrService`,** so the local TrOCR sidecar
  could be replaced by a hosted one without touching anything above it. Marking
  is unaware of it entirely — OCR produces a `String`, which reaches
  `CorrectionService.correct` exactly as a text layer does.

### How marks are kept honest

- The prompt names the question paper as the authority for structure: the
  questions marked, their sections and their maxima all come from it, and marks
  printed on the answer sheet are explicitly disregarded.
- Correctness is the model's judgement, so it must declare the marking points it
  rewarded and how it divided the marks. Marking against stated points, shown to
  the teacher, beats a general impression of the answer that cannot be checked.
- A maximum the paper did not state, and any answer whose question number is not
  in the paper, are both reported as warnings rather than absorbed silently.
- The response is constrained to a JSON schema (`response_format.schema`), so the
  application never parses free-form prose into marks.
- `correction_validation_service.dart` re-checks every field before display.
  Awarded marks are capped at the question maximum, negative marks are raised to
  zero, marks on unsatisfied points are zeroed, and **the totals and percentage
  are always recomputed locally** from the per-question marks rather than
  trusted from the model. Any adjustment is shown to the teacher above the
  result.

## Tests

```bat
flutter test
```

Covers the validation rules, configuration parsing, PDF extraction against a
generated PDF, the Gemini client (request shape, streamed-response parsing,
refusals, truncation, retries, and each HTTP failure), the workflow controller,
the Settings flow, an end-to-end widget walkthrough from upload to displayed
marks, and a layout check at six window sizes so the window cannot overflow.

The suite is offline. Three scripts check the real service; they live outside
`test/` so `flutter test` never touches the network:

| Script | What it answers |
| --- | --- |
| `dart run tool/live_check.dart` | Does the key work end to end? Marks a two-question paper. |
| `dart run tool/sample_check.dart` | Does marking still agree with `sample/expected_outcome.md`? Marks the sample paper and compares every question. |
| `dart run tool/quota_probe.dart [model]` | Which models does this key have quota for? Prints the raw status and message. |
| `flutter test tool/show_extracted.dart` | What does the PDF layer actually read from a file? Defaults to the sample paper; set `EXAM_CORRECTOR_PDF=/path/to/file.pdf` for another. |
| `flutter test tool/ocr_check.dart` | The whole handwriting pipeline through the app's own services, with per-line confidences and the text that would be marked. Set `EXAM_CORRECTOR_SCAN=…` for another file, `EXAM_CORRECTOR_OCR_VISION_CHECK=0` to spend no quota. |

Override the model for a run with `EXAM_CORRECTOR_MODEL=<model> dart run …`.

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

The script is written so one paper exercises every marking rule: full credit,
partial credit, an accepted alternative wording, a calculation with method
marks and a wrong final answer, an unanswered question, a fluent but mostly
incorrect answer, a contradicted marking point, and an answer continued in the
extra answer space on a later page. A correct run scores **14/20 — 70%**.

Regenerate them with:

```bat
flutter test tool/make_sample_inputs.dart
ocr_service/.venv/bin/python ocr_service/tools/make_handwritten_sample.py
```

## Handwritten scripts

A PDF with a text layer is read directly. A scan or a photograph — which has no
extractable text — is read by **Microsoft TrOCR**, running locally in a Python
sidecar the application starts on demand. See
[`ocr_service/README.md`](ocr_service/README.md) for the setup, which is a
one-time `uv venv` and install.

```
scan or photograph
   │
   ├─ PyMuPDF      render each page
   ├─ OpenCV       deskew, denoise, even out the lighting
   ├─ docTR DBNet  find the text lines
   ├─ TrOCR        read each line, and score its own confidence
   ├─ Gemini       re-read only the lines TrOCR was unsure of
   └─ review       the teacher checks the transcript before anything is marked
```

Three things make this trustworthy rather than a black box:

- **The teacher sees the evidence.** Recognition stops at a review screen that
  shows each line beside the strip of page it was read from, with the uncertain
  ones highlighted and filterable. Nothing is marked until it is accepted, and
  the original reading is always one click away.
- **Uncertainty is measured, and acted on.** TrOCR reports no confidence, so it
  is derived from the decoder's own token probabilities. Lines below the
  threshold get a second opinion from the vision model — sent as cropped line
  images, batched, so a whole script costs a request or two rather than a day's
  quota. Where the two readings agree the line is cleared; where they disagree
  it stays flagged.
- **Transcription errors are not marked as the student's.** When a paper came
  from OCR the prompt says so, and tells the model to judge the answer on its
  evident intent rather than deducting for a misread character.

The honest limitation: TrOCR is trained on English prose, one line at a time.
It is excellent on running handwriting and weak on the rest of what an exam
script contains — equations, tables, diagrams, crossed-out work. On the sample
script it read every prose answer correctly and misread `+` as `t`, `=` as `-`,
and `100 / 0.05` as `( 100 ) 0.05`. Those are exactly the lines it scores low
on, which is what the cross-check and the review screen are for. **Check the
working on any question that turns on arithmetic.**

Turn any of this off in **Settings** — recognition itself, the cross-check, or
the confidence threshold.

## Note on dependencies

`syncfusion_flutter_pdf` provides pure-Dart PDF text extraction on Windows. It
is distributed under the Syncfusion Community License, which is free for
qualifying individuals and small businesses — check that you qualify before
distributing a build.

## Previous implementation

The original Python/Tkinter version now lives in `legacy_python/`, with a table
mapping each old module to its Dart counterpart. It is not built or run; delete
it (and the root `.venv/`) once the Flutter version has settled.
