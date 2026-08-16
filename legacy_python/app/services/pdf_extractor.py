"""PDF validation and text extraction.

Deliberately isolated from the UI and from the AI layer: this module turns a
path on disk into plain text, or raises PdfExtractionError with a message that
is safe to show a teacher.
"""

from __future__ import annotations

import os

from pypdf import PdfReader
from pypdf.errors import PyPdfError

from app.config import MAX_PDF_BYTES

# Below this many characters we assume the PDF carries no real text layer
# (typically a scan or a photo of a handwritten script).
MIN_USEFUL_CHARS = 40


class PdfExtractionError(Exception):
    """Raised when a PDF cannot be read or contains no usable text."""


def extract_text(path: str) -> str:
    """Return the text content of `path`, page by page.

    Raises PdfExtractionError for anything the teacher needs to act on:
    missing file, wrong format, corrupt file, encrypted file, or a scan with no
    text layer.
    """
    _validate_file(path)

    try:
        reader = PdfReader(path)
    except PyPdfError as exc:
        raise PdfExtractionError(f"This PDF could not be read: {exc}") from exc
    except Exception as exc:  # pypdf can raise plain exceptions on bad input
        raise PdfExtractionError(f"This file is not a readable PDF: {exc}") from exc

    if reader.is_encrypted:
        # An empty user password is common; try it before giving up.
        try:
            if reader.decrypt("") == 0:
                raise PdfExtractionError(
                    "This PDF is password protected. Please supply an unlocked copy."
                )
        except PdfExtractionError:
            raise
        except Exception as exc:
            raise PdfExtractionError(
                f"This PDF is password protected and could not be opened: {exc}"
            ) from exc

    if not reader.pages:
        raise PdfExtractionError("This PDF has no pages.")

    pages: list[str] = []
    for index, page in enumerate(reader.pages, start=1):
        try:
            text = page.extract_text() or ""
        except Exception:  # a single unreadable page should not fail the paper
            text = ""
        pages.append(f"--- Page {index} ---\n{text.strip()}")

    combined = "\n\n".join(pages).strip()

    if len(_strip_page_markers(combined)) < MIN_USEFUL_CHARS:
        raise PdfExtractionError(
            "No readable text was found in this PDF. It is most likely a scan or "
            "photograph. Please supply a PDF with a text layer."
        )

    return combined


def _validate_file(path: str) -> None:
    if not path:
        raise PdfExtractionError("No file was selected.")
    if not os.path.isfile(path):
        raise PdfExtractionError(f"File not found: {path}")
    if not path.lower().endswith(".pdf"):
        raise PdfExtractionError("Only PDF files are supported.")

    size = os.path.getsize(path)
    if size == 0:
        raise PdfExtractionError("This file is empty.")
    if size > MAX_PDF_BYTES:
        raise PdfExtractionError(
            f"This PDF is {size / 1_048_576:.1f} MB, which exceeds the "
            f"{MAX_PDF_BYTES // 1_048_576} MB limit."
        )

    with open(path, "rb") as handle:
        if handle.read(5) != b"%PDF-":
            raise PdfExtractionError("This file is not a valid PDF.")


def _strip_page_markers(text: str) -> str:
    return "\n".join(
        line for line in text.splitlines() if not line.startswith("--- Page ")
    ).strip()
