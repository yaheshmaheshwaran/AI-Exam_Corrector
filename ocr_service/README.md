# Local document-understanding sidecar

Renders exam scripts, analyses their page layout, and reads handwriting region
by region, so the application can understand a script before it is marked. It
runs as a child process of the Flutter app, bound to loopback, and is started on
demand — the first time a paper needs rendering, never at launch.

The app finds this automatically during development. If you have not set the
environment up, choosing a scanned paper reports *"The handwriting recogniser is
not installed"* and points here.

## Why a separate process

Two things the Flutter app cannot do for itself:

- **TrOCR is PyTorch.** There is no Dart runtime for it.
- **Nothing in the app can rasterise a PDF.** `syncfusion_flutter_pdf` extracts
  a text layer but cannot render a page to a bitmap, and a scan has no text
  layer to extract.

A Python process solves both at once — PyMuPDF renders, TrOCR reads — which is
why the alternative of a hosted OCR API was not taken: it would have left the
rasterisation problem unsolved and added a native PDFium plugin to fix it.

## Setup

Python **3.12** is required. PyTorch does not support 3.13+, and the repository
root's `.venv` is 3.14 — left over from the retired `legacy_python/` port. Do
not reuse it.

```bash
uv venv --python 3.12 ocr_service/.venv
uv pip install --python ocr_service/.venv/bin/python -r ocr_service/requirements.txt
```

On the first scanned paper the recognition weights are downloaded to
`~/.cache/huggingface` (~1.4 GB for `trocr-large-handwritten`) and the line
detector to `~/.cache/doctr` (~110 MB). They are not committed and not shipped
in the installer.

`transformers` is pinned below 5.0 deliberately. TrOCR's checkpoints ship
RoBERTa BPE files with no `tokenizer.json`, and transformers 5 dropped the
slow-to-fast conversion path they depend on — `from_pretrained` fails outright
there, with or without `sentencepiece` installed.

## The engines

```
PDF or photograph
   │
   ├─ rasterize.py   PyMuPDF, one page at a time — never the whole document in memory
   ├─ preprocess.py  deskew (projection profile), denoise, even out contrast
   ├─ analyze.py     stage one: ink coverage and blank pages, ignoring exercise-book ruling
   ├─ render.py      writes the original, the cleaned page, and a preview for vision models
   ├─ detect.py      docTR DBNet word boxes (projection-profile fallback)
   ├─ layout.py      words → lines → blocks; graphics → table / graph / diagram;
   │                 strikes, question numbers, margins, headers, reading order
   ├─ recognize.py   TrOCR, with line and per-word confidence from token probabilities
   └─ regions.py     reads each region line by line and returns it whole; crops
```

Three details carry more weight than their size suggests.

**Layout decides what gets read, and as what.** A paragraph, a margin question
number, a diagram's labels and a crossed-out line are separate regions, so
nothing is glued to the text beside it just because it shares a baseline. Blocks
split on gaps, on a change in writing size (printed question text versus the
student's hand), and on indentation. What layout cannot establish it says so:
a page with graphics or unexplained ink is reported `needs_vision`, and the app
sends that page to a vision model. It never guesses printed versus handwritten.

**Confidence is derived, not reported.** TrOCR has no confidence output. It is
computed in `recognize.py` from the decoder's token log-probabilities — per line
as a geometric mean, and per word from that word's own tokens, so one smudged
word is an uncertain span rather than a weak line. On a scanned script correctly
read prose scores 0.97–1.00, while misread symbols (`+` as `t`, `=` as `-`)
score well below; the app's default threshold is 0.92.

**Crossed-out detection is conservative.** A strike is a long, near-straight
horizontal run of ink through the middle of a line. A fraction bar can pass that
test, so the confidence stays at 0.5 and the app keeps such a line in the answer
with a flag rather than discarding it.

## HTTP interface

Loopback only. Every request must carry the `x-ocr-token` header with the shared
secret the app passes at spawn time — the service opens whatever path it is
given, so without that check any local process could use it to read files.

| Route | Purpose |
|---|---|
| `GET /health` | Readiness, device, which models are resident |
| `POST /warmup` | Loads the recognition weights ahead of the first document |
| `POST /render` | `{path, out_dir, dpi, preview_max_dim}` → streams progress, then every page: image paths, size, text-layer flag and text, ink coverage, blank |
| `POST /layout` | `{pages: [{index, image_path}]}` → streams progress, then typed regions per page, with lines, word boxes, reading order and `needs_vision` |
| `POST /recognize` | `{pages: [{index, image_path, regions}], crops_dir, model, uncertain_below}` → streams progress, then one reading per region with lines and uncertain spans |
| `POST /crop` | `{image_path, out_dir, max_dim, regions: [{region_id, box}]}` → crop paths |
| `POST /shutdown` | Exits cleanly when the app closes |

Streaming routes send server-sent events: `{"type": "progress" | "done" |
"error", …}`. Errors are events, not HTTP failures, so a page that cannot be
rendered is named (`"page": 7`). Output files are written where the app says —
its cache — and left there.

## Packaging

```bash
uv pip install --python .venv/bin/python -r requirements-build.txt
.venv/bin/python packaging/build_sidecar.py              # build, then smoke-test
.venv/bin/python packaging/build_sidecar.py --skip-build # smoke-test only
```

PyInstaller builds `dist/exam-corrector-ocr/` from `packaging/exam-corrector-ocr.spec`
— a windowed executable (no console pops up when the app starts it) plus its
libraries, about 830 MB, most of it PyTorch. The smoke test starts the built
binary and drives `/health`, `/render`, `/layout` and `/recognize`, so a missing
hidden import fails the build rather than a teacher's first scan. Weights are
not bundled. Build on the platform you ship for: a Windows build must be made on
Windows. `flutter build windows` then copies the folder beside the app.

## Shutdown

The app stops the sidecar through `/shutdown` when its window closes. For the
cases where that cannot happen — the app killed, or crashing — it passes
`--parent-pid`, and `pipeline/watchdog.py` exits the sidecar within a couple of
seconds of the app disappearing (using `OpenProcess` on Windows, where probing a
process with a signal is unsafe).

## Running it by hand

```bash
# Render, layout and region recognition over one file, as the app drives them.
.venv/bin/python tools/run_pipeline.py ../sample/student_paper_handwritten.pdf

# Build a scanned-looking handwritten paper to test against.
.venv/bin/python tools/make_handwritten_sample.py

# The service itself.
.venv/bin/python app.py --port 8765 --token dev
```

`EXAM_CORRECTOR_OCR_DEVICE=cpu` forces CPU. Worth reaching for on Apple silicon:
MPS is much faster, but when a result looks wrong, forcing CPU is the quickest
way to tell a model problem from a backend one.

## Tests

```bash
.venv/bin/python -m pytest tests/ -v
```

Offline and fast — no weights are loaded. Layout is tested on synthetic pages
(text blocks, margin numbers, diagrams with labels, tables, graphs, strikes,
ruling, blank pages), rendering on generated mixed PDFs, region recognition and
word confidences with stub readers, deskew against known rotations, confidence
arithmetic against hand-built tensors, and the HTTP endpoints through FastAPI's
test client.
