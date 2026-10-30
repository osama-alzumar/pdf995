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
    # Secure share links. Disabled unless SHARE_MASTER_KEY (32 random bytes, base64) is set.
    share_dir: Path = Path(_env("SHARE_DIR", "/var/lib/waraqa/shares"))
    share_master_key: str = _env("SHARE_MASTER_KEY", "")
    public_base_url: str = _env("PUBLIC_BASE_URL", "http://127.0.0.1:8765")
    share_max_mb: int = int(_env("SHARE_MAX_MB", "20"))
    share_max_pages: int = int(_env("SHARE_MAX_PAGES", "50"))
    # Rows of finished shares are kept this long so the owner can still see "expired"; then deleted.
    share_keep_days: int = int(_env("SHARE_KEEP_DAYS", "30"))

    @property
    def max_upload_bytes(self) -> int:
        return self.max_upload_mb * 1_000_000

    @property
    def shares_enabled(self) -> bool:
        return len(self.share_master_key) >= 40

    @property
    def ai_enabled(self) -> bool:
        return bool(self.anthropic_api_key)


settings = Settings()
