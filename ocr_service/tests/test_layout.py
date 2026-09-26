"""Local layout analysis, on synthetic pages.

Words are supplied explicitly — the geometry is what is under test, not DBNet —
and drawn as runs of short vertical strokes so the page's ink looks like
writing to the graphic and strike-through detectors: lots of short marks,
never a long horizontal run.
"""

from __future__ import annotations

import cv2
import numpy as np

from pipeline import analyze, layout

WIDTH, HEIGHT = 1240, 1754


def _page() -> np.ndarray:
    return np.full((HEIGHT, WIDTH, 3), 255, dtype=np.uint8)


def _write_word(page: np.ndarray, x: int, y: int, width: int, height: int = 28):
    for stroke_x in range(x, x + width, 7):
        cv2.line(page, (stroke_x, y + 3), (stroke_x + 2, y + height - 3), (20, 20, 20), 2)
    return (x, y, width, height)


def _write_line(page, x: int, y: int, words: int = 5, word_width: int = 90):
    boxes = []
    for index in range(words):
        boxes.append(_write_word(page, x + index * (word_width + 22), y, word_width))
    return boxes


def _types(result) -> list[str]:
    return [region["type"] for region in result["regions"]]


def test_paragraphs_separated_by_space_are_separate_blocks():
    page = _page()
    words = []
    for row in range(3):
        words += _write_line(page, 200, 300 + row * 45)
    for row in range(2):
        words += _write_line(page, 200, 700 + row * 45)

    result = layout.analyze_layout(page, words=words)

    blocks = [r for r in result["regions"] if r["type"] == "handwritten_answer"]
    assert len(blocks) == 2
    assert len(blocks[0]["lines"]) == 3
    assert len(blocks[1]["lines"]) == 2
    assert blocks[0]["reading_order"] < blocks[1]["reading_order"]
    assert result["needs_vision"] is False


def test_a_margin_number_becomes_a_question_number_before_its_answer():
    page = _page()
    number = _write_word(page, 70, 300, 40)
    words = [number]
    for row in range(3):
        words += _write_line(page, 220, 300 + row * 45)

    result = layout.analyze_layout(page, words=words)

    assert _types(result)[:2] == ["question_number", "handwritten_answer"]


def test_drawn_shapes_become_a_diagram_with_their_labels():
    page = _page()
    words = _write_line(page, 200, 200)
    cv2.circle(page, (620, 800), 220, (0, 0, 0), 4)
    cv2.line(page, (400, 800), (840, 800), (0, 0, 0), 3)
    cv2.line(page, (620, 580), (500, 1000), (0, 0, 0), 3)
    label = _write_word(page, 560, 700, 80)
    words.append(label)

    result = layout.analyze_layout(page, words=words)

    diagrams = [r for r in result["regions"] if r["type"] == "diagram"]
    assert len(diagrams) == 1
    parent = result["regions"].index(diagrams[0])
    labels = [r for r in result["regions"] if r["type"] == "label"]
    assert labels and labels[0]["parent"] == parent
    assert result["needs_vision"] is True


def test_a_ruled_grid_is_a_table():
    page = _page()
    left, top, cell_w, cell_h = 250, 500, 220, 90
    for row in range(5):
        y = top + row * cell_h
        cv2.line(page, (left, y), (left + 3 * cell_w, y), (0, 0, 0), 3)
    for col in range(4):
        x = left + col * cell_w
        cv2.line(page, (x, top), (x, top + 4 * cell_h), (0, 0, 0), 3)

    result = layout.analyze_layout(page, words=[])

    assert "table" in _types(result)


def test_perpendicular_axes_are_a_graph():
    page = _page()
    origin = (300, 1300)
    cv2.line(page, origin, (1000, 1300), (0, 0, 0), 3)  # x axis
    cv2.line(page, origin, (300, 700), (0, 0, 0), 3)  # y axis
    points = np.array([[320 + i * 30, int(1280 - (i**1.6) * 6)] for i in range(22)], np.int32)
    cv2.polylines(page, [points], False, (0, 0, 0), 3)

    result = layout.analyze_layout(page, words=[])

    assert "graph" in _types(result)


def test_a_struck_through_line_is_reported_as_crossed_out():
    page = _page()
    kept = _write_line(page, 200, 300)
    struck = _write_line(page, 200, 420)
    left = struck[0][0]
    right = struck[-1][0] + struck[-1][2]
    cv2.line(page, (left, 434), (right, 436), (0, 0, 0), 3)

    result = layout.analyze_layout(page, words=kept + struck)

    crossed = [r for r in result["regions"] if r["type"] == "crossed_out"]
    assert len(crossed) == 1
    assert crossed[0]["box"][1] >= 400
    assert 0 < crossed[0]["confidence"] < 0.6


def test_writing_is_never_mistaken_for_a_strike():
    page = _page()
    words = _write_line(page, 200, 300, words=6)

    result = layout.analyze_layout(page, words=words)

    assert "crossed_out" not in _types(result)


def test_headers_and_footers_are_ordered_around_the_body():
    page = _page()
    footer = _write_line(page, 550, 1690, words=1, word_width=80)
    body = _write_line(page, 200, 600)
    header = _write_line(page, 200, 40, words=2)

    result = layout.analyze_layout(page, words=footer + body + header)

    assert _types(result) == ["header", "handwritten_answer", "footer"]


def test_exercise_book_ruling_is_not_content():
    page = _page()
    for y in range(150, 1700, 60):
        cv2.line(page, (40, y), (1200, y), (160, 160, 160), 2)
    words = _write_line(page, 200, 300)

    result = layout.analyze_layout(page, words=words)

    assert _types(result) == ["handwritten_answer"]
    assert result["needs_vision"] is False


def test_no_words_at_all_needs_the_vision_model():
    page = _page()
    result = layout.analyze_layout(page, words=[])
    assert result["needs_vision"] is True


def test_blank_and_ruled_pages_are_blank_but_writing_is_not():
    assert analyze.page_stats(_page())["is_blank"] is True

    ruled = _page()
    for y in range(150, 1700, 60):
        cv2.line(ruled, (40, y), (1200, y), (170, 170, 170), 2)
    assert analyze.page_stats(ruled)["is_blank"] is True

    written = _page()
    _write_line(written, 200, 300)
    stats = analyze.page_stats(written)
    assert stats["is_blank"] is False
    assert stats["ink_coverage"] > 0


def test_a_change_in_writing_size_starts_a_new_block():
    # Printed question text, then the student's larger handwriting beneath it
    # at the same pitch: two blocks, not one.
    page = _page()
    words = []
    for row in range(2):
        for index in range(5):
            words.append(_write_word(page, 200 + index * 100, 300 + row * 40, 80, height=24))
    for row in range(2):
        for index in range(4):
            words.append(_write_word(page, 200 + index * 140, 390 + row * 60, 120, height=44))

    result = layout.analyze_layout(page, words=words)

    blocks = [r for r in result["regions"] if r["type"] == "handwritten_answer"]
    assert [len(b["lines"]) for b in blocks] == [2, 2]


def test_an_indented_line_starts_a_new_block():
    page = _page()
    words = _write_line(page, 120, 300) + _write_line(page, 120, 345)
    words += _write_line(page, 320, 390) + _write_line(page, 320, 435)

    result = layout.analyze_layout(page, words=words)

    blocks = [r for r in result["regions"] if r["type"] == "handwritten_answer"]
    assert len(blocks) == 2


def test_labels_beside_a_drawing_belong_to_it_but_paragraphs_do_not():
    page = _page()
    cv2.circle(page, (450, 800), 220, (0, 0, 0), 4)
    cv2.line(page, (450, 800), (720, 700), (0, 0, 0), 3)
    # A pointer-line label just outside the circle's ink.
    label = _write_word(page, 690, 690, 90)
    # A paragraph beside the drawing, which must stay a paragraph.
    paragraph = []
    for row in range(3):
        paragraph += _write_line(page, 700, 900 + row * 45, words=4, word_width=70)

    result = layout.analyze_layout(page, words=[label] + paragraph)

    types = _types(result)
    assert types.count("label") == 1
    assert "handwritten_answer" in types
