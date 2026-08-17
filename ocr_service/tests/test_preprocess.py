"""Deskew has to recover a known rotation, or every box downstream is wrong."""

from __future__ import annotations

import cv2
import numpy as np
import pytest

from pipeline.preprocess import estimate_skew, preprocess


def _page_with_text_lines() -> np.ndarray:
    """A white page with evenly spaced black bars standing in for text lines."""
    page = np.full((600, 800, 3), 255, dtype=np.uint8)
    for top in range(80, 520, 60):
        page[top : top + 18, 100:700] = 0
    return page


def _rotate(image: np.ndarray, degrees: float) -> np.ndarray:
    height, width = image.shape[:2]
    matrix = cv2.getRotationMatrix2D((width / 2.0, height / 2.0), degrees, 1.0)
    return cv2.warpAffine(
        image,
        matrix,
        (width, height),
        flags=cv2.INTER_CUBIC,
        borderMode=cv2.BORDER_REPLICATE,
    )


def test_a_straight_page_is_reported_as_straight():
    assert abs(estimate_skew(_page_with_text_lines())) < 0.3


@pytest.mark.parametrize("skew", [-3.0, -1.5, 1.0, 2.5])
def test_recovers_a_known_skew(skew):
    rotated = _rotate(_page_with_text_lines(), skew)

    estimated = estimate_skew(rotated)

    # The search steps in quarter degrees, so this is the achievable precision.
    assert estimated == pytest.approx(-skew, abs=0.4)


def test_preprocess_returns_a_three_channel_image_of_the_same_size():
    page = _page_with_text_lines()

    cleaned = preprocess(page)

    assert cleaned.shape == page.shape
    assert cleaned.dtype == np.uint8


def test_preprocess_does_not_binarise():
    # A faint pencil grey must survive as grey; hard thresholding would push it
    # to pure black or pure white and cost the recogniser stroke detail.
    page = np.full((200, 400, 3), 255, dtype=np.uint8)
    page[80:110, 50:350] = 140

    cleaned = preprocess(page)
    values = np.unique(cleaned)

    assert len(values) > 2


def test_a_blank_page_does_not_crash_the_skew_search():
    blank = np.full((300, 300, 3), 255, dtype=np.uint8)

    assert estimate_skew(blank) == 0.0
