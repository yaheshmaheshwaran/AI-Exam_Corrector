"""HTTP front door for the handwriting OCR pipeline.

Runs as a child process of the Flutter app, bound to loopback only. The app
spawns it on the first scanned paper, polls `/health` until it answers, then
streams `/extract`.

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
import threading
from typing import Any, Iterator

import uvicorn
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from pipeline import extract as extract_pipeline
from pipeline import recognize

DEFAULT_PORT = 8765

# Set at startup; compared against the `x-ocr-token` header on every request.
_TOKEN = ""

app = FastAPI(title="Exam Corrector OCR", docs_url=None, redoc_url=None)


class ExtractRequest(BaseModel):
    path: str = Field(..., description="Absolute path to a PDF or an image.")
    dpi: int = Field(300, ge=100, le=400)
    model: str = Field(recognize.DEFAULT_MODEL)
    workdir: str | None = Field(
        None,
        description="Where page images and crops are written. The caller owns "
        "it, because the review screen reads them back.",
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


@app.post("/extract")
def extract(
    request: ExtractRequest,
    x_ocr_token: str | None = Header(default=None),
) -> StreamingResponse:
    """Streams progress, then the finished transcript, as server-sent events."""
    _authorise(x_ocr_token)

    def events() -> Iterator[str]:
        for event in extract_pipeline.extract(
            source_path=request.path,
            dpi=request.dpi,
            model_name=request.model,
            workdir=request.workdir,
        ):
            yield f"data: {json.dumps(event)}\n\n"

    # A sync generator here is deliberate: Starlette runs it on a worker thread,
    # which is exactly right for a pipeline that is busy in torch rather than
    # waiting on I/O.
    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"cache-control": "no-cache", "x-accel-buffering": "no"},
    )


@app.post("/shutdown")
def shutdown(x_ocr_token: str | None = Header(default=None)) -> dict[str, str]:
    """Lets the app stop the sidecar cleanly when it closes."""
    _authorise(x_ocr_token)

    def stop() -> None:
        os.kill(os.getpid(), signal.SIGTERM)

    # Deferred so this request gets its response out first.
    threading.Timer(0.25, stop).start()
    return {"status": "stopping"}


def main() -> None:
    global _TOKEN

    parser = argparse.ArgumentParser(description="Exam Corrector OCR sidecar")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument(
        "--token",
        default=os.environ.get("EXAM_CORRECTOR_OCR_TOKEN", ""),
        help="Shared secret the app must send as the x-ocr-token header.",
    )
    arguments = parser.parse_args()
    _TOKEN = arguments.token

    # The app watches for this line to learn which port it actually got.
    print(f"OCR_SIDECAR_READY port={arguments.port}", flush=True)

    uvicorn.run(app, host=arguments.host, port=arguments.port, log_level="warning")


if __name__ == "__main__":
    main()
