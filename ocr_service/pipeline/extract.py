"""The pipeline end to end: a file path in, a transcript document out.

Written as a generator of events rather than a blocking call. Transcribing a
seven-page script takes minutes, and without a running commentary the app's
status bar is indistinguishable from a hang — so every stage reports as it goes
and the finished document arrives as the last event.
"""

from __future__ import annotations

import os
import shutil
import tempfile
from typing import Any, Iterator

from pipeline import assemble, detect, preprocess, rasterize, recognize


def extract(
    source_path: str,
    dpi: int = 300,
    model_name: str = recognize.DEFAULT_MODEL,
    workdir: str | None = None,
) -> Iterator[dict[str, Any]]:
    """Yields `{"type": "progress"|"done"|"error", ...}` events.

    The caller owns `workdir` if it supplies one — the crops and page images
    stay on disk after this returns, because the review screen displays them.
    """
    owns_workdir = workdir is None
    workdir = workdir or tempfile.mkdtemp(prefix="exam_ocr_")
    os.makedirs(workdir, exist_ok=True)

    try:
        yield _progress("Rendering pages…", 0.0)
        pages = rasterize.rasterize(source_path, workdir, dpi=dpi)
        page_count = len(pages)

        crops_dir = os.path.join(workdir, "crops")
        assembled: list[dict[str, Any]] = []
        detector_used = "db_resnet50"

        for page in pages:
            position = page.index + 1

            yield _progress(
                f"Cleaning page {position} of {page_count}…",
                _fraction(page.index, page_count, 0.0),
            )
            cleaned = preprocess.preprocess(page.image)

            # The review screen shows the same image the boxes were measured
            # against, so the cleaned page replaces the raw render on disk.
            _write_page(cleaned, page.path)

            yield _progress(
                f"Finding text lines on page {position} of {page_count}…",
                _fraction(page.index, page_count, 0.25),
            )
            boxes = detect.detect_lines(cleaned)

            if not boxes:
                assembled.append(
                    assemble.build_page(
                        page.index, page.path, page.width, page.height, [], []
                    )
                )
                continue

            yield _progress(
                f"Reading {len(boxes)} lines on page {position} of {page_count}…",
                _fraction(page.index, page_count, 0.5),
            )

            transcriptions = recognize.recognize_lines(
                page_image=cleaned,
                boxes=boxes,
                crops_dir=crops_dir,
                page_index=page.index,
                model_name=model_name,
            )

            assembled.append(
                assemble.build_page(
                    page.index,
                    page.path,
                    page.width,
                    page.height,
                    boxes,
                    transcriptions,
                )
            )

        document = assemble.build_document(
            pages=assembled,
            engine=model_name,
            dpi=dpi,
            detector=detector_used,
        )
        document["workdir"] = workdir

        yield {"type": "done", "document": document}

    except ValueError as error:
        # Raised by the pipeline for conditions a teacher can act on.
        if owns_workdir:
            shutil.rmtree(workdir, ignore_errors=True)
        yield {"type": "error", "message": str(error)}

    except Exception as error:  # noqa: BLE001 - never take the app down
        if owns_workdir:
            shutil.rmtree(workdir, ignore_errors=True)
        yield {
            "type": "error",
            "message": f"The handwriting recogniser failed: {error}",
        }


def _write_page(image, path: str) -> None:
    import cv2

    cv2.imwrite(path, image)


def _progress(message: str, fraction: float) -> dict[str, Any]:
    return {
        "type": "progress",
        "message": message,
        "fraction": round(max(0.0, min(1.0, fraction)), 3),
    }


def _fraction(page_index: int, page_count: int, within_page: float) -> float:
    """Overall completion, treating each page as an equal share of the work."""
    if page_count <= 0:
        return 0.0
    return (page_index + within_page) / page_count
