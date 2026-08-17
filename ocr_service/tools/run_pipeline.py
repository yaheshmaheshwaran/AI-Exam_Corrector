"""Runs the OCR pipeline over a file and prints what it read.

    ocr_service/.venv/bin/python tools/run_pipeline.py <path> [dpi]

Prints every line with its confidence, so a bad result can be traced to the
stage that caused it: missing lines mean detection, wrong words mean
recognition.
"""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pipeline import assemble, extract  # noqa: E402


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    path = sys.argv[1]
    dpi = int(sys.argv[2]) if len(sys.argv) > 2 else 300

    started = time.time()
    document = None

    for event in extract.extract(path, dpi=dpi):
        if event["type"] == "progress":
            print(f"  [{event['fraction']:>5.0%}] {event['message']}", flush=True)
        elif event["type"] == "error":
            print(f"\nERROR: {event['message']}")
            return 1
        else:
            document = event["document"]

    if document is None:
        print("\nERROR: no document was produced")
        return 1

    elapsed = time.time() - started
    print(f"\nengine   {document['engine']}")
    print(f"detector {document['detector']}")
    print(f"lines    {document['line_count']}")
    print(f"mean conf {document['mean_confidence']:.3f}")
    print(f"elapsed  {elapsed:.1f}s\n")

    for page in document["pages"]:
        print(f"--- Page {page['index'] + 1} ---")
        for line in page["lines"]:
            flag = "  <-- LOW" if line["confidence"] < 0.75 else ""
            print(f"  {line['confidence']:.3f}  {line['text']}{flag}")
        print()

    print("=== assembled text ===")
    print(assemble.to_marked_text(document))
    return 0


if __name__ == "__main__":
    sys.exit(main())
