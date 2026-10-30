import XCTest

/// Simulator checks for design B: the app launches in both languages, the four tabs work, the
/// protection journey runs end to end on a generated sample, every tool screen opens, and
/// screenshots are attached for review / the App Store.
final class WaraqaUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ language: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-WaraqaLanguage", language, "-WaraqaUITestUnlocked"] + extra
        app.launch()
        return app
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testArabicHome() {
        let app = launch("ar")
        XCTAssertTrue(app.staticTexts["احمِ مستندك"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["protect.add"].exists)
        XCTAssertTrue(app.staticTexts["أدوات الملفات"].exists)
        for tab in ["الرئيسية", "أدوات PDF", "مستنداتي", "حسابي"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists, tab)
        }
        screenshot("01-home-ar")
        app.swipeUp()
        screenshot("02-home-recents-ar")
    }

    func testProtectJourneyWithSample() {
        let app = launch("ar", ["-WaraqaDemoProtect"])
        let recipient = app.textFields.firstMatch
        XCTAssertTrue(recipient.waitForExistence(timeout: 20), "the editor opens with the sample")
        recipient.tap()
        recipient.typeText("مكتب الأمل العقاري")
        app.buttons["متكررة"].tap()
        sleep(2) // the live preview is rendered by the engine
        screenshot("03-editor-ar")
        app.buttons["إنشاء النسخة المحمية"].tap()
        XCTAssertTrue(app.staticTexts["تمت حماية المستند"].waitForExistence(timeout: 30))
        screenshot("04-result-ar")
    }

    func testHideDataSuggestsSensitiveNumbers() {
        let app = launch("ar", ["-WaraqaDemoProtect"])
        let hide = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'إخفاء بيانات'")).firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 20))
        sleep(4) // on-device reading of the sample
        hide.tap()
        XCTAssertTrue(app.staticTexts["رقم الهوية / الإقامة"].waitForExistence(timeout: 20), "the ID number is suggested for hiding")
        screenshot("05-hide-data-ar")
    }

    func testEnglishToolsSearch() {
        let app = launch("en")
        app.tabBars.buttons["PDF tools"].tap()
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("sign")
        XCTAssertTrue(app.staticTexts["Sign PDF"].waitForExistence(timeout: 5))
        screenshot("06-tools-search-en")
    }

    func testArabicSearchWithoutHamza() {
        let app = launch("ar")
        app.tabBars.buttons["أدوات PDF"].tap()
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        screenshot("07-tools-ar")
        search.tap()
        search.typeText("ازالة") // typed without hamza
        XCTAssertTrue(app.staticTexts["إزالة علامة ورقة"].waitForExistence(timeout: 5))
    }

    func testEveryToolScreenOpens() {
        let tools = ["merge", "split", "removePages", "extractPages", "organize", "scanToPDF", "compress", "repair", "ocr",
                     "imagesToPDF", "wordToPDF", "powerPointToPDF", "excelToPDF", "htmlToPDF", "pdfToImages", "pdfToWord",
                     "pdfToPowerPoint", "pdfToExcel", "pdfToPDFA", "pdfToMarkdown", "rotate", "pageNumbers", "watermark", "crop",
                     "edit", "forms", "unlock", "protect", "sign", "redact", "compare", "summarize", "translate", "intelligence",
                     "convertImages", "shrinkImages"]
        for tool in tools {
            let app = launch("ar", ["-WaraqaOpenTool", tool])
            let run = app.buttons.matching(NSPredicate(format: "label IN %@", ["تنفيذ", "افتح المحرر", "ضع توقيعك", "افتح النموذج", "حلّل الملف"])).firstMatch
            XCTAssertTrue(run.waitForExistence(timeout: 10), "tool screen \(tool) has no action button")
            if ["merge", "compress", "convertImages"].contains(tool) { screenshot("tool-\(tool)-ar") }
            app.terminate()
        }
    }

    func testDocumentsAndAccount() {
        let app = launch("ar")
        app.tabBars.buttons["مستنداتي"].tap()
        // The simulator has no passcode, so the wallet opens without Face ID (still encrypted).
        XCTAssertTrue(app.staticTexts["هوياتي"].waitForExistence(timeout: 10))
        screenshot("08-documents-ar")
        app.tabBars.buttons["حسابي"].tap()
        XCTAssertTrue(app.staticTexts["الخصوصية والأمان"].waitForExistence(timeout: 5))
        screenshot("09-account-ar")
    }

    func testDarkModeHome() {
        let app = XCUIApplication()
        app.launchArguments = ["-WaraqaLanguage", "ar", "-WaraqaDark"]
        app.launch()
        XCTAssertTrue(app.staticTexts["احمِ مستندك"].waitForExistence(timeout: 10))
        screenshot("10-home-dark-ar")
    }
}
