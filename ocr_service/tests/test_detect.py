"""Line grouping is pure geometry, so it is tested without a detector."""

from __future__ import annotations

import numpy as np

from pipeline.detect import LineBox, _pad, detect_lines, group_words_into_lines


def test_groups_words_on_the_same_baseline_into_one_line():
    words = [
        (10, 100, 40, 20),
        (60, 102, 50, 18),
        (120, 98, 30, 22),
    ]

    lines = group_words_into_lines(words)

    assert len(lines) == 1
    assert lines[0].x == 10
    assert lines[0].y == 98
    # Spans from the leftmost edge to the rightmost.
    assert lines[0].width == 140
    assert lines[0].height == 22


def test_separates_words_on_different_lines():
    words = [
        (10, 100, 40, 20),
        (10, 200, 40, 20),
        (10, 300, 40, 20),
    ]

    lines = group_words_into_lines(words)

    assert len(lines) == 3
    assert [line.y for line in lines] == [100, 200, 300]


def test_returns_lines_in_reading_order_regardless_of_input_order():
    words = [
        (10, 300, 40, 20),
        (10, 100, 40, 20),
        (10, 200, 40, 20),
    ]

    lines = group_words_into_lines(words)

    assert [line.y for line in lines] == [100, 200, 300]


def test_a_tall_capital_does_not_split_its_own_line():
    # An initial capital rises well above the x-height of the rest.
    words = [
        (10, 90, 25, 40),
        (40, 105, 30, 22),
        (75, 106, 30, 21),
    ]

    lines = group_words_into_lines(words)

    assert len(lines) == 1


def test_close_but_non_overlapping_lines_stay_separate():
    # Tight leading: a two pixel gap, no vertical overlap at all.
    words = [
        (10, 100, 40, 20),
        (10, 122, 40, 20),
    ]

    lines = group_words_into_lines(words)

    assert len(lines) == 2


def test_empty_input_yields_no_lines():
    assert group_words_into_lines([]) == []


def test_padding_expands_the_box_but_stays_inside_the_page():
    line = LineBox(x=0, y=0, width=100, height=50)

    padded = _pad(line, (200, 300))

    # Clamped at the top-left corner rather than going negative.
    assert padded.x == 0
    assert padded.y == 0
    assert padded.width > 100
    assert padded.x + padded.width <= 300
    assert padded.y + padded.height <= 200


def test_projection_fallback_finds_lines_without_a_model(monkeypatch):
    # Force the DBNet path to fail so the classical detector takes over.
    monkeypatch.setattr(
        "pipeline.detect._detect_words_doctr",
        lambda image: (_ for _ in ()).throw(RuntimeError("no weights")),
    )

    page = np.full((300, 400, 3), 255, dtype=np.uint8)
    page[50:70, 40:360] = 0
    page[150:170, 40:360] = 0

    lines = detect_lines(page)

    assert len(lines) == 2
    assert lines[0].y < lines[1].y
