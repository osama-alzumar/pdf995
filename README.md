# ورقة | Waraqa

تطبيق iPhone أصلي (SwiftUI) لإدارة ملفات PDF: 37 أداة في 7 تصنيفات، بواجهة عربية أولاً مع الإنجليزية.
معظم الأدوات تعمل على الجهاز بلا إنترنت، والأدوات الثقيلة تعمل عبر خادم مستقل بعد موافقة المستخدم.

- حالة كل أداة بصراحة (ما اختُبر وما لم يُختبر): [docs/STATUS.md](docs/STATUS.md)
- المحركات والتراخيص والتكلفة: [docs/ENGINES.md](docs/ENGINES.md)
- TestFlight وApp Store: [docs/RELEASE.md](docs/RELEASE.md)
- قالب سياسة الخصوصية: [docs/PRIVACY_POLICY.md](docs/PRIVACY_POLICY.md)

## البنية
```
App/                      تطبيق SwiftUI
  App/                    نقطة البدء، الحالة العامة، استقبال الملفات من التطبيقات الأخرى
  DesignSystem/           الألوان، المكونات، اللغة (عربي/إنجليزي + RTL)
  Features/
    Home/                 الرئيسية: العنوان، البحث، الأدوات السريعة، المفضلة، كل الأدوات
    Tool/                 شاشة الأداة الموحدة + ToolJobs (نظام تشغيل موحد لكل الأدوات) + النتيجة
    Pages/                معاينة الصفحات والتحديد والترتيب بالسحب
    Editor/               المحرر، التوقيع (PencilKit)، النماذج
    Scanner/              ماسح المستندات (VisionKit)
    Compare/ AI/          نتائج المقارنة والتلخيص والأسئلة
    Files/ Settings/      ملفاتي، الإعدادات
  Services/               التخزين المحمي، خادم المعالجة، HTML→PDF
  Resources/              الأيقونة، الألوان، Privacy Manifest
WaraqaKit/                حزمة Swift
  WaraqaCore/             منطق نقي (يُختبر على Linux و macOS)
  PDFEngine/              محرك PDF على الجهاز (PDFKit/CoreGraphics/CoreText/Vision)
AppUITests/               اختبارات الواجهة ولقطات الشاشة
backend/                  خادم المعالجة (FastAPI + LibreOffice + Tesseract + qpdf + Ghostscript + PyMuPDF)
.github/workflows/ci.yml  بناء واختبار على macOS + اختبارات الخادم على Linux
```

## التشغيل
**التطبيق (يتطلب Mac + Xcode 16 أو أحدث):**
```bash
brew install xcodegen && xcodegen generate && open Waraqa.xcodeproj
```

**النواة على أي نظام (Linux/macOS):**
```bash
cd WaraqaKit && swift test
```

**الخادم:**
```bash
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.lock
# يحتاج: libreoffice tesseract-ocr(-ara) qpdf ocrmypdf ghostscript poppler-utils + خطوط عربية
.venv/bin/python -m tests.make_fixtures tests/fixtures   # ملفات الاختبار الحقيقية
.venv/bin/python -m pytest -q tests
.venv/bin/uvicorn app.main:app --port 8765
```
أو `docker build -t waraqa-backend backend && docker run -p 8000:8000 --env-file backend/.env waraqa-backend`.

**اختبار التطبيق ↔ الخادم (نفس عميل الشبكة الذي يستخدمه التطبيق):**
```bash
cd WaraqaKit && WARAQA_LIVE_SERVER=http://127.0.0.1:8765 WARAQA_FIXTURES=../backend/tests/fixtures swift test --filter LiveServerTests
```

## مبادئ ملزمة في الكود
- الملف الأصلي لا يُعدل أبداً: كل أداة تكتب نسخة جديدة.
- كل ناتج يُعاد فتحه ويُفحص (عدد الصفحات، قابلية الفتح، غياب النص المنقح…) قبل عرض «تم بنجاح».
- لا رفع بدون موافقة؛ لا مفاتيح سرية في التطبيق أو المستودع؛ لا تسجيل لمحتوى أو أسماء الملفات على الخادم.
- غياب الخادم أو الذكاء الاصطناعي يظهر كرسالة واضحة، لا كانهيار ولا كنتيجة وهمية.
