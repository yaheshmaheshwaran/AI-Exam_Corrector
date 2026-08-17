# Handwriting OCR sidecar

Reads handwritten exam scripts so the application can mark them. It runs as a
child process of the Flutter app, bound to loopback, and is started on demand —
the first time a teacher opens a scan, never at launch.

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

## The pipeline

```
PDF or photograph
   │
   ├─ rasterize.py    PyMuPDF → one page image per page, at the requested dpi
   ├─ preprocess.py   deskew (projection profile), denoise, even out contrast
   ├─ detect.py       docTR DBNet word boxes, grouped into text lines
   ├─ recognize.py    TrOCR reads each line crop, and scores its own confidence
   └─ assemble.py     reading order, page markers, the response document
```

Two details carry more weight than their size suggests.

**Detection is the accuracy ceiling.** TrOCR is a *single-line* recogniser: it
turns one cropped line into one string and has no notion of layout. Everything
it can do depends on `detect.py` handing it well-formed lines. A classical
projection-profile detector stands behind DBNet so a machine that cannot reach
the weights still produces a usable result instead of failing.

**Confidence is derived, not reported.** TrOCR has no confidence output. It is
computed in `recognize.py` as the geometric mean of the decoder's per-token
probabilities — length-independent, so a two-word line and a twenty-word line
are comparable. That single number decides which lines get a second opinion from
the vision model, which the review screen highlights, and which reach the
teacher as a warning.

Measured on a scanned script, that number separates cleanly: correctly read
prose lands at 0.97–1.00, while every line TrOCR got wrong — `+` read as `t`,
`=` as `-`, `100 / 0.05` as `( 100 ) 0.05` — landed between 0.77 and 0.91. The
app's default threshold of 0.92 sits in that gap.

## HTTP interface

Loopback only. Every request must carry the `x-ocr-token` header with the shared
secret the app passes at spawn time — the service opens whatever path it is
given, so without that check any local process could use it to read files.

| Route | Purpose |
|---|---|
| `GET /health` | Readiness, device, which models are resident |
| `POST /warmup` | Loads the weights ahead of the first document |
| `POST /extract` | Streams progress, then the transcript, as server-sent events |
| `POST /shutdown` | Exits cleanly when the app closes |

`/extract` takes `{path, dpi, model, workdir}` and streams
`{"type": "progress" | "done" | "error", …}`. Page images and line crops are
written under `workdir` and left there: the review screen reads them back to
show each line beside the strip of page it came from.

## Running it by hand

```bash
# The whole pipeline over one file, with per-line confidences.
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

Offline and fast — no weights are loaded. Line grouping is tested as pure
geometry, deskew against known rotations, and the confidence arithmetic against
hand-built tensors, so the parts that are easy to get subtly wrong are pinned
down without waiting on a model.
