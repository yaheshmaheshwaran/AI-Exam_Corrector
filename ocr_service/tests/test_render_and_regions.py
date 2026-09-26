"""The document engine's render stage, region recognition and cropping."""

from __future__ import annotations

import math
import os
import types

import cv2
import numpy as np
import pymupdf
from PIL import Image

from pipeline import regions, render
from pipeline.recognize import words_from_tokens


def _mixed_pdf(path: str) -> str:
    """Page 1 typed, page 2 blank, page 3 drawn with no text layer."""
    document = pymupdf.open()
    typed = document.new_page(width=595, height=842)
    typed.insert_text(
        (72, 144),
        "1  Name the organelle that carries out aerobic respiration. [2 marks]",
        fontsize=11,
    )
    document.new_page(width=595, height=842)
    drawn = document.new_page(width=595, height=842)
    drawn.draw_circle((300, 400), 120, color=(0, 0, 0), width=3)
    drawn.draw_line((120, 600), (480, 620), color=(0, 0, 0), width=3)
    document.save(path)
    document.close()
    return path


def _run(source: str, out_dir: str, **kwargs):
    events = list(render.render(source, out_dir, **kwargs))
    assert events[-1]["type"] in {"done", "error"}
    return events


def test_render_streams_every_page_with_three_images(tmp_path):
    source = _mixed_pdf(str(tmp_path / "mixed.pdf"))

    events = _run(source, str(tmp_path / "out"), dpi=100, preview_max_dim=400)

    progress = [e for e in events if e["type"] == "progress"]
    assert any(e.get("page") == 3 for e in progress)
    done = events[-1]
    assert done["type"] == "done"
    assert done["page_count"] == 3
    for page in done["pages"]:
        for key in ("original_path", "image_path", "preview_path"):
            assert os.path.isfile(page[key])
        preview = cv2.imread(page["preview_path"])
        assert max(preview.shape[:2]) <= 400


def test_render_reports_text_layer_and_blank_pages(tmp_path):
    source = _mixed_pdf(str(tmp_path / "mixed.pdf"))

    pages = _run(source, str(tmp_path / "out"), dpi=100)[-1]["pages"]

    assert [p["has_text_layer"] for p in pages] == [True, False, False]
    assert [p["is_blank"] for p in pages] == [False, True, False]
    assert "organelle" in pages[0]["text"]
    assert pages[1]["text"] == ""


def test_a_text_layer_page_is_not_deskewed(tmp_path):
    # Its boxes come from PDF coordinates; rotating the image would move the
    # ink out from under them.
    source = _mixed_pdf(str(tmp_path / "mixed.pdf"))
    page = _run(source, str(tmp_path / "out"), dpi=100)[-1]["pages"][0]

    original = cv2.imread(page["original_path"])
    clean = cv2.imread(page["image_path"])
    assert page["skew_degrees"] == 0
    assert np.array_equal(original, clean)


def test_render_errors_are_events_not_exceptions(tmp_path):
    events = _run(str(tmp_path / "missing.pdf"), str(tmp_path / "out"))
    assert events[-1]["type"] == "error"
    assert "not found" in events[-1]["message"].lower()


def test_a_photograph_renders_as_one_page(tmp_path):
    path = str(tmp_path / "scan.jpg")
    Image.fromarray(np.full((500, 400, 3), 255, dtype=np.uint8)).save(path)

    done = _run(path, str(tmp_path / "out"))[-1]

    assert done["page_count"] == 1
    assert done["pages"][0]["is_blank"] is True


def _reading(text: str, confidence: float, words: list[tuple[str, float]]):
    return types.SimpleNamespace(text=text, confidence=confidence, words=words)


def test_a_region_is_read_line_by_line_and_returned_whole(tmp_path):
    page = np.full((400, 600, 3), 255, dtype=np.uint8)
    request = regions.RegionRequest(
        region_id="doc:p1:r0",
        box=(50, 50, 400, 120),
        lines=[(50, 50, 400, 50), (50, 110, 400, 50)],
        line_words=[
            [(50, 50, 150, 50), (220, 50, 200, 50)],
            [(50, 110, 150, 50)],
        ],
    )
    readings = [
        _reading("The chloroplost absorbs", 0.8, [("The", 0.99), ("chloroplost", 0.41)]),
        _reading("light.", 0.97, [("light.", 0.97)]),
    ]

    [result] = regions.recognize_regions(
        page,
        [request],
        str(tmp_path / "crops"),
        page_index=0,
        read_crops=lambda crops: readings[: len(crops)],
        uncertain_below=0.75,
    )

    assert result["text"] == "The chloroplost absorbs\nlight."
    assert os.path.isfile(result["crop_path"])
    assert result["illegible"] is False
    [span] = result["uncertain_spans"]
    assert span["text"] == "chloroplost"
    assert result["text"][span["start"] : span["end"]] == "chloroplost"
    # Two words on the line, two DBNet boxes: the span gets its own word's box.
    assert span["box"] == [220, 50, 200, 50]


def test_a_span_falls_back_to_its_line_when_word_counts_disagree(tmp_path):
    page = np.full((200, 600, 3), 255, dtype=np.uint8)
    request = regions.RegionRequest("r", (10, 10, 500, 60), [(10, 10, 500, 60)], [[(10, 10, 500, 60)]])
    reading = _reading("12.5 mol", 0.6, [("12.5", 0.5), ("mol", 0.9)])

    [result] = regions.recognize_regions(
        page, [request], str(tmp_path), 0, lambda crops: [reading], 0.75
    )

    assert result["uncertain_spans"][0]["box"] == [10, 10, 500, 60]


def test_a_region_with_nothing_legible_is_marked_illegible(tmp_path):
    page = np.full((200, 600, 3), 255, dtype=np.uint8)
    request = regions.RegionRequest("r", (10, 10, 500, 60), [(10, 10, 500, 60)], [[]])

    [result] = regions.recognize_regions(
        page, [request], str(tmp_path), 0, lambda crops: [_reading("", 0.0, [])], 0.75
    )

    assert result["illegible"] is True
    assert result["text"] == ""


def test_lines_are_found_inside_the_region_when_layout_gave_none(tmp_path, monkeypatch):
    page = np.full((300, 600, 3), 255, dtype=np.uint8)
    found = [types.SimpleNamespace(x=5, y=5, width=100, height=20)]
    monkeypatch.setattr(regions.detect, "detect_lines", lambda patch: found)
    request = regions.RegionRequest("r", (100, 100, 300, 100), [], [])
    seen = []

    def reader(crops):
        seen.extend(crops)
        return [_reading("x", 0.9, [("x", 0.9)])]

    [result] = regions.recognize_regions(page, [request], str(tmp_path), 0, reader)

    assert len(seen) == 1
    assert result["lines"][0]["box"] == [105, 105, 100, 20]


def test_crop_regions_cuts_normalised_boxes(tmp_path):
    image = np.full((1000, 800, 3), 255, dtype=np.uint8)
    path = str(tmp_path / "page.png")
    cv2.imwrite(path, image)

    crops = regions.crop_regions(
        path,
        [{"region_id": "a:p1:r2", "box": [0.25, 0.1, 0.5, 0.2]}],
        str(tmp_path / "crops"),
        max_dim=150,
        padding=0,
    )

    crop = cv2.imread(crops["a:p1:r2"])
    assert crop.shape[1] == 150  # 400px wide, scaled to the maximum
    assert os.path.basename(crops["a:p1:r2"]) == "a_p1_r2.png"


def test_words_are_scored_by_their_own_tokens():
    pieces = ["The", "Ġch", "lor", "oplast"]
    log_probs = [math.log(0.99), math.log(0.5), math.log(0.5), math.log(0.5)]

    words = words_from_tokens(pieces, log_probs)

    assert [w for w, _ in words] == ["The", "chloroplast"]
    assert words[0][1] == 0.99 or abs(words[0][1] - 0.99) < 1e-6
    assert abs(words[1][1] - 0.5) < 1e-6


def test_no_tokens_means_no_words():
    assert words_from_tokens([], []) == []
