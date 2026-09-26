"""Builds the sidecar into a self-contained folder, then smoke-tests it.

    ocr_service/.venv/bin/python ocr_service/packaging/build_sidecar.py          # macOS / Linux
    ocr_service\\.venv\\Scripts\\python ocr_service\\packaging\\build_sidecar.py   # Windows
    … build_sidecar.py --skip-build                                               # test only

Produces `ocr_service/dist/exam-corrector-ocr/`. On Windows, `flutter build
windows` copies that folder beside the application as `ocr_service/`, which is
where the app looks for `exam-corrector-ocr.exe` before trying a development
environment. The smoke test starts the built binary, waits for `/health`, and
renders a generated page through `/render` and `/layout`, so a missing hidden
import fails here rather than on a teacher's machine.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVICE = os.path.dirname(HERE)
DIST = os.path.join(SERVICE, "dist")
NAME = "exam-corrector-ocr"


def build() -> str:
    subprocess.run(
        [
            sys.executable,
            "-m",
            "PyInstaller",
            "--noconfirm",
            "--clean",
            "--distpath",
            DIST,
            "--workpath",
            os.path.join(SERVICE, "build"),
            os.path.join(HERE, f"{NAME}.spec"),
        ],
        check=True,
        cwd=SERVICE,
    )
    folder = os.path.join(DIST, NAME)
    binary = os.path.join(folder, NAME + (".exe" if os.name == "nt" else ""))
    if not os.path.isfile(binary):
        raise SystemExit(f"Build produced no executable at {binary}")
    return binary


def smoke_test(binary: str) -> None:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    token = "smoke-test"
    work = tempfile.mkdtemp(prefix="sidecar_smoke_")
    process = subprocess.Popen(
        [binary, "--port", str(port), "--token", token, "--parent-pid", str(os.getpid())],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    base = f"http://127.0.0.1:{port}/"
    try:
        deadline = time.time() + 180
        while True:
            if process.poll() is not None:
                raise SystemExit(
                    "The sidecar exited during start-up:\n"
                    + process.stderr.read().decode(errors="replace")[-4000:]
                )
            try:
                health = _call(base + "health", token)
                print("health:", health)
                break
            except OSError:
                if time.time() > deadline:
                    raise SystemExit("The sidecar did not become healthy in time.")
                time.sleep(1)

        pdf = _sample_pdf(work)
        done = _stream(base + "render", token, {"path": pdf, "out_dir": work, "dpi": 150})
        pages = done["pages"]
        print(f"render: {len(pages)} page(s), text layer {pages[0]['has_text_layer']}")
        done = _stream(base + "layout", token, {
            "pages": [{"index": 0, "image_path": pages[0]["image_path"]}],
        })
        print("layout:", [r["type"] for r in done["pages"][0].get("regions", [])],
              done["pages"][0].get("error", ""))
        # Loads TrOCR through transformers — the part most likely to be missing
        # a hidden import. Uses the weights in the user's cache.
        page = pages[0]
        done = _stream(base + "recognize", token, {
            "pages": [{
                "index": 0,
                "image_path": page["image_path"],
                "regions": [{"region_id": "smoke", "box": [0, 0, page["width"], page["height"] // 4]}],
            }],
            "crops_dir": os.path.join(work, "crops"),
        })
        if done["failures"]:
            raise SystemExit(f"recognize failed: {done['failures']}")
        print("recognize:", done["engine"], len(done["regions"]), "region(s)")
        print("SMOKE TEST PASSED")
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
        shutil.rmtree(work, ignore_errors=True)


def _call(url: str, token: str) -> dict:
    request = urllib.request.Request(url, headers={"x-ocr-token": token})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.loads(response.read())


def _stream(url: str, token: str, body: dict) -> dict:
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"x-ocr-token": token, "content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        events = [
            json.loads(line[5:])
            for line in response.read().decode().splitlines()
            if line.startswith("data:")
        ]
    last = events[-1]
    if last["type"] != "done":
        raise SystemExit(f"{url} failed: {last}")
    return last


def _sample_pdf(folder: str) -> str:
    import pymupdf

    path = os.path.join(folder, "sample.pdf")
    document = pymupdf.open()
    page = document.new_page(width=595, height=842)
    page.draw_circle((300, 420), 120, color=(0, 0, 0), width=3)
    document.save(path)
    document.close()
    return path


if __name__ == "__main__":
    if "--skip-build" in sys.argv:
        built = os.path.join(DIST, NAME, NAME + (".exe" if os.name == "nt" else ""))
    else:
        built = build()
        print("built:", built)
    smoke_test(built)
