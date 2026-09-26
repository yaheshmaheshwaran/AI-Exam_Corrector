"""Runs the local engines over a file and prints what each made of it.

    ocr_service/.venv/bin/python tools/run_pipeline.py <path> [dpi]

Render → layout → region recognition, exactly as the app drives them, with
every region's type, confidence and reading. A wrong mark usually traces back
to one of these: a missing region is layout, a wrong word is recognition.
"""

from __future__ import annotations

import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import cv2  # noqa: E402

from pipeline import layout, recognize, regions, render  # noqa: E402

TEXT_TYPES = {"handwritten_answer", "question_number", "crossed_out", "margin_note", "label"}


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    path = sys.argv[1]
    dpi = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    workdir = tempfile.mkdtemp(prefix="exam_pipeline_")
    started = time.time()

    pages = None
    for event in render.render(path, workdir, dpi=dpi):
        if event["type"] == "progress":
            print(f"  [{event['fraction']:>5.0%}] {event['message']}", flush=True)
        elif event["type"] == "error":
            print(f"\nERROR: {event['message']}")
            return 1
        else:
            pages = event["pages"]

    for page in pages or []:
        print(f"\n--- Page {page['index'] + 1} "
              f"{'(blank)' if page['is_blank'] else ''}"
              f"{'(text layer)' if page['has_text_layer'] else ''}")
        if page["is_blank"]:
            continue
        image = cv2.imread(page["image_path"])
        result = layout.analyze_layout(image)
        print(f"  layout: {result['detector']} · needs vision: {result['needs_vision']} "
              f"{result['reasons']}")

        requests = regions.parse_requests([
            {**region, "region_id": f"r{index}"}
            for index, region in enumerate(result["regions"])
            if region["type"] in TEXT_TYPES
        ])
        read = {
            item["region_id"]: item
            for item in regions.recognize_regions(
                image, requests, os.path.join(workdir, "crops"), page["index"],
                lambda crops: recognize.read_crops(crops),
            )
        }
        for index, region in enumerate(result["regions"]):
            item = read.get(f"r{index}")
            text = item["text"].replace("\n", " / ") if item else ""
            flags = ", ".join(s["text"] for s in item["uncertain_spans"]) if item else ""
            print(f"  #{region['reading_order'] + 1:<3} {region['type']:<18} "
                  f"{(item or region)['confidence']:.2f}  {text[:90]}"
                  f"{'   uncertain: ' + flags if flags else ''}")

    print(f"\nelapsed {time.time() - started:.1f}s · images in {workdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
