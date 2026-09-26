"""The document engine's rendering stage, as a stream of events.

Every page is written three ways, because each has a different job:

- `page_NNN.png` — the render exactly as it came out of the PDF. Never
  modified; the student's paper is preserved even if clean-up goes wrong.
- `page_NNN_clean.png` — deskewed and contrast-normalised. Every region box is
  measured against this image, so it is the one the teacher inspects.
- `page_NNN_preview.jpg` — the clean page scaled down for the vision model,
  which gains nothing from 300 dpi and is charged for every pixel.

A page with a text layer is not deskewed: its region boxes come from the PDF's
own coordinates, and rotating the image would move the ink out from under them.
"""

from __future__ import annotations

import os
from typing import Any, Iterator

import cv2

from pipeline import analyze, preprocess, rasterize

DEFAULT_PREVIEW_MAX_DIM = 1600

# A page with at least this many text-layer characters is read from its text
# layer rather than treated as a scan.
TEXT_LAYER_MIN_CHARS = 40


def render(
    source_path: str,
    out_dir: str,
    dpi: int = 300,
    preview_max_dim: int = DEFAULT_PREVIEW_MAX_DIM,
) -> Iterator[dict[str, Any]]:
    """Yields `progress` events, then one `done` event carrying every page."""
    os.makedirs(out_dir, exist_ok=True)
    pages: list[dict[str, Any]] = []

    try:
        yield _progress("Opening the document…", 0.0)
        for page in rasterize.iter_pages(source_path, out_dir, dpi=dpi):
            position = page.index + 1
            total = max(page.page_count, 1)
            yield _progress(
                f"Rendering page {position} of {total}…",
                page.index / total,
                page=position,
                pages=total,
            )
            pages.append(_finish_page(page, dpi, preview_max_dim))
            # The pixels are on disk now; letting go of them here is what keeps
            # a long script's memory flat.
            del page

        yield {
            "type": "done",
            "pages": pages,
            "page_count": len(pages),
            "dpi": rasterize.clamp_dpi(dpi),
        }
    except ValueError as error:
        yield {"type": "error", "message": str(error)}
    except Exception as error:  # noqa: BLE001 - never take the app down
        failed_at = len(pages) + 1
        yield {
            "type": "error",
            "message": f"Page {failed_at} could not be rendered: {error}",
            "page": failed_at,
        }


def _finish_page(
    page: rasterize.PageImage, dpi: int, preview_max_dim: int
) -> dict[str, Any]:
    has_text_layer = page.text_chars >= TEXT_LAYER_MIN_CHARS
    base = os.path.splitext(page.path)[0]

    if has_text_layer:
        clean = page.image
        skew = 0.0
    else:
        skew = preprocess.estimate_skew(page.image)
        clean = preprocess.preprocess(page.image)

    clean_path = f"{base}_clean.png"
    cv2.imwrite(clean_path, clean)

    preview_path = f"{base}_preview.jpg"
    cv2.imwrite(
        preview_path,
        _downscale(clean, preview_max_dim),
        [int(cv2.IMWRITE_JPEG_QUALITY), 88],
    )

    stats = analyze.page_stats(clean)
    return {
        "index": page.index,
        "original_path": page.path,
        "image_path": clean_path,
        "preview_path": preview_path,
        "width": int(clean.shape[1]),
        "height": int(clean.shape[0]),
        "dpi": rasterize.clamp_dpi(dpi),
        "has_text_layer": has_text_layer,
        "text_chars": page.text_chars,
        "text": page.text if has_text_layer else "",
        "skew_degrees": round(float(skew), 3),
        **stats,
    }


def _downscale(image, max_dim: int):
    height, width = image.shape[:2]
    longest = max(height, width)
    if max_dim <= 0 or longest <= max_dim:
        return image
    scale = max_dim / float(longest)
    return cv2.resize(
        image,
        (max(1, int(width * scale)), max(1, int(height * scale))),
        interpolation=cv2.INTER_AREA,
    )


def _progress(message: str, fraction: float, **extra: Any) -> dict[str, Any]:
    return {
        "type": "progress",
        "message": message,
        "fraction": round(max(0.0, min(1.0, fraction)), 3),
        **extra,
    }
