"""The parent watchdog: a sidecar must not outlive the app that started it."""

from __future__ import annotations

import os
import subprocess
import sys
import threading

from pipeline import watchdog


def test_this_process_is_alive_and_a_finished_one_is_not():
    assert watchdog.is_alive(os.getpid())
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait()
    assert not watchdog.is_alive(child.pid)
    assert not watchdog.is_alive(0)


def test_calls_back_once_the_parent_is_gone():
    checks = iter([True, True, False])
    gone = threading.Event()

    watchdog.watch_parent(
        1234,
        on_gone=gone.set,
        poll_seconds=0.01,
        alive=lambda pid: next(checks),
    )

    assert gone.wait(timeout=2)


def test_the_sidecar_exits_when_its_parent_does(tmp_path):
    # A parent that starts the sidecar's watchdog in a grandchild and exits.
    script = tmp_path / "child.py"
    script.write_text(
        "import sys, time\n"
        f"sys.path.insert(0, {os.path.dirname(os.path.dirname(os.path.abspath(__file__)))!r})\n"
        "from pipeline import watchdog\n"
        "watchdog.watch_parent(int(sys.argv[1]), poll_seconds=0.05)\n"
        "time.sleep(30)\n"
    )
    parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(0.5)"])
    child = subprocess.Popen([sys.executable, str(script), str(parent.pid)])
    parent.wait()
    assert child.wait(timeout=10) == 0
