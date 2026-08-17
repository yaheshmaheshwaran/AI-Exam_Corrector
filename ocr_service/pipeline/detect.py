"""Text-line detection.

TrOCR is a *single-line* recogniser: it turns one cropped line into one string
and has no notion of page layout. Everything it can do therefore depends on
this module handing it well-formed line crops, which makes detection — not
recognition — the real accuracy ceiling of the pipeline.

Primary detector is docTR's DBNet, which finds word boxes; those are grouped
into lines here. A classical projection-profile detector stands behind it so a
machine that cannot reach the DBNet weights still produces a usable result.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass

import cv2
import numpy as np

# Word boxes below this are scanner speckle, not writing (at 300 dpi).
MIN_WORD_HEIGHT_PX = 8
MIN_WORD_WIDTH_PX = 4

# Two words share a line when their vertical extents overlap by at least this
# fraction of the shorter one. Handwriting wanders, so this is forgiving.
LINE_OVERLAP_RATIO = 0.4

# Crops are padded so ascenders and descenders are not clipped; TrOCR loses
# accuracy on a line shaved flush to the x-height.
CROP_PADDING_RATIO = 0.18
MIN_CROP_PADDING_PX = 3

_DETECTOR = None
_DETECTOR_LOCK = threading.Lock()


@dataclass
class LineBox:
    """One detected text line, in absolute pixel coordinates."""

    x: int
    y: int
    width: int
    height: int

    @property
    def box(self) -> list[int]:
        return [self.x, self.y, self.width, self.height]


def detect_lines(image: np.ndarray) -> list[LineBox]:
    """Finds text lines in a preprocessed BGR page, in reading order."""
    try:
        words = _detect_words_doctr(image)
    except Exception:  # noqa: BLE001 - a detector failure must not lose the page
        words = []

    if not words:
        return _detect_lines_projection(image)

    lines = group_words_into_lines(words)
    return [_pad(line, image.shape) for line in lines]


def _load_detector():
    """Loads DBNet once, on first use. Import is deferred: pulling in torch and
    docTR costs seconds and memory that a text-layer PDF never needs to spend.
    """
    global _DETECTOR
    if _DETECTOR is not None:
        return _DETECTOR

    with _DETECTOR_LOCK:
        if _DETECTOR is None:
            from doctr.models import detection_predictor

            _DETECTOR = detection_predictor(
                arch="db_resnet50",
                pretrained=True,
                assume_straight_pages=True,
            )
    return _DETECTOR


def _detect_words_doctr(image: np.ndarray) -> list[tuple[int, int, int, int]]:
    predictor = _load_detector()

    # docTR expects RGB; the pipeline carries BGR.
    rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
    result = predictor([rgb])
    if not result:
        return []

    page = result[0]
    raw = page.get("words") if isinstance(page, dict) else page
    if raw is None or len(raw) == 0:
        return []

    height, width = image.shape[:2]
    boxes: list[tuple[int, int, int, int]] = []

    for entry in np.asarray(raw):
        # Straight pages give [xmin, ymin, xmax, ymax, score]; rotated pages give
        # four corner points. Reduce both to an axis-aligned box.
        flat = np.asarray(entry, dtype=np.float64).reshape(-1)
        if flat.size >= 8:
            points = flat[:8].reshape(4, 2)
            x_min, y_min = points.min(axis=0)
            x_max, y_max = points.max(axis=0)
        else:
            x_min, y_min, x_max, y_max = flat[:4]

        left = int(round(x_min * width))
        top = int(round(y_min * height))
        right = int(round(x_max * width))
        bottom = int(round(y_max * height))

        if right - left < MIN_WORD_WIDTH_PX or bottom - top < MIN_WORD_HEIGHT_PX:
            continue
        boxes.append((left, top, right - left, bottom - top))

    return boxes


def group_words_into_lines(
    words: list[tuple[int, int, int, int]],
) -> list[LineBox]:
    """Clusters word boxes into text lines by vertical overlap.

    Pure function over box geometry, so it is unit-testable without a model.
    """
    if not words:
        return []

    # Top-to-bottom; within the sweep, a word either extends the open line or
    # starts the next one.
    ordered = sorted(words, key=lambda box: box[1] + box[3] / 2.0)

    clusters: list[list[tuple[int, int, int, int]]] = []
    current: list[tuple[int, int, int, int]] = [ordered[0]]
    top, bottom = ordered[0][1], ordered[0][1] + ordered[0][3]

    for word in ordered[1:]:
        word_top = word[1]
        word_bottom = word[1] + word[3]

        overlap = min(bottom, word_bottom) - max(top, word_top)
        shorter = min(bottom - top, word_bottom - word_top)

        if shorter > 0 and overlap / shorter >= LINE_OVERLAP_RATIO:
            current.append(word)
            # Widen the band so a tall capital does not detach the rest.
            top = min(top, word_top)
            bottom = max(bottom, word_bottom)
        else:
            clusters.append(current)
            current = [word]
            top, bottom = word_top, word_bottom

    clusters.append(current)

    lines: list[LineBox] = []
    for cluster in clusters:
        left = min(box[0] for box in cluster)
        top = min(box[1] for box in cluster)
        right = max(box[0] + box[2] for box in cluster)
        bottom = max(box[1] + box[3] for box in cluster)
        lines.append(LineBox(left, top, right - left, bottom - top))

    lines.sort(key=lambda line: (line.y + line.height / 2.0, line.x))
    return lines


def _detect_lines_projection(image: np.ndarray) -> list[LineBox]:
    """Fallback detector: horizontal ink bands on a deskewed page.

    Much weaker than DBNet — it cannot separate columns and it merges lines that
    touch — but it needs no weights, so the service degrades instead of failing
    when the DBNet download is unavailable.
    """
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    binary = cv2.threshold(
        gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU
    )[1]

    # Smear each line horizontally so its words fuse into one band.
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (max(image.shape[1] // 40, 15), 1))
    smeared = cv2.dilate(binary, kernel, iterations=1)

    rows = smeared.sum(axis=1) > 0
    lines: list[LineBox] = []
    start: int | None = None

    for index, filled in enumerate(rows):
        if filled and start is None:
            start = index
        elif not filled and start is not None:
            lines.append(_band_to_line(binary, start, index))
            start = None
    if start is not None:
        lines.append(_band_to_line(binary, start, len(rows)))

    return [
        _pad(line, image.shape)
        for line in lines
        if line.height >= MIN_WORD_HEIGHT_PX and line.width >= MIN_WORD_WIDTH_PX
    ]


def _band_to_line(binary: np.ndarray, top: int, bottom: int) -> LineBox:
    band = binary[top:bottom]
    columns = np.flatnonzero(band.sum(axis=0) > 0)
    if columns.size == 0:
        return LineBox(0, top, 0, bottom - top)
    left, right = int(columns[0]), int(columns[-1]) + 1
    return LineBox(left, top, right - left, bottom - top)


def _pad(line: LineBox, shape: tuple[int, ...]) -> LineBox:
    height, width = shape[:2]
    padding = max(int(round(line.height * CROP_PADDING_RATIO)), MIN_CROP_PADDING_PX)

    left = max(0, line.x - padding)
    top = max(0, line.y - padding)
    right = min(width, line.x + line.width + padding)
    bottom = min(height, line.y + line.height + padding)

    return LineBox(left, top, right - left, bottom - top)
