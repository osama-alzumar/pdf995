"""Settings, read once from the environment (.env in production). Secrets live only here."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default).strip()


@dataclass(frozen=True)
class Settings:
    work_dir: Path = Path(_env("WARAQA_WORK_DIR", "/tmp/waraqa-work"))
    max_upload_mb: int = int(_env("MAX_UPLOAD_MB", "100"))
    # Every uploaded and produced file is deleted right after the response, and in any case by
    # the sweeper after this many minutes. The app shows this number to the user.
    retention_minutes: int = int(_env("RETENTION_MINUTES", "10"))
    job_timeout_seconds: int = int(_env("JOB_TIMEOUT_SECONDS", "240"))
    max_parallel_jobs: int = int(_env("MAX_PARALLEL_JOBS", "2"))
    rate_limit_per_minute: int = int(_env("RATE_LIMIT_PER_MINUTE", "20"))
    anthropic_api_key: str = _env("ANTHROPIC_API_KEY", "")
    anthropic_model: str = _env("ANTHROPIC_MODEL", "claude-opus-5-5")
    soffice: str = _env("SOFFICE_BIN", "soffice")
    verapdf: str = _env("VERAPDF_BIN", "")

    @property
    def max_upload_bytes(self) -> int:
        return self.max_upload_mb * 1_000_000

    @property
    def ai_enabled(self) -> bool:
        return bool(self.anthropic_api_key)


settings = Settings()
