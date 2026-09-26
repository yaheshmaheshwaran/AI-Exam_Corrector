"""The HTTP contract the app depends on: routes, token, and event streams.

No model weights are loaded — recognition is stubbed at the module boundary.
"""

from __future__ import annotations

import json
import types
import warnings

import cv2
import numpy as np
import pymupdf
import pytest

with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    from fastapi.testclient import TestClient

import app as service

TOKEN = "secret"


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.setattr(service, "_TOKEN", TOKEN)
    return TestClient(service.app)


def _events(response) -> list[dict]:
    return [
        json.loads(line[5:])
        for line in response.text.splitlines()
        if line.startswith("data:")
    ]


def _pdf(path) -> str:
    document = pymupdf.open()
    page = document.new_page(width=595, height=842)
    page.draw_circle((300, 400), 120, color=(0, 0, 0), width=3)
    document.save(str(path))
    document.close()
    return str(path)


def test_every_route_refuses_a_missing_token(client):
    for route in ("/render", "/layout", "/recognize", "/crop"):
        assert client.post(route, json={}).status_code in (401, 422)
    assert client.get("/health").status_code == 401


def test_render_streams_progress_then_pages(client, tmp_path):
    response = client.post(
        "/render",
        json={"path": _pdf(tmp_path / "scan.pdf"), "out_dir": str(tmp_path / "out"), "dpi": 100},
        headers={"x-ocr-token": TOKEN},
    )
    events = _events(response)
    assert events[0]["type"] == "progress"
    assert events[-1]["type"] == "done"
    [page] = events[-1]["pages"]
    assert page["has_text_layer"] is False
    assert page["is_blank"] is False


def test_render_reports_an_unreadable_file_as_an_error_event(client, tmp_path):
    bad = tmp_path / "bad.pdf"
    bad.write_bytes(b"%PDF-1.7 not really")
    response = client.post(
        "/render",
        json={"path": str(bad), "out_dir": str(tmp_path / "out")},
        headers={"x-ocr-token": TOKEN},
    )
    assert _events(response)[-1]["type"] == "error"


def test_layout_returns_regions_per_page_and_isolates_failures(client, tmp_path, monkeypatch):
    image = np.full((1400, 1000, 3), 255, dtype=np.uint8)
    good = str(tmp_path / "good.png")
    cv2.imwrite(good, image)
    monkeypatch.setattr(
        service.layout,
        "analyze_layout",
        lambda img: {"width": 1000, "height": 1400, "regions": [], "needs_vision": False, "reasons": []},
    )

    response = client.post(
        "/layout",
        json={"pages": [{"index": 0, "image_path": good}, {"index": 1, "image_path": str(tmp_path / "missing.png")}]},
        headers={"x-ocr-token": TOKEN},
    )

    done = _events(response)[-1]
    assert done["type"] == "done"
    assert done["pages"][0]["index"] == 0
    assert "error" in done["pages"][1]


def test_recognize_reads_regions_with_the_stubbed_model(client, tmp_path, monkeypatch):
    image = np.full((400, 600, 3), 255, dtype=np.uint8)
    path = str(tmp_path / "page.png")
    cv2.imwrite(path, image)
    monkeypatch.setattr(service.recognize, "load_model", lambda name: None)
    monkeypatch.setattr(
        service.recognize,
        "read_crops",
        lambda crops, model_name=None: [
            types.SimpleNamespace(text="The cell", confidence=0.9, words=[("The", 0.99), ("cell", 0.5)])
            for _ in crops
        ],
    )

    response = client.post(
        "/recognize",
        json={
            "pages": [{
                "index": 0,
                "image_path": path,
                "regions": [{"region_id": "p1:r0", "box": [10, 10, 300, 60], "lines": [[10, 10, 300, 60]]}],
            }],
            "crops_dir": str(tmp_path / "crops"),
            "uncertain_below": 0.8,
        },
        headers={"x-ocr-token": TOKEN},
    )

    done = _events(response)[-1]
    [region] = done["regions"]
    assert region["region_id"] == "p1:r0"
    assert region["text"] == "The cell"
    assert region["uncertain_spans"][0]["text"] == "cell"
    assert done["failures"] == []


def test_recognize_reports_a_model_that_will_not_load(client, tmp_path, monkeypatch):
    def fail(name):
        raise RuntimeError("no weights")

    monkeypatch.setattr(service.recognize, "load_model", fail)
    response = client.post(
        "/recognize",
        json={"pages": [], "crops_dir": str(tmp_path)},
        headers={"x-ocr-token": TOKEN},
    )
    event = _events(response)[-1]
    assert event["type"] == "error"
    assert "no weights" in event["message"]


def test_crop_cuts_and_reports_paths(client, tmp_path):
    path = str(tmp_path / "page.png")
    cv2.imwrite(path, np.full((1000, 800, 3), 255, dtype=np.uint8))
    response = client.post(
        "/crop",
        json={
            "image_path": path,
            "out_dir": str(tmp_path / "crops"),
            "regions": [{"region_id": "a", "box": [0.1, 0.1, 0.5, 0.2]}],
        },
        headers={"x-ocr-token": TOKEN},
    )
    assert response.status_code == 200
    assert response.json()["crops"]["a"].endswith("a.png")


def test_crop_of_a_missing_page_is_a_clear_422(client, tmp_path):
    response = client.post(
        "/crop",
        json={"image_path": str(tmp_path / "gone.png"), "out_dir": str(tmp_path), "regions": []},
        headers={"x-ocr-token": TOKEN},
    )
    assert response.status_code == 422
