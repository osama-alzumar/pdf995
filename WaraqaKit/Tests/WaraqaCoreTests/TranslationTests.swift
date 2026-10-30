import XCTest
@testable import WaraqaCore

final class TranslationTests: XCTestCase {
    func testPricing() {
        XCTAssertEqual(TranslationPricing.pricePerPageSAR, 10)
        XCTAssertEqual(TranslationPricing.total(pages: 3), 30)
        XCTAssertEqual(TranslationPricing.total(pages: -1), 0)
    }

    func testPhoneNumbers() {
        XCTAssertEqual(PhoneNumber.normalized("0551234567"), "966551234567")
        XCTAssertEqual(PhoneNumber.normalized("٠٥٥١٢٣٤٥٦٧"), "966551234567")
        XCTAssertEqual(PhoneNumber.normalized("+966 55 123 4567"), "966551234567")
        XCTAssertEqual(PhoneNumber.normalized("00971501234567"), "971501234567")
        XCTAssertNil(PhoneNumber.normalized("123"))
    }

    func testStatusDecodingFromServerJSON() throws {
        let json = """
        {"id":"abc","number":1001,"state":"awaiting_payment","pages":3,"price_sar":30,"source_language":"en",
         "target_language":"ar","message":"حوّل المبلغ","paid":false,"has_result":false,"result_name":null,
         "created_at":"2026-10-30T10:42:35+00:00","updated_at":"2026-10-30T10:42:35+00:00","owner_token":"t"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let created = try decoder.decode(CreateTranslationResponse.self, from: Data(json.utf8))
        XCTAssertEqual(created.ownerToken, "t")
        XCTAssertEqual(created.order.state, .awaitingPayment)
        XCTAssertEqual(created.order.priceSAR, 30)
        XCTAssertFalse(created.order.state.isFinished)
        XCTAssertEqual(Set(CertifiedLanguage.allCases.map(\.rawValue)),
                       ["ar", "en", "fr", "tr", "ur", "es", "de", "zh", "id", "other"], "same codes as the server")
    }

    func testToolTrialLastsThreeDays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let trial = ToolTrial(started: start)
        XCTAssertTrue(trial.isActive(now: start))
        XCTAssertEqual(trial.daysLeft(now: start), 3)
        XCTAssertEqual(trial.daysLeft(now: start.addingTimeInterval(86_400 * 2.5)), 1)
        XCTAssertTrue(trial.allowsTools(.free, now: start.addingTimeInterval(86_400 * 2.9)))
        XCTAssertFalse(trial.allowsTools(.free, now: start.addingTimeInterval(86_400 * 3)))
        XCTAssertEqual(trial.daysLeft(now: start.addingTimeInterval(86_400 * 4)), 0)
        XCTAssertTrue(trial.allowsTools(.subscribed(renews: nil, monthlyAllowance: 30), now: start.addingTimeInterval(86_400 * 30)))
    }
}
