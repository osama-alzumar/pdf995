import XCTest

/// Smoke tests on the simulator: the app launches in both languages, the home screen shows the
/// spec'd sections, every tool screen opens, and screenshots are attached for visual review.
final class WaraqaUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ language: String, tool: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-WaraqaLanguage", language] + (tool.map { ["-WaraqaOpenTool", $0] } ?? [])
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
        XCTAssertTrue(app.staticTexts["ماذا تريد أن تفعل بملفك؟"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["الأدوات السريعة"].exists)
        XCTAssertTrue(app.staticTexts["دمج PDF"].exists)
        XCTAssertTrue(app.staticTexts["ضغط PDF"].exists)
        XCTAssertTrue(app.staticTexts["PDF إلى Word"].exists)
        XCTAssertTrue(app.staticTexts["الصور إلى PDF"].exists)
        XCTAssertTrue(app.tabBars.buttons["ملفاتي"].exists)
        XCTAssertTrue(app.tabBars.buttons["الإعدادات"].exists)
        screenshot("01-home-ar")
        app.swipeUp()
        screenshot("02-home-all-tools-ar")
    }

    func testEnglishHomeAndSearch() {
        let app = launch("en")
        XCTAssertTrue(app.staticTexts["What do you want to do with your file?"].waitForExistence(timeout: 10))
        let search = app.textFields.firstMatch
        search.tap()
        search.typeText("sign")
        XCTAssertTrue(app.staticTexts["Sign PDF"].waitForExistence(timeout: 5))
        screenshot("03-search-en")
    }

    func testArabicSearchWithoutHamza() {
        let app = launch("ar")
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("اكسل")
        XCTAssertTrue(app.staticTexts["Excel إلى PDF"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["PDF إلى Excel"].exists)
    }

    func testEveryToolScreenOpens() {
        let tools = ["merge", "split", "removePages", "extractPages", "organize", "scanToPDF", "compress", "repair", "ocr",
                     "imagesToPDF", "wordToPDF", "powerPointToPDF", "excelToPDF", "htmlToPDF", "pdfToImages", "pdfToWord",
                     "pdfToPowerPoint", "pdfToExcel", "pdfToPDFA", "pdfToMarkdown", "rotate", "pageNumbers", "watermark", "crop",
                     "edit", "forms", "unlock", "protect", "sign", "redact", "compare", "summarize", "translate", "intelligence"]
        for tool in tools {
            let app = launch("ar", tool: tool)
            // Every tool screen has its big action button.
            let run = app.buttons.matching(NSPredicate(format: "label IN %@", ["تنفيذ", "افتح المحرر", "ضع توقيعك", "افتح النموذج", "حلّل الملف"])).firstMatch
            XCTAssertTrue(run.waitForExistence(timeout: 10), "tool screen \(tool) has no action button")
            if ["merge", "compress", "sign", "pdfToWord"].contains(tool) { screenshot("tool-\(tool)-ar") }
            app.terminate()
        }
    }

    func testSettingsAndFiles() {
        let app = launch("ar")
        app.tabBars.buttons["الإعدادات"].tap()
        XCTAssertTrue(app.staticTexts["الخصوصية"].waitForExistence(timeout: 5))
        screenshot("04-settings-ar")
        app.tabBars.buttons["ملفاتي"].tap()
        XCTAssertTrue(app.staticTexts["لا توجد ملفات بعد"].waitForExistence(timeout: 5))
        screenshot("05-files-ar")
    }
}
