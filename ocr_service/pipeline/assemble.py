"""Assembly of per-line results into the document contract the app consumes.

Structure only. The Dart side owns the conversion of this document into the
text the marking prompt sees, so the `--- Page N ---` convention lives in
exactly one place — `DocumentTranscript.toMarkedText()` — rather than being
half-implemented at each end of the wire.
"""

from __future__ import annotations

from typing import Any

PAGE_MARKER = "--- Page {number} ---"


def build_page(
    index: int,
    image_path: str,
    width: int,
    height: int,
    boxes: list,
    transcriptions: list,
) -> dict[str, Any]:
    """One page of the contract: its image, its size, and its lines in order."""
    lines: list[dict[str, Any]] = []

    for box, transcription in zip(boxes, transcriptions):
        text = transcription.text.strip()
        if not text:
            # A detected band that recognised to nothing is noise — a smudge, a
            # ruled line, a staple. Dropping it here keeps it out of the review
            # screen, where it would be pure friction for the teacher.
            continue

        lines.append(
            {
                "text": text,
                "confidence": round(float(transcription.confidence), 4),
                "box": box.box,
                "crop_path": transcription.crop_path,
            }
        )

    return {
        "index": index,
        "image_path": image_path,
        "width": width,
        "height": height,
        "lines": lines,
    }


def build_document(
    pages: list[dict[str, Any]],
    engine: str,
    dpi: int,
    detector: str,
) -> dict[str, Any]:
    """The full response body for `/extract`."""
    line_count = sum(len(page["lines"]) for page in pages)
    confidences = [
        line["confidence"] for page in pages for line in page["lines"]
    ]

    return {
        "pages": pages,
        "engine": engine,
        "detector": detector,
        "dpi": dpi,
        "line_count": line_count,
        "mean_confidence": round(sum(confidences) / len(confidences), 4)
        if confidences
        else 0.0,
    }


def to_marked_text(document: dict[str, Any]) -> str:
    """Debug and test convenience — *not* the contract.

    The app builds its own marking text from the structured pages so that
    teacher edits made in the review screen are included. This exists so the
    Python tests and the CLI can eyeball a page without a Flutter runtime.
    """
    blocks: list[str] = []
    for page in document["pages"]:
        body = "\n".join(line["text"] for line in page["lines"])
        blocks.append(f"{PAGE_MARKER.format(number=page['index'] + 1)}\n{body}".strip())
    return "\n\n".join(blocks).strip()
