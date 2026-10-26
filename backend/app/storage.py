"""Private per-job folders and the sweeper that guarantees nothing outlives the retention window."""
from __future__ import annotations

import os
import shutil
import threading
import time
import uuid
from pathlib import Path

from .config import settings


def new_job_dir() -> Path:
    settings.work_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = settings.work_dir / uuid.uuid4().hex
    path.mkdir(mode=0o700)
    return path


def remove(path: Path) -> None:
    shutil.rmtree(path, ignore_errors=True)


def sweep_once(max_age_seconds: float | None = None) -> int:
    """Deletes job folders older than the retention window. Returns how many were removed."""
    max_age = max_age_seconds if max_age_seconds is not None else settings.retention_minutes * 60
    if not settings.work_dir.exists():
        return 0
    now = time.time()
    removed = 0
    for entry in settings.work_dir.iterdir():
        try:
            if now - entry.stat().st_mtime > max_age:
                if entry.is_dir():
                    shutil.rmtree(entry, ignore_errors=True)
                else:
                    entry.unlink(missing_ok=True)
                removed += 1
        except FileNotFoundError:
            continue
    return removed


def start_sweeper() -> None:
    def loop() -> None:
        while True:
            try:
                sweep_once()
            except Exception:  # never let the sweeper die
                pass
            time.sleep(60)

    threading.Thread(target=loop, name="waraqa-sweeper", daemon=True).start()


def safe_name(name: str, fallback: str = "file") -> str:
    """Keeps the user's (often Arabic) name but strips anything that could escape the folder."""
    base = os.path.basename(name or "").replace("\x00", "").strip()
    for ch in '/\\:*?"<>|':
        base = base.replace(ch, " ")
    base = " ".join(base.split()).strip(". ")
    return (base or fallback)[:120]
