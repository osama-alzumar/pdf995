"""Certified translation orders: app order → team panel → translation delivered to the app."""
from __future__ import annotations

import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import admin, translations
from app.config import settings
from app.main import app, _hits

FIX = Path(__file__).parent / "fixtures"
PASSWORD = "team-pass-123"


@pytest.fixture()
def client(tmp_path):
    _hits.clear()
    admin._fails.clear()
    names = ("orders_dir", "share_master_key", "admin_password_hash")
    old = {n: getattr(settings, n) for n in names}
    object.__setattr__(settings, "orders_dir", tmp_path / "orders")
    object.__setattr__(settings, "share_master_key", "k" * 44)
    object.__setattr__(settings, "admin_password_hash", admin.hash_password(PASSWORD, iterations=1000))
    with TestClient(app, base_url="https://testserver") as c:
        yield c
    for n, v in old.items():
        object.__setattr__(settings, n, v)


def order(client, path=FIX / "english.pdf", **fields):
    data = {"name": "سارة أحمد", "phone": "0551234567", "email": "", "source_language": "en", "target_language": "ar",
            "notes": "ترجمة شهادة"}
    data.update(fields)
    with open(path, "rb") as fh:
        return client.post("/v1/translations", files={"files": ("شهادة التخرج.pdf", fh)}, data=data)


def login(client):
    r = client.post("/admin/login", data={"password": PASSWORD}, headers={"Origin": "https://testserver"},
                    follow_redirects=False)
    assert r.status_code == 303, r.text
    return r


def pages_of(path: Path) -> int:
    return translations.count_pages(path)


def test_health_announces_price(client):
    body = client.get("/v1/health").json()
    assert body["translation"] is True and body["translation_price_sar"] == 10


def test_full_order_flow(client, tmp_path):
    r = order(client)
    assert r.status_code == 200, r.text
    body = r.json()
    pages = pages_of(FIX / "english.pdf")
    assert body["pages"] == pages and body["price_sar"] == pages * 10
    assert body["state"] == "received" and body["has_result"] is False and body["number"] == 1001
    owner = {"X-Owner-Token": body["owner_token"]}

    # Stored encrypted: the original bytes never appear on disk.
    original = (FIX / "english.pdf").read_bytes()
    stored = list((settings.orders_dir / "files").iterdir())
    assert stored and all(original[:200] not in f.read_bytes() for f in stored)

    assert client.get(f"/v1/translations/{body['id']}", headers={"X-Owner-Token": "wrong"}).status_code == 404
    assert client.get(f"/v1/translations/{body['id']}/result", headers=owner).status_code == 409

    # The panel needs a login.
    assert client.get("/admin", follow_redirects=False).status_code == 303
    login(client)
    listing = client.get("/admin").text
    assert "طلب 1001" in listing and "سارة أحمد" in listing
    detail = client.get(f"/admin/orders/{body['id']}").text
    assert "+966551234567" in detail and "wa.me/966551234567" in detail and "شهادة التخرج.pdf" in detail
    download = client.get(f"/admin/orders/{body['id']}/files/0")
    assert download.status_code == 200 and download.content == original

    # Team asks for payment with a message, then marks it paid.
    r = client.post(f"/admin/orders/{body['id']}", data={"state": "awaiting_payment", "price": "30", "message": "حوّل المبلغ"},
                    headers={"Origin": "https://testserver"}, follow_redirects=False)
    assert r.status_code == 303
    status = client.get(f"/v1/translations/{body['id']}", headers=owner).json()
    assert status["state"] == "awaiting_payment" and status["price_sar"] == 30 and status["message"] == "حوّل المبلغ"
    # "ready" needs the translation first.
    r = client.post(f"/admin/orders/{body['id']}", data={"state": "ready", "price": "30", "paid": "1"},
                    headers={"Origin": "https://testserver"})
    assert r.status_code == 400

    translated = FIX / "arabic.pdf"
    with open(translated, "rb") as fh:
        r = client.post(f"/admin/orders/{body['id']}/result", files={"file": ("ترجمة.pdf", fh)},
                        headers={"Origin": "https://testserver"}, follow_redirects=False)
    assert r.status_code == 303
    status = client.get(f"/v1/translations/{body['id']}", headers=owner).json()
    assert status["state"] == "ready" and status["has_result"] is True
    result = client.get(f"/v1/translations/{body['id']}/result", headers=owner)
    assert result.status_code == 200 and result.content == translated.read_bytes()
    assert "filename*=UTF-8''" in result.headers["content-disposition"]


def test_validation(client):
    assert order(client, phone="123").json()["error"] == "bad_phone"
    assert order(client, name="").json()["error"] == "bad_name"
    assert order(client, source_language="ar", target_language="ar").json()["error"] == "bad_language"
    assert order(client, email="not-an-email").json()["error"] == "bad_email"
    assert order(client, path=FIX / "protected.pdf").json()["error"] == "encrypted"
    with open(FIX / "english.pdf", "rb") as fh:
        r = client.post("/v1/translations", files={"files": ("a.exe", fh)},
                        data={"name": "سارة", "phone": "0551234567", "source_language": "en", "target_language": "ar"})
    assert r.json()["error"] == "unsupported"


def test_images_count_one_page_each_and_arabic_digits(client, tmp_path):
    from PIL import Image
    img = tmp_path / "id.jpg"
    Image.new("RGB", (400, 300), "white").save(img)
    with open(img, "rb") as a, open(img, "rb") as b:
        r = client.post("/v1/translations", files=[("files", ("1.jpg", a)), ("files", ("2.jpg", b))],
                        data={"name": "محمد", "phone": "٠٥٥١٢٣٤٥٦٧", "source_language": "ar", "target_language": "en"})
    assert r.status_code == 200, r.text
    assert r.json()["pages"] == 2 and r.json()["price_sar"] == 20


def test_login_security(client):
    r = client.post("/admin/login", data={"password": "wrong"}, headers={"Origin": "https://testserver"})
    assert r.status_code == 401
    # Cross-site form posts are refused even with the right password.
    r = client.post("/admin/login", data={"password": PASSWORD}, headers={"Origin": "https://evil.example"})
    assert r.status_code == 401
    for _ in range(8):
        client.post("/admin/login", data={"password": "wrong"}, headers={"Origin": "https://testserver"})
    r = client.post("/admin/login", data={"password": PASSWORD}, headers={"Origin": "https://testserver"})
    assert r.status_code == 429
    assert not admin.valid_session("123.abc") and not admin.valid_session(None)


def test_session_cookie_is_strict(client):
    r = login(client)
    cookie = r.headers["set-cookie"].lower()
    assert "httponly" in cookie and "samesite=strict" in cookie and "secure" in cookie


def test_purge_deletes_files_of_old_delivered_orders(client):
    body = order(client).json()
    translations.update(body["id"], state="cancelled")
    assert translations.purge(time.time() + 31 * 86_400) == 1
    assert not list((settings.orders_dir / "files").iterdir())
    owner = {"X-Owner-Token": body["owner_token"]}
    assert client.get(f"/v1/translations/{body['id']}", headers=owner).json()["state"] == "cancelled"


def test_privacy_and_support_pages(client):
    assert "سياسة" in client.get("/privacy").text
    assert client.get("/support").status_code == 200
