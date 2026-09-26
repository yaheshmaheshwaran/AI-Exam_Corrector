"""Exits the sidecar when the app that started it is gone.

The app stops the sidecar cleanly when it closes. It cannot when it is killed —
from Task Manager, by a crash, by a debugger — and a stranded sidecar holds
gigabytes of model weights until the machine restarts. So the sidecar watches
its parent and leaves with it.
"""

from __future__ import annotations

import os
import sys
import threading
import time
from typing import Callable

POLL_SECONDS = 2.0


def is_alive(pid: int) -> bool:
    """True while process `pid` exists."""
    if pid <= 0:
        return False
    if sys.platform == "win32":
        return _windows_is_alive(pid)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, owned by someone else
    return True


def _windows_is_alive(pid: int) -> bool:
    # os.kill(pid, 0) on Windows sends CTRL_C_EVENT; it must not be used here.
    import ctypes
    from ctypes import wintypes

    process_query_limited_information = 0x1000
    still_active = 259
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    handle = kernel32.OpenProcess(process_query_limited_information, False, pid)
    if not handle:
        return False
    try:
        code = wintypes.DWORD()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return False
        return code.value == still_active
    finally:
        kernel32.CloseHandle(handle)


def watch_parent(
    pid: int,
    on_gone: Callable[[], None] | None = None,
    poll_seconds: float = POLL_SECONDS,
    alive: Callable[[int], bool] = is_alive,
) -> threading.Thread:
    """Starts a daemon thread that calls `on_gone` (default: exit now) once
    process `pid` has ended."""

    def run() -> None:
        while alive(pid):
            time.sleep(poll_seconds)
        (on_gone or (lambda: os._exit(0)))()

    thread = threading.Thread(target=run, name="parent-watchdog", daemon=True)
    thread.start()
    return thread
