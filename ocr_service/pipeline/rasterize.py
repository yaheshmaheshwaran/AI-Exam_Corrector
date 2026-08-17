"""Page rasterisation: a PDF or a photograph becomes a list of page images.

This is the step the Flutter side cannot do for itself. `syncfusion_flutter_pdf`
extracts a text layer but cannot render a page, so a scanned script has to come
through here before anything can read it.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

import numpy as np
import pymupdf

from PIL import Image

# A PDF page is 72 dpi in its own units; this is the scale factor to reach the
# requested raster resolution.
PDF_BASE_DPI = 72.0

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".webp"}

# TrOCR gains nothing above ~400 dpi and the memory cost is quadratic.
MIN_DPI = 100
MAX_DPI = 400


@dataclass
class PageImage:
    """One rendered page, on disk and in memory."""

    index: int
    path: str
    width: int
    height: int
    image: np.ndarray  # BGR, uint8 — OpenCV's convention


def rasterize(source_path: str, workdir: str, dpi: int = 300) -> list[PageImage]:
    """Renders `source_path` to one image per page.

    Accepts a PDF or a single photograph. Raises `ValueError` with a message
    that is safe to show a teacher.
    """
    if not os.path.isfile(source_path):
        raise ValueError(f"File not found: {source_path}")

    dpi = max(MIN_DPI, min(MAX_DPI, int(dpi)))
    pages_dir = os.path.join(workdir, "pages")
    os.makedirs(pages_dir, exist_ok=True)

    suffix = os.path.splitext(source_path)[1].lower()
    if suffix in IMAGE_SUFFIXES:
        return [_load_photograph(source_path, pages_dir)]
    if suffix == ".pdf":
        return _render_pdf(source_path, pages_dir, dpi)

    raise ValueError(
        f"Unsupported file type '{suffix}'. Supply a PDF or an image."
    )


def _render_pdf(source_path: str, pages_dir: str, dpi: int) -> list[PageImage]:
    zoom = dpi / PDF_BASE_DPI
    matrix = pymupdf.Matrix(zoom, zoom)

    try:
        document = pymupdf.open(source_path)
    except Exception as error:  # noqa: BLE001 - surfaced verbatim to the user
        raise ValueError(f"This PDF could not be opened: {error}") from error

    with document:
        if document.needs_pass:
            raise ValueError(
                "This PDF is password protected. Please supply an unlocked copy."
            )
        if document.page_count == 0:
            raise ValueError("This PDF has no pages.")

        pages: list[PageImage] = []
        for index in range(document.page_count):
            pixmap = document.load_page(index).get_pixmap(matrix=matrix, alpha=False)

            # PyMuPDF hands back RGB; OpenCV works in BGR throughout this
            # pipeline, so the channel flip happens once, here.
            buffer = np.frombuffer(pixmap.samples, dtype=np.uint8)
            rgb = buffer.reshape(pixmap.height, pixmap.width, pixmap.n)
            image = np.ascontiguousarray(rgb[:, :, ::-1])

            path = os.path.join(pages_dir, f"page_{index:03d}.png")
            Image.fromarray(rgb[:, :, :3]).save(path)

            pages.append(
                PageImage(
                    index=index,
                    path=path,
                    width=pixmap.width,
                    height=pixmap.height,
                    image=image,
                )
            )

    return pages


def _load_photograph(source_path: str, pages_dir: str) -> PageImage:
    try:
        with Image.open(source_path) as handle:
            rgb = handle.convert("RGB")
            array = np.asarray(rgb)
    except Exception as error:  # noqa: BLE001
        raise ValueError(f"This image could not be read: {error}") from error

    path = os.path.join(pages_dir, "page_000.png")
    Image.fromarray(array).save(path)

    return PageImage(
        index=0,
        path=path,
        width=array.shape[1],
        height=array.shape[0],
        image=np.ascontiguousarray(array[:, :, ::-1]),
    )
