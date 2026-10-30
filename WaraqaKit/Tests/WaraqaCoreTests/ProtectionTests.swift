import XCTest
@testable import WaraqaCore

final class ProtectionSpecTests: XCTestCase {
    func spec() -> ProtectionSpec {
        var s = ProtectionSpec()
        s.recipient = "مكتب الأمل العقاري"
        s.purpose = .identity
        s.date = ISO8601DateFormatter().date(from: "2026-10-30T09:00:00Z")!
        return s
    }

    func testSentenceNamesRecipientPurposeAndDate() {
        let s = spec()
        XCTAssertEqual(s.sentence, "مخصص لـمكتب الأمل العقاري — التحقق من الهوية فقط — غير صالح لأي استخدام آخر — 2026/10/30")
        XCTAssertEqual(s.shortText, "مكتب الأمل العقاري · التحقق من الهوية · 2026/10/30")
    }

    func testCustomTextAndPurpose() {
        var s = spec()
        s.purpose = .other
        s.customPurpose = "فتح ملف تأمين"
        XCTAssertTrue(s.sentence.contains("فتح ملف تأمين فقط"))
        s.customText = "نسخة مقدمة للمكتب"
        s.includeDate = false
        XCTAssertEqual(s.sentence, "نسخة مقدمة للمكتب")
        XCTAssertEqual(s.shortText, "نسخة مقدمة للمكتب")
    }

    func testEmptyRecipientHasPlaceholderAndStampIsNotOfficial() {
        var s = spec()
        s.recipient = "   "
        XCTAssertTrue(s.sentence.contains("الجهة المستلمة"))
        XCTAssertEqual(s.stampLines.last, "ليست وثيقة رسمية ولا تمثل اعتماداً من أي جهة")
        s.language = .english
        XCTAssertEqual(s.stampLines.last, "Not an official document or endorsement")
        XCTAssertTrue(s.sentence.hasPrefix("For the recipient — Identity verification only"))
    }

    func testNormalizedClampsSliderValues() {
        var s = spec()
        s.opacity = 5; s.angleDegrees = 400; s.fontSize = 1; s.spacing = 9
        s.recipient = String(repeating: "م", count: 300)
        let n = s.normalized
        XCTAssertEqual(n.opacity, 0.9)
        XCTAssertEqual(n.angleDegrees, 90)
        XCTAssertEqual(n.fontSize, 8)
        XCTAssertEqual(n.spacing, 2.0)
        XCTAssertEqual(n.recipient.count, 80)
    }

    func testSpecRoundTripsThroughJSON() throws {
        let s = spec()
        let back = try JSONDecoder().decode(ProtectionSpec.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}

final class SensitiveDataTests: XCTestCase {
    func kinds(_ line: String) -> [SensitiveDataDetector.Kind] {
        SensitiveDataDetector.detect(in: line).map(\.kind)
    }

    func testIDsPhonesIBANsCards() {
        XCTAssertEqual(kinds("رقم الهوية 1023456789"), [.nationalID])
        XCTAssertEqual(kinds("الإقامة: 2456789012"), [.nationalID])
        XCTAssertEqual(kinds("جوال 0551234567"), [.phone])
        XCTAssertEqual(kinds("+966 55 123 4567"), [.phone])
        XCTAssertEqual(kinds("IBAN SA03 8000 0000 6080 1016 7519"), [.iban])
        XCTAssertEqual(kinds("بطاقة 4111 1111 1111 1111"), [.cardNumber])
        XCTAssertEqual(kinds("mail: a.b@example.com"), [.email])
    }

    func testArabicIndicDigits() {
        XCTAssertEqual(kinds("رقم الهوية ١٠٢٣٤٥٦٧٨٩"), [.nationalID])
        XCTAssertEqual(kinds("الجوال ٠٥٥١٢٣٤٥٦٧"), [.phone])
    }

    func testLabelledLinesAreHiddenWhole() {
        let birth = SensitiveDataDetector.detect(in: "تاريخ الميلاد: 1990/01/01")
        XCTAssertEqual(birth.map(\.kind), [.birthDate])
        XCTAssertTrue(birth[0].wholeLine)
        let address = SensitiveDataDetector.detect(in: "العنوان: حي النرجس، الرياض")
        XCTAssertEqual(address.map(\.kind), [.address])
        XCTAssertTrue(address[0].wholeLine)
    }

    func testOffsetsPointAtTheValue() {
        let line = "الجوال 0551234567 للتواصل"
        let m = SensitiveDataDetector.detect(in: line)[0]
        XCTAssertEqual((line as NSString).substring(with: NSRange(location: m.offset, length: m.length)), "0551234567")
    }

    func testOrdinaryTextHasNothing() {
        XCTAssertEqual(kinds("يلتزم المستأجر بالمحافظة على العين المؤجرة"), [])
        XCTAssertEqual(kinds("Page 3 of 10"), [])
        XCTAssertEqual(kinds("رقم 12345"), [])
    }

    func testDefaults() {
        XCTAssertTrue(SensitiveDataDetector.Kind.nationalID.hiddenByDefault)
        XCTAssertFalse(SensitiveDataDetector.Kind.date.hiddenByDefault)
    }
}

final class ClassifierTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(DocumentClassifier.classify("المملكة العربية السعودية بطاقة الهوية الوطنية رقم الهوية").kind, .nationalID)
        XCTAssertEqual(DocumentClassifier.classify("PASSPORT P<SAU nationality").kind, .passport)
        XCTAssertEqual(DocumentClassifier.classify("كشف حساب الرصيد آيبان").kind, .bankStatement)
        XCTAssertEqual(DocumentClassifier.classify("عقد إيجار الطرف الأول المؤجر الطرف الثاني المستأجر").kind, .contract)
        XCTAssertEqual(DocumentClassifier.classify("شهادة تخرج يشهد").kind, .certificate)
        XCTAssertEqual(DocumentClassifier.classify("رخصة قيادة").kind, .driverLicense)
        let none = DocumentClassifier.classify("قائمة مشتريات خبز حليب")
        XCTAssertEqual(none.kind, .other)
        XCTAssertEqual(none.confidence, 0)
    }

    func testSuggestionsAreConsistent() {
        XCTAssertEqual(DocumentKind.nationalID.suggestedPurpose, .identity)
        XCTAssertEqual(DocumentKind.nationalID.suggestedStyle, .tiled)
        XCTAssertEqual(DocumentKind.bankStatement.folder, .financial)
        for kind in DocumentKind.allCases { XCTAssertFalse(kind.title.ar.isEmpty) }
    }
}

final class QuotaTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-30T09:00:00Z")!

    func testThreeFreeThenPurchase() {
        var q = ProtectionQuota()
        for expected in [2, 1, 0] {
            guard case .success(let source) = q.check(entitlement: .free, pages: 1, now: now) else { return XCTFail() }
            XCTAssertEqual(source, .free(remainingAfter: expected))
            q.consume(source, now: now)
        }
        XCTAssertEqual(q.check(entitlement: .free, pages: 1, now: now), .failure(.needsPurchase))
    }

    func testCreditsAndPageLimit() {
        var q = ProtectionQuota(freeUsed: 3, credits: 2)
        XCTAssertEqual(q.check(entitlement: .free, pages: 25, now: now), .failure(.tooManyPages(limit: PlanRules.pagesPerDocument)))
        guard case .success(let s) = q.check(entitlement: .free, pages: 2, now: now) else { return XCTFail() }
        XCTAssertEqual(s, .credit(remainingAfter: 1))
        q.consume(s, now: now)
        XCTAssertEqual(q.credits, 1)
    }

    func testSubscriptionMonthlyAllowanceResetsEachMonth() {
        var q = ProtectionQuota(freeUsed: 3)
        let sub = Entitlement.subscribed(renews: nil, monthlyAllowance: 2)
        for _ in 0..<2 {
            guard case .success(let s) = q.check(entitlement: sub, pages: 80, now: now) else { return XCTFail() }
            q.consume(s, now: now)
        }
        XCTAssertEqual(q.check(entitlement: sub, pages: 1, now: now), .failure(.monthlyLimitReached(limit: 2)))
        let nextMonth = ISO8601DateFormatter().date(from: "2026-11-02T09:00:00Z")!
        XCTAssertEqual(q.check(entitlement: sub, pages: 1, now: nextMonth), .success(.subscription(remainingAfter: 1)))
        q.credits = 1
        XCTAssertEqual(q.check(entitlement: sub, pages: 1, now: now), .success(.credit(remainingAfter: 0)))
    }

    func testMonthKeyUsesRiyadhTime() {
        // 2026-10-31 22:30 UTC is already November 1st in Riyadh.
        let late = ISO8601DateFormatter().date(from: "2026-10-31T22:30:00Z")!
        XCTAssertEqual(ProtectionQuota.monthKey(late), "2026-11")
    }
}

final class ShareModelTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(ShareDuration.allCases.map(\.seconds), [600, 3600, 86_400, 604_800])
    }

    func testStatusDecodingFromServerJSON() throws {
        let json = #"{"id":"abc","state":"active","opens":2,"max_views":3,"last_opened_at":"2026-10-30T09:10:00.123456+00:00","expires_at":"2026-10-31T09:00:00+00:00"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: raw) { return date }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: raw)!
        }
        let s = try decoder.decode(ShareStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.state, .active)
        XCTAssertEqual(s.opens, 2)
        XCTAssertNotNil(s.lastOpenedAt)
    }
}
