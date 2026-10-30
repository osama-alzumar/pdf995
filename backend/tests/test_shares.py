"""Secure share links: create → view → limits → revoke → purge, with a real PDF."""
from __future__ import annotations

import re
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import shares
from app.config import settings
from app.main import app, _hits

FIX = Path(__file__).parent / "fixtures"


@pytest.fixture()
def client(tmp_path):
    _hits.clear()
    old = (settings.share_dir, settings.share_master_key)
    object.__setattr__(settings, "share_dir", tmp_path / "shares")
    object.__setattr__(settings, "share_master_key", "k" * 44)
    with TestClient(app) as c:
        yield c
    object.__setattr__(settings, "share_dir", old[0])
    object.__setattr__(settings, "share_master_key", old[1])


def create(client, path=FIX / "english.pdf", **fields):
    data = {"recipient": "مكتب الأمل العقاري", "purpose": "التحقق من الهوية", "expires_in": "86400", "max_views": "2",
            "allow_download": "0"}
    data.update(fields)
    with open(path, "rb") as fh:
        return client.post("/v1/shares", files={"files": ("doc.pdf", fh)}, data=data)


def image_urls(html: str) -> list[str]:
    return re.findall(r"src='(/s/[^']+)'", html)


def test_create_view_and_count_opens(client):
    r = create(client)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["url"].endswith("/s/" + body["id"])
    owner = {"X-Owner-Token": body["owner_token"]}

    page = client.get(f"/s/{body['id']}")
    assert page.status_code == 200
    assert "مكتب الأمل العقاري" in page.text and "العرض فقط" in page.text
    assert page.headers["cache-control"] == "no-store" and "noindex" in page.headers["x-robots-tag"]
    imgs = image_urls(page.text)
    assert len(imgs) == 1
    png = client.get(imgs[0])
    assert png.status_code == 200 and png.content.startswith(b"\x89PNG")
    assert client.get(imgs[0].split("?")[0] + "?v=forged.token").status_code == 410
    assert client.get(f"/s/{body['id']}/download?v=x").status_code == 403, "download not allowed"

    st = client.get(f"/v1/shares/{body['id']}", headers=owner).json()
    assert st["opens"] == 1 and st["state"] == "active" and st["max_views"] == 2

    client.get(f"/s/{body['id']}")
    second = client.get(f"/v1/shares/{body['id']}", headers=owner).json()
    assert second["state"] == "exhausted"
    third = client.get(f"/s/{body['id']}")
    assert third.status_code == 410 and "انتهى عدد مرات الفتح" in third.text


def test_owner_token_required(client):
    body = create(client).json()
    assert client.get(f"/v1/shares/{body['id']}").status_code == 404
    assert client.get(f"/v1/shares/{body['id']}", headers={"X-Owner-Token": "wrong"}).status_code == 404
    assert client.delete(f"/v1/shares/{body['id']}", headers={"X-Owner-Token": "wrong"}).status_code == 404


def test_revoke_deletes_the_file_and_shows_message(client):
    body = create(client, allow_download="1").json()
    page = client.get(f"/s/{body['id']}").text
    token = image_urls(page)[0].split("v=")[1]
    pdf = client.get(f"/s/{body['id']}/download?v={token}")
    assert pdf.status_code == 200 and pdf.content.startswith(b"%PDF")

    r = client.delete(f"/v1/shares/{body['id']}", headers={"X-Owner-Token": body["owner_token"]})
    assert r.json()["state"] == "revoked"
    assert not (settings.share_dir / "files" / f"{body['id']}.bin").exists()
    gone = client.get(f"/s/{body['id']}")
    assert gone.status_code == 410 and "لم يعد هذا المستند متاحاً" in gone.text
    assert client.get(f"/s/{body['id']}/p/0?v={token}").status_code == 410


def test_expiry_message_and_purge(client):
    body = create(client).json()
    with shares._db() as conn:
        conn.execute("UPDATE shares SET expires = ? WHERE id = ?", (time.time() - 1, body["id"]))
    r = client.get(f"/s/{body['id']}")
    assert r.status_code == 410 and "انتهت صلاحية مشاركة هذا المستند" in r.text
    assert shares.purge(now=time.time() + shares.VIEW_WINDOW_SECONDS + 5) == 1
    assert not (settings.share_dir / "files" / f"{body['id']}.bin").exists()
    st = client.get(f"/v1/shares/{body['id']}", headers={"X-Owner-Token": body["owner_token"]}).json()
    assert st["state"] == "expired"


def test_stored_file_is_encrypted(client):
    body = create(client).json()
    stored = (settings.share_dir / "files" / f"{body['id']}.bin").read_bytes()
    assert b"%PDF" not in stored and b"Quarterly" not in stored


def test_validation(client):
    assert create(client, expires_in="5").json()["error"] == "bad_duration"
    assert create(client, path=FIX / "protected.pdf").json()["error"] == "encrypted"
    assert create(client, path=FIX / "hundred.pdf").json()["error"] == "too_many_pages"
    assert create(client, path=FIX / "corrupt_garbage.pdf").json()["error"] == "cannot_open"
    assert client.get("/s/doesnotexist").status_code == 404


def test_disabled_without_master_key(client):
    object.__setattr__(settings, "share_master_key", "")
    r = create(client)
    assert r.status_code == 503 and r.json()["error"] == "shares_disabled"
