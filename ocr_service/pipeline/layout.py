"""Local page layout analysis: a page image becomes typed regions.

This is the cheap, offline half of page understanding. It does not try to be
as good as a vision model — it tries to be honest about what classical
computer vision can establish, and to say so through its confidences:

- Text is found with DBNet word boxes, grouped into lines, split at wide
  horizontal gaps (so a question number in the margin is not glued to the
  answer beside it), then grouped into paragraph blocks.
- Ink that no text box explains — drawn shapes, axes, grids — is gathered into
  graphic regions and classified as a table (a grid of ruled lines), a graph
  (perpendicular axes) or a diagram (anything else). Words inside a graphic
  become its labels rather than separate paragraphs.
- A text line with one long, straight, near-horizontal stroke through its
  middle is reported as possibly crossed out.

It never claims printed versus handwritten text: stroke statistics cannot tell
them apart reliably, and misfiling a student's answer as printed matter would
drop it from marking. Pages where this analysis is out of its depth — any
graphics at all, or a lot of ink it could not explain — are reported with
`needs_vision`, and the app sends those pages to the vision model instead.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Sequence

import cv2
import numpy as np

from pipeline import analyze

Box = tuple[int, int, int, int]  # x, y, width, height in pixels

# Page bands, as fractions of page height, for running headers and footers.
HEADER_BAND = 0.06
FOOTER_BAND = 0.94

# A horizontal gap wider than this many word-heights splits a line in two.
LINE_SPLIT_GAP_HEIGHTS = 3.5

# Two lines join one block when the gap between them is under this many
# line-heights.
BLOCK_GAP_LINE_HEIGHTS = 1.35

# A graphic must cover at least this fraction of the page, and be at least
# this tall and wide, to be more than a stray mark.
MIN_GRAPHIC_AREA = 0.006
MIN_GRAPHIC_HEIGHT = 0.03
MIN_GRAPHIC_WIDTH = 0.05

# Ink outside every region beyond this fraction of all ink means the local
# analysis missed something worth a vision model's look.
UNCOVERED_INK_LIMIT = 0.2

# Exercise-book ruling spans nearly the whole width, and there are many lines.
RULING_MIN_WIDTH = 0.7
RULING_MIN_LINES = 5


@dataclass
class Region:
    type: str
    box: Box
    confidence: float
    lines: list[Box] = field(default_factory=list)
    line_words: list[list[Box]] = field(default_factory=list)
    reasons: list[str] = field(default_factory=list)
    parent: int | None = None


def analyze_layout(
    image: np.ndarray,
    words: Sequence[Box] | None = None,
) -> dict[str, Any]:
    """Segments one cleaned BGR page into typed regions, in reading order.

    `words` can be supplied (tests do); otherwise DBNet finds them, and if it
    cannot, the projection-profile fallback finds whole lines instead.
    """
    height, width = image.shape[:2]
    detector = "dbnet+cv"

    if words is None:
        words, detector = _find_words(image)
    words = [tuple(int(v) for v in word) for word in words if word[2] > 0 and word[3] > 0]

    binary = analyze.ink_mask(image)
    content = cv2.subtract(binary, _ruling(binary))

    pieces = _line_pieces(words, width)
    graphics = _graphic_boxes(content, words, width, height)

    regions: list[Region] = []
    reasons: list[str] = []

    # Graphics first: their labels must be claimed before paragraphs are built.
    claimed: set[int] = set()
    for graphic in graphics:
        kind, confidence, why = classify_graphic(content, graphic)
        labels = [
            index
            for index, piece in enumerate(pieces)
            if index not in claimed
            and (
                _coverage(piece.box, graphic) >= 0.6
                or _labels_edge(piece, graphic, width, height)
            )
        ]
        box = graphic
        for index in labels:
            box = _union(box, pieces[index].box)
        parent = len(regions)
        regions.append(Region(kind, box, confidence, reasons=why))
        for index in labels:
            claimed.add(index)
            regions.append(
                Region(
                    "label",
                    pieces[index].box,
                    0.5,
                    lines=[pieces[index].box],
                    line_words=[pieces[index].words],
                    reasons=[f"text inside the {kind}"],
                    parent=parent,
                )
            )
        reasons.append(f"{kind} found")

    free = [piece for index, piece in enumerate(pieces) if index not in claimed]
    body_left = _body_left(free, width)

    numbers: list[_Piece] = []
    struck: list[tuple[_Piece, float]] = []
    prose: list[_Piece] = []
    for piece in free:
        if _is_question_number(piece, body_left, width):
            numbers.append(piece)
            continue
        strike = strike_through_confidence(content, piece.box)
        if strike > 0:
            struck.append((piece, strike))
        else:
            prose.append(piece)

    for piece in numbers:
        regions.append(
            Region(
                "question_number",
                piece.box,
                0.55,
                lines=[piece.box],
                line_words=[piece.words],
                reasons=["short text left of the answer column"],
            )
        )

    for piece, strike in struck:
        regions.append(
            Region(
                "crossed_out",
                piece.box,
                strike,
                lines=[piece.box],
                line_words=[piece.words],
                reasons=["long straight stroke through the line"],
            )
        )

    for block in _blocks(prose):
        regions.append(_classify_block(block, width, height, body_left))

    ordered = _reading_order(regions, height)
    uncovered = _uncovered_ink(content, [region.box for region in ordered])

    needs_vision = bool(graphics)
    if not words:
        needs_vision = True
        reasons.append("no text could be located")
    if uncovered > UNCOVERED_INK_LIMIT:
        needs_vision = True
        reasons.append(f"{uncovered:.0%} of the ink is outside every region")

    return {
        "width": width,
        "height": height,
        "detector": detector,
        "needs_vision": needs_vision,
        "reasons": reasons,
        "uncovered_ink": round(uncovered, 4),
        "regions": [_to_json(region, index) for index, region in enumerate(ordered)],
    }


# --------------------------------------------------------------------------- #
# Words and lines
# --------------------------------------------------------------------------- #


@dataclass
class _Piece:
    words: list[Box]

    @property
    def box(self) -> Box:
        return _union_all(self.words)

    @property
    def word_height(self) -> float:
        return float(np.median([word[3] for word in self.words]))


def _find_words(image: np.ndarray) -> tuple[list[Box], str]:
    from pipeline import detect

    try:
        words = detect._detect_words_doctr(image)
        if words:
            return words, "dbnet+cv"
    except Exception:  # noqa: BLE001 - fall back rather than lose the page
        pass

    lines = detect._detect_lines_projection(image)
    return [line.box for line in lines], "projection+cv"


def cluster_lines(words: Sequence[Box]) -> list[list[Box]]:
    """Groups word boxes into text lines by vertical overlap."""
    if not words:
        return []
    ordered = sorted(words, key=lambda box: box[1] + box[3] / 2.0)
    clusters: list[list[Box]] = [[ordered[0]]]
    top, bottom = ordered[0][1], ordered[0][1] + ordered[0][3]

    for word in ordered[1:]:
        word_top, word_bottom = word[1], word[1] + word[3]
        overlap = min(bottom, word_bottom) - max(top, word_top)
        shorter = min(bottom - top, word_bottom - word_top)
        if shorter > 0 and overlap / shorter >= 0.4:
            clusters[-1].append(word)
            top, bottom = min(top, word_top), max(bottom, word_bottom)
        else:
            clusters.append([word])
            top, bottom = word_top, word_bottom
    return clusters


def _line_pieces(words: Sequence[Box], page_width: int) -> list[_Piece]:
    """Lines, split wherever a gap is too wide to be a space between words."""
    pieces: list[_Piece] = []
    for cluster in cluster_lines(words):
        cluster.sort(key=lambda box: box[0])
        height = float(np.median([word[3] for word in cluster]))
        split_gap = max(LINE_SPLIT_GAP_HEIGHTS * height, 0.06 * page_width)

        current = [cluster[0]]
        for word in cluster[1:]:
            previous_right = max(box[0] + box[2] for box in current)
            if word[0] - previous_right > split_gap:
                pieces.append(_Piece(current))
                current = [word]
            else:
                current.append(word)
        pieces.append(_Piece(current))
    return pieces


def _body_left(pieces: Sequence[_Piece], page_width: int) -> float:
    """Left edge of the main answer column: where substantial lines start."""
    lefts = [piece.box[0] for piece in pieces if piece.box[2] > 0.2 * page_width]
    if not lefts:
        return 0.0
    return float(np.percentile(lefts, 25))


def _is_question_number(piece: _Piece, body_left: float, page_width: int) -> bool:
    x, _, w, _ = piece.box
    short = w < 0.08 * page_width and len(piece.words) <= 2
    left_of_body = x + w < body_left + 0.01 * page_width
    return short and left_of_body and body_left > 0.04 * page_width


def _blocks(pieces: Sequence[_Piece]) -> list[list[_Piece]]:
    """Joins consecutive lines into paragraph blocks.

    Spacing alone is not enough: an answer booklet sets printed question text,
    the student's answer and the next question at almost the same line pitch.
    What does change at those boundaries is the size of the writing, the
    indentation, or a gap wider than the paragraph's own line spacing — so any
    of those starts a new block.
    """
    blocks: list[list[_Piece]] = []
    for piece in sorted(pieces, key=lambda p: (p.box[1], p.box[0])):
        placed = False
        for block in reversed(blocks):
            if _continues(block, piece):
                block.append(piece)
                placed = True
                break
        if not placed:
            blocks.append([piece])
    return blocks


def _continues(block: list[_Piece], piece: _Piece) -> bool:
    x, y, w, h = piece.box
    last = block[-1].box
    line_height = max(float(np.median([p.box[3] for p in block])), h)
    gap = y - (last[1] + last[3])
    if gap > BLOCK_GAP_LINE_HEIGHTS * line_height:
        return False

    block_height = float(np.median([p.word_height for p in block]))
    ratio = max(block_height, piece.word_height) / max(min(block_height, piece.word_height), 1.0)
    if ratio > 1.45:
        return False

    lefts = [p.box[0] for p in block]
    if abs(float(np.median(lefts)) - x) > 1.5 * line_height:
        return False

    if len(block) >= 2:
        gaps = [
            block[i].box[1] - (block[i - 1].box[1] + block[i - 1].box[3])
            for i in range(1, len(block))
        ]
        usual = max(float(np.median(gaps)), 0.0)
        if gap > max(1.8 * usual, 0.35 * line_height):
            return False

    bx, _, bw, _ = _union_all([p.box for p in block])
    overlap = min(bx + bw, x + w) - max(bx, x)
    return overlap > 0


def _classify_block(
    block: list[_Piece], width: int, height: int, body_left: float
) -> Region:
    box = _union_all([piece.box for piece in block])
    x, y, w, h = box
    lines = [piece.box for piece in block]
    line_words = [piece.words for piece in block]

    if y + h < HEADER_BAND * height and len(block) <= 2:
        return Region("header", box, 0.5, lines, line_words, ["top band of the page"])
    if y > FOOTER_BAND * height and len(block) <= 2:
        return Region("footer", box, 0.5, lines, line_words, ["bottom band of the page"])
    if x > 0.85 * width and w < 0.15 * width:
        return Region("margin_note", box, 0.45, lines, line_words, ["right margin"])
    if body_left > 0.08 * width and x + w < body_left - 0.01 * width:
        return Region("margin_note", box, 0.4, lines, line_words, ["left margin"])

    # Deliberately not "printed" versus "handwritten": see the module notes.
    return Region(
        "handwritten_answer",
        box,
        0.6,
        lines,
        line_words,
        [f"{len(block)} line(s) of text"],
    )


# --------------------------------------------------------------------------- #
# Graphics
# --------------------------------------------------------------------------- #


def _ruling(binary: np.ndarray) -> np.ndarray:
    """Exercise-book ruling only: many lines spanning nearly the full width.

    A table's rules and a graph's axes are kept — they are the graphic.
    """
    width = binary.shape[1]
    kernel = cv2.getStructuringElement(
        cv2.MORPH_RECT, (max(int(width * RULING_MIN_WIDTH), 20), 1)
    )
    long_lines = cv2.morphologyEx(binary, cv2.MORPH_OPEN, kernel)
    count, _ = cv2.connectedComponents(long_lines)
    if count - 1 < RULING_MIN_LINES:
        return np.zeros_like(binary)
    return cv2.dilate(long_lines, np.ones((3, 1), np.uint8))


def _graphic_boxes(
    content: np.ndarray, words: Sequence[Box], width: int, height: int
) -> list[Box]:
    """Ink no text box explains, grouped into candidate graphics."""
    text_mask = np.zeros_like(content)
    for x, y, w, h in words:
        pad = max(2, h // 8)
        cv2.rectangle(text_mask, (x - pad, y - pad), (x + w + pad, y + h + pad), 255, -1)

    residue = cv2.bitwise_and(content, cv2.bitwise_not(text_mask))
    reach = max(width // 80, 5)
    joined = cv2.dilate(residue, np.ones((reach, reach), np.uint8))

    count, _, stats, _ = cv2.connectedComponentsWithStats(joined, connectivity=8)
    boxes: list[Box] = []
    page_area = float(width * height)
    for index in range(1, count):
        x, y, w, h, _ = (int(v) for v in stats[index])
        if w * h < MIN_GRAPHIC_AREA * page_area:
            continue
        if h < MIN_GRAPHIC_HEIGHT * height or w < MIN_GRAPHIC_WIDTH * width:
            continue
        # The dilation grew the box; the ink inside decides whether it is real.
        ink = int(cv2.countNonZero(residue[y : y + h, x : x + w]))
        if ink < 0.002 * w * h * 4 and ink < 400:
            continue
        # Mostly text boxes with a few stray strokes is text, not a figure.
        if _text_coverage((x, y, w, h), words) > 0.5:
            continue
        boxes.append((x, y, w, h))

    return _merge_boxes(boxes, gap=max(width // 60, 8))


# A label beside a drawing — at the end of a pointer line, a tick value, an
# axis title — sits just outside the drawing's ink. Short text this close to a
# graphic's edge is taken as its label; anything longer is left alone, so a
# paragraph written next to a diagram is never swallowed by it.
LABEL_GAP_X = 0.035
LABEL_GAP_Y = 0.03
LABEL_MAX_WIDTH = 0.25
LABEL_MAX_WORDS = 3


def _labels_edge(piece: "_Piece", graphic: Box, width: int, height: int) -> bool:
    px, py, pw, ph = piece.box
    gx, gy, gw, gh = graphic
    if pw > LABEL_MAX_WIDTH * width or len(piece.words) > LABEL_MAX_WORDS:
        return False
    gap_x = max(gx - (px + pw), px - (gx + gw), 0)
    gap_y = max(gy - (py + ph), py - (gy + gh), 0)
    beside = gap_y == 0 and gap_x <= LABEL_GAP_X * width
    below_or_above = gap_x == 0 and gap_y <= LABEL_GAP_Y * height
    return beside or below_or_above


def classify_graphic(content: np.ndarray, box: Box) -> tuple[str, float, list[str]]:
    """Table, graph or diagram, from the straight lines inside the box."""
    x, y, w, h = box
    patch = content[y : y + h, x : x + w]
    if patch.size == 0:
        return "diagram", 0.4, ["empty graphic"]

    horizontal = _straight_lines(patch, axis=0, fraction=0.5)
    vertical = _straight_lines(patch, axis=1, fraction=0.5)

    if len(horizontal) >= 3 and len(vertical) >= 2:
        return "table", 0.7, [
            f"{len(horizontal)} horizontal and {len(vertical)} vertical rules"
        ]

    if horizontal and vertical:
        low_axis = any(position > 0.55 * h for position in horizontal)
        left_axis = any(position < 0.45 * w for position in vertical)
        if low_axis and left_axis:
            return "graph", 0.55, ["perpendicular axes at the lower left"]

    return "diagram", 0.55, ["drawn content with no grid or axes"]


def _straight_lines(patch: np.ndarray, axis: int, fraction: float) -> list[int]:
    """Positions of straight ruled lines spanning `fraction` of the patch."""
    height, width = patch.shape[:2]
    if axis == 0:
        length = max(int(width * fraction), 10)
        kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (length, 1))
    else:
        length = max(int(height * fraction), 10)
        kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (1, length))

    lines = cv2.morphologyEx(patch, cv2.MORPH_OPEN, kernel)
    count, _, stats, centroids = cv2.connectedComponentsWithStats(lines)
    positions = [
        int(centroids[index][1] if axis == 0 else centroids[index][0])
        for index in range(1, count)
    ]
    return _dedupe(sorted(positions), tolerance=6)


def strike_through_confidence(content: np.ndarray, box: Box) -> float:
    """How likely it is that a line of writing has been struck through.

    A strike is a long, thin, near-straight stroke through the middle of the
    line. Writing itself almost never contains a continuous horizontal run of
    ink across most of a line, so the test is: rotate the line a few degrees
    either way, and look for a single pixel row in the middle band whose
    longest ink run spans at least half the line. A fraction bar in working
    can pass that test too, which is why the confidence stays modest — the app
    keeps such a line in the answer and flags it rather than discarding it.
    """
    x, y, w, h = box
    if w < 2.5 * h or h < 6:
        return 0.0
    patch = content[y : y + h, x : x + w]
    if patch.size == 0:
        return 0.0

    for angle in (0.0, -2.0, 2.0, -4.0, 4.0, -6.0, 6.0):
        rotated = patch if angle == 0.0 else _rotate(patch, angle)
        band = rotated[int(0.25 * h) : int(0.75 * h) + 1]
        if band.size == 0:
            continue
        if _longest_run(band) >= 0.55 * w:
            return 0.5
    return 0.0


def _longest_run(band: np.ndarray) -> int:
    longest = 0
    for row in band > 0:
        if not row.any():
            continue
        padded = np.concatenate(([False], row, [False]))
        edges = np.flatnonzero(np.diff(padded.astype(np.int8)))
        runs = edges[1::2] - edges[0::2]
        if runs.size:
            longest = max(longest, int(runs.max()))
    return longest


def _rotate(patch: np.ndarray, angle: float) -> np.ndarray:
    height, width = patch.shape[:2]
    matrix = cv2.getRotationMatrix2D((width / 2.0, height / 2.0), angle, 1.0)
    return cv2.warpAffine(
        patch,
        matrix,
        (width, height),
        flags=cv2.INTER_NEAREST,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )


# --------------------------------------------------------------------------- #
# Ordering, coverage and geometry
# --------------------------------------------------------------------------- #


def _reading_order(regions: list[Region], height: int) -> list[Region]:
    """Top to bottom, headers first and footers last, children after parents.

    A question number is ordered just before the paragraph it sits beside, so
    the label always opens the answer it belongs to.
    """
    top_level = [index for index, region in enumerate(regions) if region.parent is None]

    def key(index: int) -> tuple[int, float, int]:
        region = regions[index]
        x, y, _, h = region.box
        band = 0 if region.type == "header" else 2 if region.type == "footer" else 1
        top = y - (0.5 * h if region.type == "question_number" else 0)
        return band, top, x

    ordered: list[Region] = []
    remap: dict[int, int] = {}
    for index in sorted(top_level, key=key):
        remap[index] = len(ordered)
        ordered.append(regions[index])
        children = [i for i, r in enumerate(regions) if r.parent == index]
        for child in sorted(children, key=lambda i: (regions[i].box[1], regions[i].box[0])):
            remap[child] = len(ordered)
            ordered.append(regions[child])

    for region in ordered:
        if region.parent is not None:
            region.parent = remap[region.parent]
    return ordered


def _uncovered_ink(content: np.ndarray, boxes: Sequence[Box]) -> float:
    total = int(cv2.countNonZero(content))
    if total == 0:
        return 0.0
    covered = np.zeros_like(content)
    for x, y, w, h in boxes:
        cv2.rectangle(covered, (x, y), (x + w, y + h), 255, -1)
    outside = int(cv2.countNonZero(cv2.bitwise_and(content, cv2.bitwise_not(covered))))
    return outside / float(total)


def _text_coverage(box: Box, words: Sequence[Box]) -> float:
    x, y, w, h = box
    area = float(w * h)
    if area <= 0:
        return 0.0
    covered = sum(_intersection(box, word) for word in words)
    return min(1.0, covered / area)


def _coverage(inner: Box, outer: Box) -> float:
    area = float(inner[2] * inner[3])
    return 0.0 if area <= 0 else _intersection(inner, outer) / area


def _intersection(a: Box, b: Box) -> int:
    w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    return w * h if w > 0 and h > 0 else 0


def _union(a: Box, b: Box) -> Box:
    left, top = min(a[0], b[0]), min(a[1], b[1])
    right = max(a[0] + a[2], b[0] + b[2])
    bottom = max(a[1] + a[3], b[1] + b[3])
    return left, top, right - left, bottom - top


def _union_all(boxes: Sequence[Box]) -> Box:
    result = boxes[0]
    for box in boxes[1:]:
        result = _union(result, box)
    return result


def _merge_boxes(boxes: list[Box], gap: int) -> list[Box]:
    merged = list(boxes)
    changed = True
    while changed:
        changed = False
        for i in range(len(merged)):
            for j in range(i + 1, len(merged)):
                a = merged[i]
                grown = (a[0] - gap, a[1] - gap, a[2] + 2 * gap, a[3] + 2 * gap)
                if _intersection(grown, merged[j]) > 0:
                    merged[i] = _union(a, merged[j])
                    del merged[j]
                    changed = True
                    break
            if changed:
                break
    return merged


def _dedupe(values: list[int], tolerance: int) -> list[int]:
    kept: list[int] = []
    for value in values:
        if not kept or value - kept[-1] > tolerance:
            kept.append(value)
    return kept


def _to_json(region: Region, order: int) -> dict[str, Any]:
    return {
        "type": region.type,
        "box": [int(v) for v in region.box],
        "confidence": round(float(region.confidence), 3),
        "reading_order": order,
        "parent": region.parent,
        "lines": [[int(v) for v in line] for line in region.lines],
        "line_words": [
            [[int(v) for v in word] for word in words] for words in region.line_words
        ],
        "reasons": region.reasons,
    }

