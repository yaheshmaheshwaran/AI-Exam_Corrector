# Architecture

Exam Corrector marks a student's answer sheet against the question paper it was
sat from. This document describes how it understands a handwritten script —
pages, regions, evidence, answers — before any mark is given, and how each mark
stays traceable to the ink it was awarded for.

The governing principle:

> **OCR is not the exam-understanding system. It is one evidence-extraction
> component inside it.** The scanned page is the source of truth and is never
> replaced by text. Every piece of extracted information keeps its page, its
> box, its crop, its type, its question and its confidence.

---

## 1. Where it came from

The previous architecture was a text pipeline:

```
PDF ─► text layer, or: render ─► DBNet lines ─► TrOCR per line ─► one string
    ─► Gemini (question paper text + answer string) ─► marks
```

- The sidecar found text *lines* and TrOCR read each one. The app flattened
  them into `--- Page N ---` text and sent that one string to the model, which
  both mapped answers to questions and marked them.
- Diagrams, graphs, tables and equations were either misread as lines or lost.
- The model saw no images, so a misread `=` became a wrong answer.
- Marks cited nothing; alignment was invisible; a failure anywhere restarted
  everything.

What was kept, because it was sound: the Gemini transport (`GeminiClient` —
streaming, retries, error translation), the model fallback chain, the sidecar
process manager and its token, PyMuPDF rendering, OpenCV clean-up, DBNet word
detection, TrOCR with derived confidence, the validation rules (marks capped,
totals recomputed locally), the configuration model, the Fluent theme, and the
question-number patterns (now in `question_label_detector.dart`).

What was replaced: the line transcript model, the ingest service that flattened
it, the line-level cross-check, the text-only correction prompt and service, and
the line review screen. They were removed once their replacements were tested;
their transport tests were ported to `GeminiModelClient`.

---

## 2. The pipeline

```
Question paper PDF ─► text layer ─► deterministic parser ──(untrusted?)──► model extraction
                  └─► scanned ───► render ─► vision extraction
                                         │
                                         ▼
                              QuestionPaper  (structural authority)

Answer sheet PDF/image
   │
   ├─ 1  Render            sidecar /render   original + cleaned + preview image per page,
   │                                         one page at a time; text-layer flag; ink coverage
   ├─ 2  Analyse pages     DefaultPageAnalyzer   blank → skip · text layer → exact · else detect
   ├─ 3  Detect regions    TextLayerRegionDetector | Hybrid(Local, Vision)  + crops
   ├─ 4  Read handwriting  Ensemble(TrOCR regions, vision second opinion)
   ├─ 5  Align             LabelBoundaryDetector ─► PaperQuestionAligner
   ├─ 6  Analyse visuals   diagrams · graphs · tables · equations
   ├─ 7  Reconstruct       EvidenceAnswerReconstructor  one StudentAnswer per question
   └─ 8  Mark              ModelMarkingEngine ─► MarkingValidator
                                         │
                                         ▼
                 CorrectionResult (AI)  +  TeacherReviewBook (teacher)  ─► UI, export
```

`ExamPipeline` (`lib/pipeline/exam_pipeline.dart`) runs the stages, caches each
stage's output, reports a `ProcessingJob`, and honours cancellation. Handwriting
is read *before* alignment because labels such as `2 (a)` are found in the
recognised text; visual analysis runs *after* alignment so each diagram can be
analysed with the question it answers as context.

### Stage 1 — Render (document engine)

`SidecarDocumentRenderer` → sidecar `/render` (`ocr_service/pipeline/render.py`).
Pages stream one at a time (`rasterize.iter_pages`), so a 200-page script never
sits in memory on either side. For each page:

| File | Purpose |
|---|---|
| `page_NNN.png` | the render, untouched — the student's paper is never lost to clean-up |
| `page_NNN_clean.png` | deskewed, denoised, contrast-normalised; **every region box is measured against this image** |
| `page_NNN_preview.jpg` | the clean page at `EXAM_CORRECTOR_MAX_IMAGE_DIM`, for vision models |

A page with a text layer is not deskewed, so PDF coordinates stay valid on its
image. The app only ever holds paths; images load when shown, at display
resolution (`cacheWidth`).

Without the sidecar, a typed document still works: `ExamPipeline` builds pages
from the text layer alone and warns that page images are unavailable. A scanned
document without the sidecar fails at this stage with a message naming it.

### Stage 2 — Page analysis

Cheap, local, no model: `DefaultPageAnalyzer` routes each page from the render's
measurements — blank pages are skipped by every later stage; text-layer pages
are read exactly; the rest go to layout detection.

### Stage 3 — Region detection (page understanding)

Regions are typed (`RegionType`): `printed_text`, `question_number`,
`handwritten_answer`, `diagram`, `graph`, `table`, `equation`, `label`,
`crossed_out`, `margin_note`, `header`, `footer`, `unknown`. Boxes are
normalised (`NormalizedBox`, fractions of the page) so they are independent of
render resolution.

| Detector | How | Strengths / limits |
|---|---|---|
| `TextLayerRegionDetector` | PDF text lines with positions, grouped into blocks | exact and free; typed documents only |
| `LocalRegionDetector` → `/layout` (`layout.py`) | DBNet words → lines split at wide gaps → blocks split on gap, writing size and indentation; ink no word explains → graphics, classified by ruled lines (table: grid; graph: axes; else diagram); strike detection; margins, headers, footers; reading order | free, offline; does not claim printed vs handwritten; no equation detection; reports `needs_vision` when it sees graphics or unexplained ink |
| `VisionRegionDetector` | page previews to the vision model, `box_2d` regions with types, labels, verbatim transcription, uncertain words | best understanding; costs a request per `EXAM_CORRECTOR_PAGES_PER_REQUEST` pages |
| `HybridRegionDetector` (default) | local for every page; vision only for pages local analysis flags | nearly all of a prose script costs no request |

`EXAM_CORRECTOR_LAYOUT_ENGINE` chooses `hybrid`, `vision` or `local`. Every
region is then cropped (`/crop`) for display and for models.

### Stage 4 — Handwriting, region by region

`EnsembleHandwritingRecognizer` combines readings; nothing edits text:

1. A text-layer reading is exact and final.
2. TrOCR reads every other textual region (`/recognize`, `regions.py`): lines
   are found *inside the region* (layout's lines, or DBNet on the crop), read,
   and returned as one region reading with per-line confidence and per-word
   confidence (`words_from_tokens`: BPE tokens grouped into words, each scored
   by its own tokens). Low-scoring words become `UncertainSpan`s placed on
   their own word box.
3. A region still uncertain — low confidence overall, **any line** below the
   threshold, or any word below 0.5 — is shown to the vision model
   (`VisionHandwritingRecognizer`, crops batched ten per request).
   A region local layout only *suspects* is struck through is always shown
   too: the reader is asked whether the writing is crossed out, and its
   yes/no (`HandwritingReading.crossedOut`) settles it.
4. With two machine readings, the vision reading is primary and their
   `agreement` is recorded — against a *confident* second reading only (≥ 0.85);
   TrOCR misreading a lone label, and knowing it, is not a disagreement.
   Agreement ≥ 0.95 lifts the evidence's confidence; a real disagreement flags
   the region. Every reading is kept.
5. A region that missed a reading only because an engine was unreachable (a
   rate limit, a recogniser not yet started) is tagged as retryable, and the
   next run re-reads just those regions.

Raw recognition is deliberately context-free. Context — the question, the
subject — is applied later by the marking model and recorded as an
`InterpretedReading` beside the raw text, never in place of it.

### Stage 5 — Answer boundaries and question alignment

`LabelBoundaryDetector` walks every region of every page in reading order.
A region that opens with a question label — or a `question_number` region, or
the label the vision model reported — starts a new `AnswerSegment`; everything
up to the next label belongs to it, diagrams and page breaks included. Headers
and footers never join an answer. Two things real scripts do are handled
explicitly:

- **A block holding two answers** (the end of Q4 and the start of Q5 with no
  gap) is split at the line where the label appears. The parts become derived
  regions (`parentRegionId`), with boxes from the line geometry and the reading
  sliced, uncertain spans re-offset. The parent's evidence is kept.
- **A page that starts mid-answer** opens a continuation segment the aligner
  joins to the previous answer, at reduced confidence.

`QuestionLabelDetector` recognises `1`, `1.`, `Q1`, `Question 1`, `2 (a)`,
`2a)`, `2 ( a )`, `(b)`, `(ii)`, `3(b)(ii)`, `Q2(b) continued`, and resolves a
bare part against the answer being read. It under-detects on purpose and **is
checked against the question paper**: `50 micrometres = 0.05 mm` and `12.5 mol`
are not labels because the paper has no question 50 or 12; `Answer: 50 …` is
not a label either. A label repeating the paper's own wording (a booklet that
reprints its questions) or coming next in the paper's order is near-certain.

`PaperQuestionAligner` maps segments to the paper's questions:

| Case | Mapping |
|---|---|
| label matches a question | `label` |
| page continues without a label | `continuation` (0.85) |
| label names a question with parts | shared with every part, `parentLabel` (×0.7) |
| label has a part the paper lacks (`3(a)` vs `3`) | the nearest question, noted |
| paper has one question, no label | `soleQuestion` (0.8) |
| before the first label | preamble — kept, not suspected |
| label the paper does not contain | unmatched — reported, never marked |

The question paper is the authority: nothing on the answer sheet adds a
question or changes a maximum.

### Stage 6 — Visual evidence

`VisualEvidenceEngine` routes each visual region to its analyser; the vision
implementation (`VisionVisualAnalyzer`) has a schema per kind:

| Kind | Extracted |
|---|---|
| diagram | description, labels, components, relationships |
| graph | axes, plotted elements, approximate values, trend, labels |
| table | cells row by row, crossed-out cells |
| equation | LaTeX exactly as written, plain text |

Every analyser describes what is visible and never adds what a correct answer
would contain. The kinds run side by side, at most two requests in flight — a
free tier counts requests per minute, and a burst of four trips it. Analysis
that fails is recorded (`AnalysisStatus.failed`, reason) and the image is still
shown to the marker; the next run retries only the failed analyses.

**Equations inside writing.** Local layout cannot see an equation — to it,
`= 100 / 0.05` is a line like any other. Once the writing has been read,
though, working is recognisable by its content: `EquationPromoter` (run at the
end of alignment, when regions are final) turns each run of mathematical lines
inside a handwritten region into a derived `equation` region with its own crop.
It is read as mathematics here and shown to the marker as an image; the parent
region keeps its text, and the derived region joins whatever answer its parent
belongs to. Equations the vision model already found are not duplicated.

### Stage 7 — Answer reconstruction

`EvidenceAnswerReconstructor` assembles one `StudentAnswer` per markable
question: text evidence (with raw text, teacher text, uncertain spans, second
reading), visual evidence, visual region IDs (analysed or not), crossed-out
work (apart), pages, and two confidences — how well the content read, how sure
the mapping is — plus teacher-facing flags. Two policies matter:

- **Crossed-out work.** `strikeLikelihood` combines local layout's suspicion
  (confidence 0.5) with the vision reader's verdict: a confirmed strike (0.85)
  moves the region out of the answer into `crossedOut`; a rejected one (0.2)
  stays in, unflagged; an unconfirmed suspicion stays in the answer and is
  flagged — a weak signal never silently removes what a student wrote. A
  strike only the vision model saw counts too.
- **Printed question text.** A region whose text is the paper's own wording
  for the question is retyped as `printed_text`: context, not answer, and not
  counted in how well the answer read.

### Stage 8 — Multimodal marking

`ModelMarkingEngine` marks in batches (`EXAM_CORRECTOR_QUESTIONS_PER_REQUEST`,
and an image budget per request). Each question is sent with its wording,
maximum, section and instructions, the teacher's guidance, every region of the
answer as text with `{?uncertain?}` words marked and second readings shown,
structured visual evidence, crossed-out work (labelled), and **images**: every
visual region, and every text region with doubtful reading. Region IDs are sent
as short aliases (`R1`) and mapped back.

The model returns, per question: marking points (source teacher/inferred,
marks available, marks awarded, evidence region IDs, basis
observed/inferred/uncertain), awarded marks, a faithful summary, an
explanation, confidence, review flag and reasons, and interpreted readings.

A question with no answer scores zero without a request.

`MarkingValidator` enforces what the prompt asks for:

- the maximum is the paper's whenever it printed one;
- a point awards between 0 and its worth; the question's mark is the sum of its
  points, capped at the maximum, whatever total the model reported;
- a scheme worth more than the maximum is capped and flagged;
- evidence must name regions of *this* answer — others are dropped; a mark with
  no evidence is marked `uncertain` and flagged;
- confidence = min(model's, answer read confidence, mapping confidence); below
  `EXAM_CORRECTOR_REVIEW_THRESHOLD`, or any uncertain award, or an unprinted
  maximum → `needsReview`, with the reasons listed.

The prompt also holds the model to the question's own wording: items a
question lists ("label the nucleus, the cell membrane and the cytoplasm",
"label both axes") are marking points in their own right; a wrong label earns
nothing and counts against any point about the drawing being correct; a point
the student contradicts elsewhere is not awarded.

Returned question IDs are resolved as labels (`8`, `Q 8` and `Q8` are the same
question), because lighter fallback models do not copy identifiers faithfully.
A question the model still skips is retried once on its own, then handed to the
teacher unmarked — never given an invented zero silently.

---

## 3. Domain model

`lib/domain/` — independent of Flutter, providers and storage; every class
round-trips through JSON because every stage is cached.

| Model | Role |
|---|---|
| `SelectedDocument` | a validated, fingerprinted file (hash, pages, text layer) |
| `ExamDocument` / `ExamPage` | pages with image paths, size, dpi, blank flag, regions |
| `PageRegion` | ID, page, `RegionType`, `NormalizedBox`, confidence, reading order, origin, parent, crop, detected label/text, line and word boxes |
| `HandwritingEvidence` / `HandwritingReading` / `UncertainSpan` / `RecognizedLine` | every reading of a region, primary choice, agreement, teacher text |
| `VisualEvidence` → `DiagramEvidence`, `GraphEvidence`, `TableEvidence`, `EquationEvidence` | visual analysis, or why there is none |
| `QuestionPaper` / `QuestionSection` / `Question` / `QuestionLabel` | the structural authority; labels normalise `2 (a)` → key `2.a`, ID `Q2a` |
| `AnswerSegment` / `QuestionAlignment` / `AlignmentResult` | boundaries and mapping, with methods and confidence |
| `StudentAnswer` / `TextEvidenceItem` | one reconstructed answer per question |
| `QuestionResult` (the per-question MarkingResult) / `MarkingPoint` / `InterpretedReading` | marks with evidence, basis, confidence, review state |
| `CorrectionResult` | the AI's marks for the paper; totals always recomputed |
| `TeacherReview` / `TeacherReviewBook` | the teacher's decisions, beside — never inside — the AI's result |
| `ProcessingJob` / `ProcessingStage` / `ProcessingCounts` | progress, completed and reused stages, failure point |
| `ExamAssessment` | everything one run produced; `result` may be null while the rest is complete |

`QuestionResult` and `CorrectionResult` pre-date this design and were extended
rather than duplicated, so the result screens and validation rules carried
over.

---

## 4. Engines and providers

`lib/pipeline/engines.dart` defines one interface per engine: `DocumentInspector`,
`DocumentRenderer`, `TextLayerReader`, `PageAnalyzer`, `RegionDetector`,
`RegionCropper`, `HandwritingRecognizer`, `DiagramAnalyzer`, `GraphAnalyzer`,
`TableAnalyzer`, `EquationRecognizer`, `QuestionPaperExtractor`,
`AnswerBoundaryDetector`, `QuestionAligner`, `AnswerReconstructor`,
`MarkingEngine`.

Every model call goes through `ModelClient` (`lib/services/ai/model_client.dart`):
text and image parts in, schema-constrained JSON out, with a model list to fall
back through. `GeminiModelClient` is the only implementation and the only code
that knows the provider; `main.dart` is the only place it is named. Adding a
provider means one new `ModelClient`.

`PipelineFactory` builds the pipeline from configuration for each correction,
so a change in Settings applies to the next run. Tests build `ExamPipeline`
directly with fakes.

| Role | Setting | Default |
|---|---|---|
| marking model (+ fallbacks) | `EXAM_CORRECTOR_MODEL`, `EXAM_CORRECTOR_FALLBACK_MODELS` | `gemini-3.6-flash`, chain |
| vision model (layout, handwriting check, scanned paper) | `EXAM_CORRECTOR_VISION_MODEL` | the marking model |
| diagram model | `EXAM_CORRECTOR_DIAGRAM_MODEL` | the vision model |
| handwriting model | `EXAM_CORRECTOR_TROCR_MODEL` | `microsoft/trocr-large-handwritten` |
| API endpoint | `EXAM_CORRECTOR_API_ENDPOINT` | Gemini Interactions |
| local endpoint | `EXAM_CORRECTOR_OCR_ENDPOINT`, `EXAM_CORRECTOR_OCR_TOKEN` | spawn the sidecar |
| timeout, retries | `EXAM_CORRECTOR_TIMEOUT_SECONDS`, `EXAM_CORRECTOR_RETRIES` | 300 s idle, 2 |
| thresholds | `EXAM_CORRECTOR_OCR_THRESHOLD`, `EXAM_CORRECTOR_REVIEW_THRESHOLD` | 0.92, 0.7 |
| images | `EXAM_CORRECTOR_OCR_DPI`, `EXAM_CORRECTOR_MAX_IMAGE_DIM`, `EXAM_CORRECTOR_MAX_IMAGES_PER_REQUEST` | 300, 1600, 16 |

Keys come from the environment, the Settings dialog (per-user profile) or
`.env`, never from source.

---

## 5. Caching and resume

`ArtifactStore` (`lib/pipeline/cache/artifact_store.dart`) keeps each stage's
output at `<app support>/cache/docs/<document hash>/<stage>-<fingerprint>.json`,
with page images and crops in sibling folders. Document identity is a SHA-256
of the file's bytes; a stage's fingerprint covers its engine, its settings and
the keys of the stages it depends on. Consequences:

- an unchanged pair of files re-runs from cache in seconds;
- a run interrupted at any stage resumes at that stage — marking is cached per
  question as each batch returns, so an interruption loses at most one batch;
- a teacher's correction to one transcription changes one answer, so only that
  question is re-marked;
- deterministic stages carry a version in their key (`align:v3`,
  `local-layout:v2`, `marking:v3`), bumped when their logic changes;
- failures worth retrying are not treated as final: failed visual analyses and
  readings that missed an unreachable engine are redone on the next run,
  everything else is reused.

Writes are atomic (temporary file, then rename); an unreadable artifact is a
cache miss. The last `ProcessingJob` per pair is saved, so choosing the same
files again offers to resume. Teacher reviews and transcription corrections are
stored beside the cache (`teacher-*`) and survive "Clear processing cache".
`EXAM_CORRECTOR_CACHE=false` disables reuse.

---

## 6. Errors

Every layer throws an `AppException` carrying a message written for a teacher.

| Failure | Behaviour |
|---|---|
| unreadable, encrypted, oversized PDF | refused when chosen (`LocalDocumentInspector`) |
| page fails to render | `PipelineException` naming the page |
| sidecar unavailable | typed documents continue from the text layer; scans stop with setup instructions; hybrid layout falls back to the vision model |
| vision model unavailable | local layout stands; pages that needed a better look are named |
| handwriting recognition fails | region kept with failed evidence; its image goes to the marker |
| visual analysis fails | image kept, reason recorded, marker judges from the image |
| question mapping uncertain | lower mapping confidence → review flag |
| marking model unavailable | job fails *at marking*; every extracted answer is kept and shown; marking again resumes |
| rate limited | a per-minute limit (Gemini's `quotaId` says `PerMinute`) waits and retries the same model; a spent daily quota (`PerDay`) moves straight to the next model in the chain |
| a class set stops partway | the scripts already marked are kept; marking all again continues from the one that stopped |
| cancelled | `CancelledException`; finished stages stay cached |

The original paper is never modified; the original render is kept beside the
cleaned one.

---

## 7. Teacher review

- **Results** — one row per question: final mark, review / accepted / changed,
  confidence. The total counts the teacher's marks where they overrode, and
  shows the AI total beside it.
- **Question detail** (`lib/screens/results/question_detail_screen.dart`) — the
  question and its maximum; the student's answer region by region: the crop of
  the original ink, the recognised text with uncertain words highlighted, the
  second reading when engines disagreed, visual analysis; crossed-out work
  apart; readings the marker interpreted in context; marking points with ✓/✗,
  marks, basis and evidence chips; the reasoning; confidence and review
  reasons; the teacher panel.
- **Evidence on the page** — every evidence chip and every region opens the
  original page with that region highlighted (and its uncertain words marked).
- **Corrections** — a transcription can be corrected; the machine reading is
  kept, and re-marking re-marks only the affected question.
- **Overrides** — accept, or set a mark with a comment. Stored as a
  `TeacherReview` with the AI mark, the teacher mark, the comment and the time;
  the AI result is never overwritten.
- **Page inspector** (developer mode) — every region on every page with type,
  reading order, confidence, origin, question, answer segment, readings, lines,
  spans and visual analysis; filter by type; answer-boundary view.
- **Export** — CSV (gradebook), HTML (printable), JSON (the full record with
  evidence locations). Every format carries both marks for every question.

---

## 8. Code map

```
lib/
  domain/            the models above — no Flutter, no providers
  pipeline/
    engines.dart     the engine interfaces
    exam_pipeline.dart   stage orchestration, caching, jobs
    pipeline_factory.dart   configuration → implementations
    cache/           ArtifactStore
    document/        inspector, sidecar renderer, text-layer reader, page analyser
    layout/          text-layer, local, vision and hybrid detectors; cropper
    recognition/     TrOCR regions, vision reader, ensemble, equation promoter,
                     text similarity
    questions/       parser, model extractor, question tree
    alignment/       label detector, boundary detector, aligner
    visual/          vision analyser, visual evidence engine
    reconstruction/  answer reconstructor
    marking/         prompt, validator, engine
  services/
    ai/              ModelClient, GeminiModelClient, GeminiClient (transport)
    ocr/             sidecar process manager, sidecar client
    export/          report exporter
    review/          teacher work store
    pdf_service.dart, settings_store.dart, file_picker_service.dart
  state/             the workflow controller; MarkedScript (one student)
  screens/           home, question detail, page inspector
  widgets/           uploads, guidance, processing, results, class results,
                     page viewer, settings
ocr_service/
  app.py             /health /warmup /render /layout /recognize /crop /shutdown
  pipeline/          rasterize, preprocess, analyze, render, detect, layout,
                     recognize, regions, watchdog
  packaging/         PyInstaller spec and build-and-smoke-test script
```

---

## 9. Decisions worth knowing

- **Hybrid layout by default.** Free-tier quotas are counted in requests, and a
  typical script is mostly prose that local analysis handles. Only pages with
  graphics or unexplained ink cost a vision request.
- **Local layout never claims printed vs handwritten.** Stroke statistics
  cannot tell them apart reliably, and misfiling an answer as printing would
  drop it from marking. Printed question text is instead recognised by its
  similarity to the paper.
- **Raw recognition is context-free; context lives in marking.** Asking the
  recogniser to use the question would make it read what ought to be there.
- **The vision reading is primary when two engines read a region**, because it
  has broader training — but the disagreement is kept and flagged.
- **Labels are validated against the paper.** The paper is the authority for
  what exists; the answer sheet can only point at it.
- **Unanswered questions cost nothing** and score zero deterministically.
- **The teacher's decisions are a separate record**, so the AI's proposal and
  the teacher's decision are both always visible and exportable.

## 10. Class sets

The controller holds a list of `MarkedScript`s — one per student — sharing one
question paper and one set of guidance; each keeps its own assessment, reviews
and transcription corrections. Choosing several files at once makes a class.
"Mark all" runs the scripts one after another through the same cached
pipeline, skipping those already marked (and re-marking those whose
transcriptions were corrected). A marking failure — most often a spent quota —
stops the batch instead of failing identically for every remaining student;
marking all again continues from there. The class table shows each student's
status, final mark (with overrides) and the class average; a row opens that
student's questions; "Export class…" writes one gradebook CSV with a column per
question.

## 11. Packaging and shutdown

`ocr_service/packaging/build_sidecar.py` builds the sidecar with PyInstaller
(`exam-corrector-ocr.spec`) into a self-contained `ocr_service/dist/
exam-corrector-ocr/` folder, then smoke-tests the built binary: `/health`,
`/render`, `/layout` and `/recognize` (TrOCR loaded through `transformers`,
the likeliest missing hidden import). Model weights are not bundled; they
download to the user's cache on first use. On Windows, `flutter build windows`
copies that folder beside the executable as `ocr_service/`, where
`SidecarProcessService` looks for `exam-corrector-ocr.exe`; the check runs at
install time, so packaging after the first build still takes effect.

The sidecar never outlives the app: closing the window raises an exit request
(`AppLifecycleListener`) that stops it first, SIGTERM does the same where Dart
can watch it (not Windows), and — for a kill that skips both — the app passes
`--parent-pid` and the sidecar's watchdog exits once that process is gone.

## 12. Extension points

- **Another model provider**: implement `ModelClient`.
- **A local vision model** (e.g. a layout model or handwriting VLM served
  locally): implement `RegionDetector` or `HandwritingRecognizer`, or expose it
  through the sidecar; add to `PipelineFactory`.
- **Equations written apart from any paragraph** on a locally analysed page
  (a lone line of working in empty space) become their own handwritten region
  and are promoted like any other; a detector working from ink geometry alone
  would catch them before recognition.
- **Marking scripts of a class concurrently**: scripts run one at a time today,
  which keeps within per-minute limits; a paid tier could run two or three.
- **Scanned question papers offline**: the local layout + TrOCR path could feed
  the deterministic parser; today a scanned paper needs the vision model.
