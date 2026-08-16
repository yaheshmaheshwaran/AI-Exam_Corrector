# Exam Corrector

A Flutter **Windows desktop** application that marks a student's exam paper
against a supplied mark scheme, using Google Gemini, and shows the result question by
question.

## Workflow

```
Upload student exam PDF → Provide mark scheme → Correct
→ Content extraction
→ AI evaluates each answer against the mark scheme
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

1. **Choose PDF…** — select the student's completed exam paper. Text is
   extracted immediately, on a background isolate, and the character count is
   shown, so an unreadable file is caught before any API call.
2. **Mark scheme** — paste it, or **Load from PDF…**. Include the questions,
   expected answers, mark allocation, required points, acceptable alternatives
   and any partial-credit rules. The mark scheme is the sole authority for
   awarding marks.
3. **Correct paper** — the button enables once both inputs are present. Marking
   runs asynchronously with a visible progress state. The result appears in
   section 3 with per-question marks, the student's answer, a short evaluation,
   satisfied (✓) and unsatisfied (✗) marking points, and a pinned total with
   percentage.

### If every question comes back "No answer found"

A result of 0 out of everything, with no answer found for any question, almost
always means section 1 holds the wrong file — the mark scheme, or a blank
question paper — rather than a student who wrote nothing. The result says so
above the marks, and the two files being identical is refused before a request
is spent. `flutter test tool/show_extracted.dart` prints exactly what the
application reads from a PDF.

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
    exam_paper.dart                  extracted paper
    mark_scheme.dart                 the marking authority
    correction_result.dart           validated correction + adjustments
    question_result.dart             per-question marks and marking points
  services/
    pdf_service.dart                 PDF validation and text extraction
    file_picker_service.dart         native open dialog
    settings_store.dart              the API key, saved in the user profile
    correction_validation_service.dart  validates the AI response before it becomes marks
    ai/
      correction_service.dart        CorrectionService interface
      correction_prompt.dart         correction prompt + JSON response schema
      gemini_correction_service.dart   Gemini implementation of the interface
  state/
    correction_controller.dart       ChangeNotifier driving the workflow
  screens/home/home_screen.dart      upload, mark scheme, correct, results
  widgets/                           section shell, upload, mark scheme, progress,
                                     question card, results view
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
  so the window stays responsive.

### How marks are kept faithful to the mark scheme

- The prompt names the mark scheme as the single authority and forbids inventing
  criteria, so marking is done against stated criteria rather than a general
  impression of the answer.
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

Override the model for a run with `EXAM_CORRECTOR_MODEL=<model> dart run …`.

### Sample inputs

`sample/` holds a full worked example for trying the application by hand:

| File | Use |
| --- | --- |
| `student_paper.pdf` | **Choose PDF…** — a three-page Year 10 biology script with a text layer |
| `mark_scheme.pdf` | **Load from PDF…** |
| `mark_scheme.txt` | The same mark scheme, for pasting |
| `expected_outcome.md` | The marks each question should receive, and why |

The script is written so one paper exercises every marking rule: full credit,
partial credit, an accepted alternative wording, a calculation with method
marks and a wrong final answer, an unanswered question, a fluent but mostly
incorrect answer, a contradicted marking point, and an answer continued in the
extra answer space on a later page. A correct run scores **14/20 — 70%**.

Regenerate them with:

```bat
flutter test tool/make_sample_inputs.dart
```

## Known limitation

Correction relies on the PDF containing a text layer. A scanned or photographed
script has no extractable text; the application detects this and says so rather
than sending an empty paper for marking. Handwritten-script support would need
an OCR or vision step, which is outside the current scope.

## Note on dependencies

`syncfusion_flutter_pdf` provides pure-Dart PDF text extraction on Windows. It
is distributed under the Syncfusion Community License, which is free for
qualifying individuals and small businesses — check that you qualify before
distributing a build.

## Previous implementation

The original Python/Tkinter version now lives in `legacy_python/`, with a table
mapping each old module to its Dart counterpart. It is not built or run; delete
it (and the root `.venv/`) once the Flutter version has settled.
