"""HTTP front door for the local document-understanding engines.

Runs as a child process of the Flutter app, bound to loopback only. The app
spawns it on the first paper that needs rendering, polls `/health` until it
answers, then calls the region-centric endpoints: `/render` (pages),
`/layout` (regions), `/recognize` (handwriting, region by region) and `/crop`.

Requests must carry the shared token the app passed at spawn time. The service
opens whatever file path it is handed, so without that check any other process
on the machine could use it to read files it should not.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import signal
import sys
import threading
from typing import Any, Iterator

import cv2
import uvicorn
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from pipeline import layout, recognize, regions, render, watchdog

DEFAULT_PORT = 8765

# Set at startup; compared against the `x-ocr-token` header on every request.
_TOKEN = ""

app = FastAPI(title="Exam Corrector OCR", docs_url=None, redoc_url=None)


class RenderRequest(BaseModel):
    path: str = Field(..., description="Absolute path to a PDF or an image.")
    out_dir: str = Field(..., description="Where page images are written.")
    dpi: int = Field(300, ge=100, le=400)
    preview_max_dim: int = Field(render.DEFAULT_PREVIEW_MAX_DIM, ge=256, le=4096)


class LayoutPage(BaseModel):
    index: int
    image_path: str


class LayoutRequest(BaseModel):
    pages: list[LayoutPage]


class RecognizeRegion(BaseModel):
    region_id: str
    box: list[int] = Field(..., min_length=4, max_length=4)
    lines: list[list[int]] = Field(default_factory=list)
    line_words: list[list[list[int]]] = Field(default_factory=list)


class RecognizePage(BaseModel):
    index: int
    image_path: str
    regions: list[RecognizeRegion]


class RecognizeRequest(BaseModel):
    pages: list[RecognizePage]
    crops_dir: str
    model: str = Field(recognize.DEFAULT_MODEL)
    uncertain_below: float = Field(regions.DEFAULT_UNCERTAIN_BELOW, ge=0, le=1)


class CropRegion(BaseModel):
    region_id: str
    box: list[float] = Field(..., min_length=4, max_length=4)


class CropRequest(BaseModel):
    image_path: str
    out_dir: str
    max_dim: int = Field(0, ge=0, le=8192)
    padding: float = Field(0.01, ge=0, le=0.2)
    regions: list[CropRegion]


def _stream(events: Iterator[dict[str, Any]]) -> StreamingResponse:
    """Server-sent events from a generator of dicts.

    A sync generator is deliberate: Starlette runs it on a worker thread, which
    is exactly right for work that is busy in OpenCV or torch rather than
    waiting on I/O.
    """

    def encoded() -> Iterator[str]:
        for event in events:
            yield f"data: {json.dumps(event)}\n\n"

    return StreamingResponse(
        encoded(),
        media_type="text/event-stream",
        headers={"cache-control": "no-cache", "x-accel-buffering": "no"},
    )


def _authorise(token: str | None) -> None:
    if not _TOKEN:
        return
    if token is None or not secrets.compare_digest(token, _TOKEN):
        raise HTTPException(status_code=401, detail="Invalid or missing token.")


@app.get("/health")
def health(x_ocr_token: str | None = Header(default=None)) -> dict[str, Any]:
    _authorise(x_ocr_token)
    return {
        "status": "ok",
        "device": str(recognize.resolve_device()),
        "models_loaded": sorted(recognize._MODEL_CACHE.keys()),
        "default_model": recognize.DEFAULT_MODEL,
    }


@app.post("/warmup")
def warmup(
    model: str = recognize.DEFAULT_MODEL,
    x_ocr_token: str | None = Header(default=None),
) -> dict[str, Any]:
    """Loads the weights ahead of time.

    The first call on a new machine downloads well over a gigabyte. Doing it
    here lets the app say so plainly instead of appearing to stall partway
    through a teacher's first correction.
    """
    _authorise(x_ocr_token)
    try:
        loaded = recognize.load_model(model)
    except Exception as error:  # noqa: BLE001
        raise HTTPException(
            status_code=503,
            detail=f"The handwriting model could not be loaded: {error}",
        ) from error
    return {"status": "ready", "model": model, "device": str(loaded.device)}


@app.post("/render")
def render_document(
    request: RenderRequest,
    x_ocr_token: str | None = Header(default=None),
) -> StreamingResponse:
    """Renders every page: original, cleaned and preview images, plus the
    cheap stage-one measurements (text layer, ink coverage, blankness)."""
    _authorise(x_ocr_token)
    return _stream(
        render.render(
            request.path,
            request.out_dir,
            dpi=request.dpi,
            preview_max_dim=request.preview_max_dim,
        )
    )


@app.post("/layout")
def analyze_layout(
    request: LayoutRequest,
    x_ocr_token: str | None = Header(default=None),
) -> StreamingResponse:
    """Segments each page into typed regions with local computer vision."""
    _authorise(x_ocr_token)

    def events() -> Iterator[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        total = max(len(request.pages), 1)
        for position, page in enumerate(request.pages):
            yield {
                "type": "progress",
                "message": f"Finding regions on page {page.index + 1}…",
                "fraction": round(position / total, 3),
            }
            image = cv2.imread(page.image_path)
            if image is None:
                results.append(
                    {"index": page.index, "error": "The page image could not be read."}
                )
                continue
            try:
                result = layout.analyze_layout(image)
            except Exception as error:  # noqa: BLE001 - one page must not fail the rest
                results.append({"index": page.index, "error": str(error)})
                continue
            result["index"] = page.index
            results.append(result)
        yield {"type": "done", "pages": results}

    return _stream(events())


@app.post("/recognize")
def recognize_regions(
    request: RecognizeRequest,
    x_ocr_token: str | None = Header(default=None),
) -> StreamingResponse:
    """Reads handwriting region by region, with word-level uncertainty."""
    _authorise(x_ocr_token)

    def events() -> Iterator[dict[str, Any]]:
        try:
            recognize.load_model(request.model)
        except Exception as error:  # noqa: BLE001
            yield {
                "type": "error",
                "message": f"The handwriting model could not be loaded: {error}",
            }
            return

        def reader(crops):
            return recognize.read_crops(crops, model_name=request.model)

        results: list[dict[str, Any]] = []
        failures: list[dict[str, Any]] = []
        total = max(len(request.pages), 1)
        for position, page in enumerate(request.pages):
            yield {
                "type": "progress",
                "message": f"Reading handwriting on page {page.index + 1}…",
                "fraction": round(position / total, 3),
            }
            image = cv2.imread(page.image_path)
            if image is None:
                failures.extend(
                    {"region_id": r.region_id, "error": "The page image could not be read."}
                    for r in page.regions
                )
                continue
            try:
                results.extend(
                    regions.recognize_regions(
                        image,
                        regions.parse_requests([r.model_dump() for r in page.regions]),
                        request.crops_dir,
                        page.index,
                        reader,
                        uncertain_below=request.uncertain_below,
                    )
                )
            except Exception as error:  # noqa: BLE001 - keep the image, report the page
                failures.extend(
                    {"region_id": r.region_id, "error": str(error)} for r in page.regions
                )
        yield {
            "type": "done",
            "regions": results,
            "failures": failures,
            "engine": request.model,
        }

    return _stream(events())


@app.post("/crop")
def crop(
    request: CropRequest,
    x_ocr_token: str | None = Header(default=None),
) -> dict[str, Any]:
    """Cuts regions out of a page image, for display and for the vision model."""
    _authorise(x_ocr_token)
    try:
        paths = regions.crop_regions(
            request.image_path,
            [region.model_dump() for region in request.regions],
            request.out_dir,
            max_dim=request.max_dim,
            padding=request.padding,
        )
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    return {"crops": paths}


@app.post("/shutdown")
def shutdown(x_ocr_token: str | None = Header(default=None)) -> dict[str, str]:
    """Lets the app stop the sidecar cleanly when it closes."""
    _authorise(x_ocr_token)

    def stop() -> None:
        os.kill(os.getpid(), signal.SIGTERM)

    # Deferred so this request gets its response out first.
    threading.Timer(0.25, stop).start()
    return {"status": "stopping"}


def _ensure_streams() -> None:
    """A windowed build (no console) starts without stdout or stderr when not
    given pipes. Printing the ready line, or uvicorn logging, would then fail,
    so missing streams are pointed at the null device."""
    for name in ("stdout", "stderr"):
        if getattr(sys, name) is None:
            setattr(sys, name, open(os.devnull, "w", encoding="utf-8"))


def main() -> None:
    global _TOKEN

    _ensure_streams()

    parser = argparse.ArgumentParser(description="Exam Corrector OCR sidecar")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument(
        "--token",
        default=os.environ.get("EXAM_CORRECTOR_OCR_TOKEN", ""),
        help="Shared secret the app must send as the x-ocr-token header.",
    )
    parser.add_argument(
        "--parent-pid",
        type=int,
        default=0,
        help="Exit when this process ends — the app that started the sidecar.",
    )
    arguments = parser.parse_args()
    _TOKEN = arguments.token

    if arguments.parent_pid > 0:
        watchdog.watch_parent(arguments.parent_pid)

    # The app watches for this line to learn which port it actually got.
    print(f"OCR_SIDECAR_READY port={arguments.port}", flush=True)

    uvicorn.run(app, host=arguments.host, port=arguments.port, log_level="warning")


if __name__ == "__main__":
    main()
