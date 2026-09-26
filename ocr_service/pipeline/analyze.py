"""Stage 1 page analysis: cheap measurements taken on every page.

Nothing here loads a model. It exists so the expensive stages can skip what
does not need them — a blank page, a continuation sheet with nothing on it —
and so the app can decide early which pages are worth a vision model's time.
"""

from __future__ import annotations

import cv2
import numpy as np

# Below this fraction of inked pixels (after ruled lines are removed) a page is
# treated as blank. Scanner speckle and a page number sit well under it; one
# short handwritten line sits well over it.
BLANK_INK_COVERAGE = 0.0012

# Components smaller than this, in pixels at 300 dpi, are speckle.
SPECKLE_AREA_PX = 24


def ink_mask(image: np.ndarray) -> np.ndarray:
    """White-on-black mask of everything darker than the paper."""
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if image.ndim == 3 else image
    return cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)[1]


def ruling_mask(binary: np.ndarray) -> np.ndarray:
    """Printed ruling: horizontal lines spanning most of the page width.

    Exercise-book ruling is ink, but nobody wrote it. Left in, it makes an
    empty lined page look full and joins every line of writing into one blob.
    """
    width = binary.shape[1]
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (max(width // 3, 20), 1))
    return cv2.morphologyEx(binary, cv2.MORPH_OPEN, kernel)


def page_stats(image: np.ndarray) -> dict:
    """Ink coverage and blankness for one page."""
    binary = ink_mask(image)
    if not binary.any():
        return {"ink_coverage": 0.0, "is_blank": True}

    # Otsu on a blank page splits the paper's own grain into "ink"; a page
    # whose darkest pixels are still light has nothing written on it.
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if image.ndim == 3 else image
    if int(gray.min()) > 200:
        return {"ink_coverage": 0.0, "is_blank": True}

    content = cv2.subtract(binary, ruling_mask(binary))
    count, _, stats, _ = cv2.connectedComponentsWithStats(content, connectivity=8)
    inked = sum(
        int(stats[index, cv2.CC_STAT_AREA])
        for index in range(1, count)
        if stats[index, cv2.CC_STAT_AREA] >= SPECKLE_AREA_PX
    )
    coverage = inked / float(content.shape[0] * content.shape[1])
    return {
        "ink_coverage": round(coverage, 5),
        "is_blank": coverage < BLANK_INK_COVERAGE,
    }
