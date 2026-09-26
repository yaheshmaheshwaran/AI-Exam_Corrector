"""Region-level handwriting recognition.

The unit of recognition is a region — a paragraph, a margin note, a question
label — not a free-floating line. TrOCR can still only read one line at a time,
so each region is read line by line, but the lines are found *inside* the
region and returned *as* the region: one text in reading order, one confidence,
the lines it was built from, and the words the recogniser was unsure of, each
with its place on the page.

That keeps recognition subordinate to layout. A diagram label is read as part
of its diagram, a crossed-out line stays its own region, and nothing is glued to
the paragraph beside it just because it shares a baseline.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any, Callable, Sequence

import cv2
import numpy as np
from PIL import Image

from pipeline import detect

Box = tuple[int, int, int, int]

# Padding around a region crop, as a fraction of its height (min 4px), so
# strokes at the edge are not clipped.
CROP_PADDING = 0.04

# Words scoring below this are reported as uncertain spans. The app passes
# its own threshold; this is the fallback.
DEFAULT_UNCERTAIN_BELOW = 0.75


@dataclass
class RegionRequest:
    region_id: str
    box: Box
    lines: list[Box]
    line_words: list[list[Box]]


def parse_requests(raw: Sequence[dict[str, Any]]) -> list[RegionRequest]:
    requests: list[RegionRequest] = []
    for entry in raw:
        box = entry.get("box") or []
        if len(box) != 4:
            continue
        lines = [tuple(int(v) for v in line) for line in entry.get("lines") or [] if len(line) == 4]
        line_words = [
            [tuple(int(v) for v in word) for word in words if len(word) == 4]
            for words in entry.get("line_words") or []
        ]
        requests.append(
            RegionRequest(
                region_id=str(entry.get("region_id", "")),
                box=tuple(int(v) for v in box),
                lines=lines,
                line_words=line_words,
            )
        )
    return requests


def recognize_regions(
    page_image: np.ndarray,
    requests: Sequence[RegionRequest],
    crops_dir: str,
    page_index: int,
    read_crops: Callable[[list[Image.Image]], list[Any]],
    uncertain_below: float = DEFAULT_UNCERTAIN_BELOW,
) -> list[dict[str, Any]]:
    """Reads every requested region on one page.

    `read_crops` is the recogniser — `recognize.read_crops` in service, a stub
    in tests — taking line images and returning objects with `text`,
    `confidence` and `words`.
    """
    os.makedirs(crops_dir, exist_ok=True)
    height, width = page_image.shape[:2]

    plans: list[tuple[RegionRequest, str, list[Box], list[list[Box]]]] = []
    line_images: list[Image.Image] = []

    for request in requests:
        crop_path = _save_crop(page_image, request.box, crops_dir, page_index, request.region_id)
        lines, words = _lines_for(page_image, request)
        plans.append((request, crop_path, lines, words))
        for line in lines:
            patch = _cut(page_image, line)
            line_images.append(Image.fromarray(cv2.cvtColor(patch, cv2.COLOR_BGR2RGB)))

    readings = read_crops(line_images) if line_images else []

    results: list[dict[str, Any]] = []
    cursor = 0
    for request, crop_path, lines, words in plans:
        region_readings = readings[cursor : cursor + len(lines)]
        cursor += len(lines)
        results.append(
            _assemble(
                request,
                crop_path,
                lines,
                words,
                region_readings,
                width,
                height,
                uncertain_below,
            )
        )
    return results


def _lines_for(
    page_image: np.ndarray, request: RegionRequest
) -> tuple[list[Box], list[list[Box]]]:
    """The region's text lines: from layout when it found them, else detected
    inside the crop."""
    if request.lines:
        words = request.line_words if len(request.line_words) == len(request.lines) else [[] for _ in request.lines]
        return request.lines, words

    x, y, w, h = request.box
    patch = page_image[y : y + h, x : x + w]
    if patch.size == 0:
        return [], []
    try:
        found = detect.detect_lines(patch)
    except Exception:  # noqa: BLE001 - read the region whole rather than not at all
        found = []
    if not found:
        return [request.box], [[]]
    lines = [(x + line.x, y + line.y, line.width, line.height) for line in found]
    return lines, [[] for _ in lines]


def _assemble(
    request: RegionRequest,
    crop_path: str,
    lines: list[Box],
    line_words: list[list[Box]],
    readings: list[Any],
    width: int,
    height: int,
    uncertain_below: float,
) -> dict[str, Any]:
    text_lines: list[dict[str, Any]] = []
    spans: list[dict[str, Any]] = []
    offset = 0
    weighted = 0.0
    weight = 0

    for line, boxes, reading in zip(lines, line_words, readings):
        text = (reading.text or "").strip()
        if not text:
            continue
        confidence = float(reading.confidence)
        text_lines.append({"text": text, "confidence": round(confidence, 4), "box": list(line)})
        weighted += confidence * len(text)
        weight += len(text)

        # Words map onto the detector's word boxes only when the counts agree;
        # otherwise a span is placed on its line, which is still the right ink.
        words = list(reading.words or [])
        position = 0
        for index, (word, score) in enumerate(words):
            start = text.find(word, position)
            if start < 0:
                start = position
            end = start + len(word)
            position = end
            if score >= uncertain_below:
                continue
            box = boxes[index] if len(boxes) == len(words) else line
            spans.append(
                {
                    "text": word,
                    "confidence": round(float(score), 4),
                    "start": offset + start,
                    "end": offset + end,
                    "box": list(box),
                }
            )
        offset += len(text) + 1  # the newline joining lines

    full_text = "\n".join(line["text"] for line in text_lines)
    confidence = weighted / weight if weight else 0.0
    return {
        "region_id": request.region_id,
        "text": full_text,
        "confidence": round(confidence, 4),
        "illegible": not text_lines,
        "crop_path": crop_path,
        "lines": text_lines,
        "uncertain_spans": spans,
        "page_width": width,
        "page_height": height,
    }


def crop_regions(
    image_path: str,
    regions: Sequence[dict[str, Any]],
    out_dir: str,
    max_dim: int = 0,
    padding: float = 0.01,
) -> dict[str, str]:
    """Cuts normalised boxes out of a page image; returns region ID → path."""
    image = cv2.imread(image_path)
    if image is None:
        raise ValueError(f"The page image could not be read: {image_path}")
    os.makedirs(out_dir, exist_ok=True)
    height, width = image.shape[:2]

    paths: dict[str, str] = {}
    for region in regions:
        box = region.get("box") or []
        region_id = str(region.get("region_id", ""))
        if len(box) != 4 or not region_id:
            continue
        nx, ny, nw, nh = (float(v) for v in box)
        pad_x, pad_y = padding * width, padding * height
        left = max(0, int((nx * width) - pad_x))
        top = max(0, int((ny * height) - pad_y))
        right = min(width, int((nx + nw) * width + pad_x))
        bottom = min(height, int((ny + nh) * height + pad_y))
        if right <= left or bottom <= top:
            continue
        patch = _downscale(image[top:bottom, left:right], max_dim)
        path = os.path.join(out_dir, f"{_safe(region_id)}.png")
        cv2.imwrite(path, patch)
        paths[region_id] = path
    return paths


def _save_crop(
    image: np.ndarray, box: Box, crops_dir: str, page_index: int, region_id: str
) -> str:
    path = os.path.join(crops_dir, f"p{page_index:03d}_{_safe(region_id)}.png")
    cv2.imwrite(path, _cut(image, box, padding=CROP_PADDING))
    return path


def _cut(image: np.ndarray, box: Box, padding: float = 0.0) -> np.ndarray:
    height, width = image.shape[:2]
    x, y, w, h = box
    pad = max(int(h * padding), 4) if padding else 0
    left, top = max(0, x - pad), max(0, y - pad)
    right, bottom = min(width, x + w + pad), min(height, y + h + pad)
    patch = image[top:bottom, left:right]
    if patch.size == 0:
        return np.full((8, 8, 3), 255, dtype=np.uint8)
    return patch


def _downscale(image: np.ndarray, max_dim: int) -> np.ndarray:
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


def _safe(identifier: str) -> str:
    return "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in identifier)
