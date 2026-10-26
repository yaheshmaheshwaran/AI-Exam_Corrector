# Marklume

A Flutter desktop application (macOS, Windows) that marks a student's
handwritten answer script against the question paper it was sat from. It reads
every page, finds each question's answer, marks it with the evidence for every
mark, and lets the teacher review and override each one.

```
once per exam   question paper → questions and marks · answer key (AI-written, or the teacher's)
every student   script PDF → pages → read by a vision model → answers matched to questions
                → answers cleaned → marked by one model → checked → teacher review
```

A 14-page script takes about 5–6 minutes, almost all of it marking. How it is
built is in [ARCHITECTURE.md](ARCHITECTURE.md); why, in
[docs/decisions/](docs/decisions/).

## Requirements

- Flutter 3.41 or later, with the macOS (Xcode) or Windows (Visual Studio,
  "Desktop development with C++") desktop target.
- Two free API keys:
  - **Gemini** ([AI Studio](https://aistudio.google.com/apikey)): reads the
    pages and marks.
  - **NVIDIA** ([build.nvidia.com](https://build.nvidia.com), phone check, no
    card): reads the question paper and writes the answer key.

Nothing else is installed: PDF pages are rendered in the app by PDFium. There is
no Python service.

## Setup

```bash
flutter pub get
flutter run -d macos        # or: -d windows
```

The first macOS build downloads the PDFium framework through CocoaPods from
GitHub, so it needs a network that reaches `github.com`.

Then open **Settings → Models**:

1. Paste the Gemini and NVIDIA keys.
2. Leave the three jobs on their defaults, or change them:

   | Job | Default, first choice first | Done |
   |---|---|---|
   | Exam preparation | `nvidia/moonshotai/kimi-k3`, `nvidia/z-ai/glm-5.3`, `gemini/gemini-3.5-flash` | Once per exam |
   | Page reading | `gemini/gemini-3.1-flash-lite`, `server/Qwen/Qwen3-VL-8B-Instruct` | Every student |
   | Marking | `gemini/gemini-3.5-flash`, `nvidia/moonshotai/kimi-k3` | Every student |

   A model's name starts with where it runs: `gemini/`, `nvidia/`, `server/`
   (your own vLLM server, such as a Kaggle notebook) or `ollama/` (this
   computer). The models after the first are backups, used when one is out of
   its daily allowance or not answering.
3. Press **Test connection** beside each job.

Settings are saved per user, in `~/Library/Application Support/Exam
Corrector/settings.json` on macOS and `%APPDATA%\Exam Corrector\settings.json`
on Windows. An environment variable overrides a saved setting, and a saved
setting overrides `.env`. To keep settings beside the project instead, copy
[`.env.example`](.env.example) to `.env`. Keys are never hard-coded, and `.env`
is git-ignored.

### Your own model server (optional)

When Gemini's free allowance is spent, a GPU server can read pages instead:

```bash
vllm serve Qwen/Qwen3-VL-8B-Instruct --max-model-len 32768
```

Enter its address (`https://…/v1`) under **Settings → Models**. Ollama works
too (`ollama/<model>`), but start it with `OLLAMA_CONTEXT_LENGTH=32768 ollama
serve`, because its OpenAI-compatible address cannot set the context length.

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
     code, `{{ .Token }}`. People type that 6-digit code into Marklume; there is
     no link back into a desktop app.
   - Supabase's built-in email sender allows only a few emails an hour. For a
     whole class signing up, add your own SMTP server (*Authentication → Emails
     → SMTP Settings*) or turn confirmation off.
4. **Connect Marklume.** Copy the *Project URL* and the **anon / public** key
   from *Project Settings → API*. In Marklume choose **Connect…** on the
   sign-in screen, paste both, press *Test connection*, then *Save*.
   `SUPABASE_URL` and `SUPABASE_ANON_KEY` environment variables (or
   `--dart-define` at build time) override them, so a college can ship a build
   that is already connected.

Never put the **service_role** key in the app. The anon key is public by
design, and everything anyone may see or change is decided by the rules in
`setup.sql`.

To start over with test data, run [`supabase/reset_data.sql`](supabase/reset_data.sql)
in the SQL Editor. It deletes every row and every account but keeps the set-up.
Empty the `answer-sheets` bucket from *Storage* as well.

| Role | Signs up with | Can |
| --- | --- | --- |
| College admin | "New college": college name + a college ID they choose | Approve, turn down, remove and restore teachers; everything a teacher can |
| Teacher | The college ID, a staff ID | Waits for the admin's approval, then marks and publishes; removes or restores students |
| Student | The college ID, their roll number | Is in at once; sees only results published to their roll number, asks for corrections, verifies marks |

## Using it

1. **Student's script**: a PDF. Choose several to mark a class against the same
   paper. Each is checked as soon as it is chosen (readable, not encrypted, page
   count), so an unusable file is refused before anything is spent.
2. **Question paper**: a PDF, typed or a photo. It decides which questions are
   marked, their sections and their maximums. Marks printed on the script are
   ignored.
3. **Answer key** *(optional)*: typed by the teacher. Without one, an answer key
   is written once from the questions and shared by every script; the teacher
   can edit it. A **syllabus** from the library, a **marking standard** and
   **moderation** can also be set.
4. **Correct paper**: progress shows each stage and can be cancelled. Results
   appear question by question. Opening a question shows the student's ink
   beside what was read, the marking points with the evidence for each, the
   reasoning, the confidence, and a panel to accept or change the mark.

A question goes to **Review** when the marker is unsure, when a mark rests on
writing that was hard to read or possibly crossed out, when the answer's match
to the question is uncertain, or when a backup model marked it. The teacher's
mark is kept beside the AI's, never over it, and the total counts the
teacher's.

**A class**: with several scripts chosen, **Mark all** marks them one after
another, reading the next script while the current one is marked, and skips
those already marked. **Export class…** writes one gradebook CSV.

**Free allowances**: a script takes about 5 reading requests and 1 marking
request. When the first-choice marker's daily allowance is spent, the app
offers to mark with the backup, and every mark it gives is flagged. Each script
is always marked by one model. Allowances reset at midnight Pacific. Every
stage is saved, so a stopped or failed run resumes where it stopped, at no
extra cost.

## Tools

Run from the project root. They use the same settings and keys as the app.

| Command | What it answers |
| --- | --- |
| `dart run tool/mark_one_script.dart --script <pdf> --paper <pdf>` | What does each stage make of a script, and how long does it take? Writes `transcript.md`, `marks.json` and `summary.json`; `--reader`, `--marker`, `--prep` choose models |
| `dart run tool/compare_examiner.dart --examiner <csv> <marks folder>…` | How close are the marks to an examiner's? Reads the examiner's marks only after marking, and never sends them to a model |
| `dart run tool/quota_probe.dart <models>` | Which models can this key use right now? |
| `dart run tool/provider_probe.dart [nvidia]` | What does a provider accept: models, images, JSON schema? |
| `dart run tool/render_check.dart <pdf>` | Does PDFium render this PDF, and how fast? |
| `flutter test tool/show_extracted.dart` | What does a PDF's text layer contain? |

## Tests

```bash
flutter analyze
flutter test
```

Everything is offline. `test/ai` covers the model client (streaming, retries,
allowances, time limits, every HTTP failure). `test/marking` covers the reader's
output mapping, matching answers to questions, marking checks and the pipeline
end to end (caching, resume, backup marking, teacher corrections,
cancelling). `test/state` and `test/widgets` cover the controller and the
screens.

`sample/` holds worked examples for trying the app by hand: a typed and a
handwritten Year 10 biology script with its question paper, mark scheme and
expected marks (`expected_outcome.md`, 14 / 20), and a visual script with a
diagram, table and graph (`visual_expected.md`, 9 / 11). Regenerate the typed
one with `flutter test tool/make_sample_inputs.dart`.

## Packaging

```bash
flutter build macos --release      # or: flutter build windows --release
```

The macOS debug build has the App Sandbox off
(`macos/Runner/DebugProfile.entitlements`) so it can read the project's `.env`;
the release build keeps it on. Windows binaries can only be built on Windows.

## Dependencies worth knowing

- `pdfrx` renders PDF pages with PDFium; `image` crops them.
- `syncfusion_flutter_pdf` reads a typed PDF's text. It is under the Syncfusion
  Community License, free for qualifying individuals and small businesses.
  Check that you qualify before distributing a build.
- `supabase` (pure Dart) talks to the college server.

The earlier Python version and the Python OCR service (doctr, TrOCR) are
archived outside the project, in `~/Documents/marklume-archive/`.
