# خادم المعالجة — Waraqa backend

FastAPI يشغّل الأدوات التي لا يمكن تنفيذها على الآيفون بجودة كافية. التفاصيل والتراخيص: `../docs/ENGINES.md`.

## الواجهة
| الطلب | الوصف |
|---|---|
| `GET /v1/health` | الحالة، الأدوات المتاحة، `ai`، `retention_minutes`، `max_upload_mb` |
| `POST /v1/tools/{tool}` | multipart: `files` + خيارات (`password`، `languages=ar,en`، `level`). الأدوات: `wordToPDF` `powerPointToPDF` `excelToPDF` `pdfToWord` `pdfToPowerPoint` `pdfToExcel` `pdfToPDFA` `ocr` `repair` `compress`. يعيد الملف مع `filename*` بالعربية |
| `POST /v1/ai/summarize` · `/ask` · `/translate` | JSON بنص الصفحات (يُستخرج على الجهاز). كل اقتباس يُتحقق منه مقابل النص |

الأخطاء: `{"error": "<code>", "message_ar": "...", "message_en": "..."}` — يحولها التطبيق إلى رسائل عربية مفهومة.

## الخصوصية والأمان
- مجلد خاص (0700) لكل طلب، يُحذف بعد إرسال الرد مباشرة؛ ومنظف كل دقيقة يحذف ما تجاوز `RETENTION_MINUTES`؛ ويُفرغ كل شيء عند التشغيل.
- لا تُسجل أسماء الملفات ولا محتوياتها (يوجد اختبار لذلك).
- حد للحجم (`MAX_UPLOAD_MB`)، حد للطلبات لكل IP، حد لعدد المهام المتزامنة، مهلة لكل محرك.
- المفاتيح في `.env` فقط (`ANTHROPIC_API_KEY`). لا شيء سري في التطبيق.
- يجب تشغيله خلف HTTPS (ملف `deploy/Caddyfile` جاهز).

## النشر على خادم Ubuntu 24.04
```bash
sudo apt install libreoffice-writer libreoffice-calc libreoffice-impress tesseract-ocr tesseract-ocr-ara tesseract-ocr-eng \
  qpdf ocrmypdf ghostscript poppler-utils fonts-noto-core fonts-kacst fonts-hosny-amiri unpaper pngquant python3-venv caddy
sudo useradd --system --create-home waraqa
sudo mkdir -p /opt/waraqa && sudo cp -r backend /opt/waraqa/ && cd /opt/waraqa/backend
sudo -u waraqa python3 -m venv .venv && sudo -u waraqa .venv/bin/pip install -r requirements.lock
sudo cp .env.example .env   # ثم عدّل القيم
sudo cp deploy/waraqa-backend.service /etc/systemd/system/ && sudo systemctl enable --now waraqa-backend
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile  # غيّر اسم النطاق
sudo systemctl reload caddy
curl https://<النطاق>/v1/health
```
ثم ضع `https://<النطاق>` في `WARAQA_SERVER_URL` في `project.yml`.

## الاختبارات
```bash
.venv/bin/python -m tests.make_fixtures tests/fixtures
WARAQA_WORK_DIR=/tmp/waraqa-test .venv/bin/python -m pytest -q tests
```
