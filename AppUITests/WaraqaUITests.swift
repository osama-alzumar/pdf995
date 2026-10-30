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
        app.swipeDown()
        app.buttons["protect.add"].tap()
        XCTAssertTrue(app.staticTexts["من الصور"].waitForExistence(timeout: 10), "the protect flow opens from Home")
        screenshot("02b-protect-pick-ar")
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

    // MARK: Every tool, end to end on generated sample files

    /// Runs each on-device tool through its real screen, runner and engine and expects the result
    /// screen (not an error). Server-only tools are hidden in this build and the editor-based tools
    /// have their own tests.
    func testEveryOnDeviceToolProducesAResult() {
        let tools = ["merge", "split", "removePages", "extractPages", "organize", "scanToPDF", "compress", "repair", "ocr",
                     "imagesToPDF", "htmlToPDF", "pdfToImages", "pdfToMarkdown", "rotate", "pageNumbers", "watermark", "crop",
                     "unlock", "protect", "redact", "compare", "convertImages", "shrinkImages"]
        var failures: [String] = []
        for tool in tools {
            let app = launch("ar", ["-WaraqaOpenTool", tool, "-WaraqaSampleFiles"])
            let run = app.buttons["تنفيذ"]
            guard run.waitForExistence(timeout: 15) else { failures.append("\(tool): no run button"); app.terminate(); continue }
            switch tool {
            case "removePages", "extractPages":
                type("2", into: app.textFields["1-3, 5, 8"], app)
            case "watermark":
                type("سري", into: app.textFields.firstMatch, app)
            case "protect":
                type("123456", into: app.secureTextFields["كلمة المرور"], app)
                type("123456", into: app.secureTextFields["تأكيد كلمة المرور"], app)
            case "redact":
                type("1000000001", into: app.textViews.firstMatch, app)
            default:
                break
            }
            reveal(run, in: app)
            guard run.isEnabled else { failures.append("\(tool): run button disabled"); app.terminate(); continue }
            run.tap()
            let done = app.buttons["ابدأ من جديد"]
            let failed = app.buttons["رجوع وتعديل الخيارات"]
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline && !done.exists && !failed.exists { _ = done.waitForExistence(timeout: 1) }
            if !done.exists {
                screenshot("failed-\(tool)")
                let message = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                failures.append("\(tool): \(failed.exists ? "error" : "timeout") — \(message.prefix(300))")
            }
            app.terminate()
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// Dark mode used to turn drawn signatures white. Draw in blue and check the placed
    /// signature on the page is really blue.
    func testSignatureKeepsItsColorInDarkMode() {
        let app = launch("ar", ["-WaraqaOpenTool", "sign", "-WaraqaSampleFiles", "-WaraqaDark"])
        let place = app.buttons["ضع توقيعك"]
        XCTAssertTrue(place.waitForExistence(timeout: 15))
        reveal(place, in: app)
        place.tap()
        XCTAssertTrue(app.navigationBars["اضغط حيث تريد التوقيع"].waitForExistence(timeout: 15))
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let canvas = app.otherElements["signature.canvas"].exists ? app.otherElements["signature.canvas"] : app.descendants(matching: .any)["signature.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "the signature sheet opens")
        app.buttons["ink.blue"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35)))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65)))
        screenshot("signature-sheet-dark")
        XCTAssertGreaterThan(bluePixels(app.screenshot()), 150, "the ink on the drawing area is blue")
        app.buttons["استخدم التوقيع"].tap()
        XCTAssertFalse(canvas.waitForExistence(timeout: 2) && canvas.isHittable)
        sleep(1)
        screenshot("signature-placed-dark")
        XCTAssertGreaterThan(bluePixels(app.screenshot()), 150, "the signature placed on the page is blue, not white")
        app.navigationBars.buttons["تم"].tap()
        XCTAssertTrue(app.staticTexts["تم بنجاح"].waitForExistence(timeout: 30), "the signed copy is produced")
    }

    /// The translation order form counts pages and prices them (10 SAR a page). Nothing is sent:
    /// the server side of orders is tested against a real server in WaraqaCore and the backend.
    func testCertifiedTranslationOrderForm() {
        let app = launch("ar", ["-WaraqaSampleFiles"])
        let open = app.buttons["translation.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15), "the translation card is on Home")
        open.tap()
        XCTAssertTrue(app.staticTexts["السعر: 10 ريال للصفحة."].waitForExistence(timeout: 10))
        app.buttons["translation.new"].tap()
        // Two generated 3-page PDFs → 6 pages → 60 SAR.
        let price = app.staticTexts["translation.price"]
        XCTAssertTrue(price.waitForExistence(timeout: 10))
        XCTAssertEqual(price.label, "60 ريال")
        type("سارة أحمد", into: app.textFields["translation.name"], app)
        type("0551234567", into: app.textFields["translation.phone"], app)
        let send = app.buttons["translation.send"]
        reveal(send, in: app)
        XCTAssertFalse(send.isEnabled, "needs the consent first")
        let agree = app.switches["translation.agree"]
        reveal(agree, in: app)
        agree.tap()
        if agree.value as? String == "0" { agree.switches.firstMatch.tap() }
        reveal(send, in: app)
        XCTAssertTrue(send.isEnabled)
        screenshot("11-translation-order-ar")
    }

    func testToolsAskForPlusAfterTheTrial() {
        let app = launch("ar", ["-WaraqaOpenTool", "merge", "-WaraqaTrialEnded"])
        XCTAssertTrue(app.buttons["tool.subscribe"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["تنفيذ"].exists)
        screenshot("12-trial-ended-ar")
    }

    // MARK: Helpers

    private func type(_ text: String, into field: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "field for \(text)")
        reveal(field, in: app)
        field.tap()
        field.typeText(text)
        if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
        else if app.keyboards.buttons["return"].exists { app.keyboards.buttons["return"].tap() }
        else if app.toolbars.buttons["Done"].exists { app.toolbars.buttons["Done"].tap() }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var tries = 0
        while !element.isHittable && tries < 6 { app.swipeUp(); tries += 1 }
    }

    /// Pixels of the fixed signature blue (r≈13 g≈89 b≈217), which nothing else in the UI uses.
    private func bluePixels(_ shot: XCUIScreenshot) -> Int {
        guard let cg = shot.image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var count = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            if b > 160 && r < 70 && g > 50 && g < 125 { count += 1 }
        }
        return count
    }
}
