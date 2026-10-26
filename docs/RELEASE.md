# تجهيز TestFlight ثم النشر على App Store

## المتطلبات (منك)
1. حساب Apple Developer مفعل (99$ سنوياً) وTeam ID.
2. معرف التطبيق: `app.waraqa.ios` (أو غيّره في `project.yml` → `PRODUCT_BUNDLE_IDENTIFIER`).
3. إنشاء سجل التطبيق في App Store Connect باسم «ورقة» (واجهة الويب؛ واجهة API لا تسمح بإنشائه).
4. رابط سياسة خصوصية منشور (القالب في `docs/PRIVACY_POLICY.md`) وبريد دعم.
5. (للأدوات السحابية) خادم منشور على `https://...` — انظر `backend/README.md`.

## 1) البناء محلياً على Mac
```bash
brew install xcodegen
xcodegen generate
open Waraqa.xcodeproj
```
في Xcode: Signing & Capabilities → اختر الفريق. اضبط في Build Settings:
- `WARAQA_SERVER_URL` = رابط الخادم (اتركه فارغاً لنسخة تعمل محلياً فقط؛ الأدوات السحابية تظهر «غير مفعّلة»).
- `WARAQA_PRIVACY_POLICY_URL`، `WARAQA_SUPPORT_EMAIL`.

## 2) TestFlight
1. Product → Archive (الوجهة: Any iOS Device).
2. Organizer → Distribute App → App Store Connect → Upload.
3. في App Store Connect → TestFlight: أكمل «Test Information» (بريد التواصل، وصف ما يُختبر).
4. المختبرون الداخليون فوراً؛ الخارجيون بعد مراجعة Beta سريعة.

بديل آلي (مثل مشروع رصيد): إضافة خطوة رفع في GitHub Actions بشهادة Distribution وملف Provisioning ومفتاح App Store Connect API في Secrets — أجهزها عند إنشاء المستودع.

## 3) قبل الإرسال للمراجعة — قائمة تحقق
- [ ] CI ناجح: اختبارات WaraqaKit على macOS + اختبارات الواجهة + بناء الجهاز.
- [ ] تجربة يدوية على آيفون حقيقي لكل أداة في `docs/STATUS.md` (خاصة الكاميرا والمشاركة من تطبيقات أخرى).
- [ ] ملفات كبيرة (100+ صفحة، 50+ م.ب) بلا تجمد أو إغلاق مفاجئ.
- [ ] الوضع الداكن، Dynamic Type بأكبر حجم، VoiceOver على الشاشات الرئيسية.
- [ ] الخادم: HTTPS، `RETENTION_MINUTES` مطابق لما في سياسة الخصوصية، لا تسجيل لأسماء الملفات.
- [ ] إذا لم يُفعّل الخادم: الأدوات السحابية تظهر بوضوح «غير مفعّلة» (مطبق) — أو أخفها قبل النشر إن أردت.

## 4) بيانات App Store Connect
- **الفئة**: Productivity (الإنتاجية).
- **App Privacy («ملصق الخصوصية»)**: «Data Not Collected» صحيح طالما: لا تحليلات، لا حسابات، والملفات المرفوعة تُعالج وتُحذف فوراً ولا تُربط بهوية. (ملف `PrivacyInfo.xcprivacy` مطابق لذلك.) إذا أضفت لاحقاً تحليلات أو تقارير أعطال، حدّث الملصق والملف.
- **Export Compliance**: `ITSAppUsesNonExemptEncryption = false` (يستخدم تشفير النظام فقط: HTTPS وتشفير PDF القياسي).
- **ملاحظات للمراجع**: اذكر أن معظم الأدوات تعمل بلا حساب ولا إنترنت، وأن الأدوات السحابية تطلب موافقة قبل الرفع، وأن التوقيع مرئي وليس رقمياً معتمداً.
- **لقطات الشاشة**: تخرج من CI (artifact `ios-test-results`) لأحجام iPhone 6.9″؛ أضف 6.5″ إن طُلب.
- **الاسم والعلامة**: «ورقة | Waraqa» هوية مستقلة؛ لا تستخدم اسم iLovePDF أو شعاره في الاسم أو الوصف أو الكلمات المفتاحية.

## 5) بعد النشر
- راقب التقارير في Xcode Organizer (Crashes / Energy).
- كل تحديث: ارفع `CURRENT_PROJECT_VERSION`، و`MARKETING_VERSION` عند الإصدارات الظاهرة.
