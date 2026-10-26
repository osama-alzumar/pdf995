#if canImport(PDFKit)
import XCTest
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import PDFEngine
import WaraqaCore

final class PDFEngineTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = Fixtures.dir()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// Runs `body` and checks the input file is byte-for-byte unchanged afterwards.
    func assertUntouched(_ inputs: URL..., body: () throws -> Void) rethrows {
        let before = inputs.map(Fixtures.sha256)
        try body()
        XCTAssertEqual(inputs.map(Fixtures.sha256), before, "the original file must never be modified")
    }

    func containsArabic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0xFE70...0xFEFF).contains($0.value) }
    }

    // MARK: Organize

    func testMergeKeepsOrderAndPages() throws {
        let a = file("a.pdf"), b = file("b.pdf"), out = file("merged.pdf")
        Fixtures.simplePDF(["Alpha one", "Alpha two", "Alpha three"], at: a)
        Fixtures.simplePDF(["Beta one", "Beta two"], at: b)
        try assertUntouched(a, b) {
            try PDFEngine.merge([PDFInput(url: a), PDFInput(url: b)], to: out)
        }
        XCTAssertEqual(Fixtures.pageCount(out), 5)
        XCTAssertTrue(Fixtures.text(out, page: 0).contains("Alpha one"))
        XCTAssertTrue(Fixtures.text(out, page: 3).contains("Beta one"))
        XCTAssertTrue(Fixtures.text(out, page: 4).contains("Beta two"))
    }

    func testMergeEncryptedInputNeedsPassword() throws {
        let a = file("a.pdf"), locked = file("locked.pdf"), out = file("m.pdf")
        Fixtures.simplePDF(["Plain"], at: a)
        Fixtures.encryptedPDF(["Locked page"], password: "1234", at: locked)
        XCTAssertThrowsError(try PDFEngine.merge([PDFInput(url: a), PDFInput(url: locked)], to: out)) {
            XCTAssertEqual($0 as? WaraqaError, .passwordRequired)
        }
        try PDFEngine.merge([PDFInput(url: a), PDFInput(url: locked, password: "1234")], to: out)
        XCTAssertEqual(Fixtures.pageCount(out), 2)
        XCTAssertTrue(Fixtures.text(out, page: 1).contains("Locked page"))
        XCTAssertFalse(PDFDocument(url: out)!.isEncrypted)
    }

    func testSplitModes() throws {
        let src = file("ten.pdf")
        Fixtures.simplePDF((1...10).map { "Page number \($0)" }, at: src)
        let parts = try PDFEngine.split(PDFInput(url: src), mode: .everyN(4), into: file("parts"), baseName: "ten.pdf")
        XCTAssertEqual(parts.map(Fixtures.pageCount), [4, 4, 2])
        XCTAssertEqual(parts.map(\.lastPathComponent), ["ten - 1.pdf", "ten - 2.pdf", "ten - 3.pdf"])
        XCTAssertTrue(Fixtures.text(parts[2], page: 0).contains("Page number 9"))

        let ranges = try PageSelection.parse("1-2, 5, 7-", pageCount: 10)
        let byRange = try PDFEngine.split(PDFInput(url: src), mode: .ranges(ranges), into: file("r"), baseName: "x.pdf")
        XCTAssertEqual(byRange.map(Fixtures.pageCount), [2, 1, 4])
        XCTAssertEqual(try PDFEngine.split(PDFInput(url: src), mode: .everyPage, into: file("e"), baseName: "y.pdf").count, 10)
    }

    func testExtractRemoveOrganizeRotate() throws {
        let src = file("five.pdf")
        Fixtures.simplePDF(["P1", "P2", "P3", "P4", "P5"], at: src)
        try assertUntouched(src) {
            try PDFEngine.extract(PDFInput(url: src), pages: [4, 0], to: file("ex.pdf"))
            try PDFEngine.remove(PDFInput(url: src), pages: [1, 2], to: file("rm.pdf"))
            try PDFEngine.organize(PDFInput(url: src), pages: [PageEdit(sourceIndex: 2, extraRotation: 90), PageEdit(sourceIndex: 0)],
                                   to: file("org.pdf"))
            try PDFEngine.rotate(PDFInput(url: src), degrees: 270, pages: [1], to: file("rot.pdf"))
        }
        XCTAssertEqual(Fixtures.text(file("ex.pdf"), page: 0).trimmingCharacters(in: .whitespacesAndNewlines), "P5")
        XCTAssertEqual(Fixtures.pageCount(file("rm.pdf")), 3)
        XCTAssertTrue(Fixtures.text(file("rm.pdf"), page: 1).contains("P4"))
        let org = PDFDocument(url: file("org.pdf"))!
        XCTAssertEqual(org.pageCount, 2)
        XCTAssertEqual(org.page(at: 0)?.rotation, 90)
        XCTAssertTrue(org.page(at: 0)!.string!.contains("P3"))
        let rot = PDFDocument(url: file("rot.pdf"))!
        XCTAssertEqual(rot.page(at: 1)?.rotation, 270)
        XCTAssertEqual(rot.page(at: 0)?.rotation, 0)

        XCTAssertThrowsError(try PDFEngine.remove(PDFInput(url: src), pages: [0, 1, 2, 3, 4], to: file("none.pdf"))) {
            XCTAssertEqual($0 as? WaraqaError, .cannotRemoveAllPages)
        }
        XCTAssertThrowsError(try PDFEngine.extract(PDFInput(url: src), pages: [9], to: file("bad.pdf")))
    }

    func testHundredPageDocument() throws {
        let src = file("hundred.pdf")
        Fixtures.simplePDF((1...100).map { "Long document page \($0)" }, at: src)
        let start = Date()
        let parts = try PDFEngine.split(PDFInput(url: src), mode: .everyN(10), into: file("h"), baseName: "h.pdf")
        try PDFEngine.merge(parts.map { PDFInput(url: $0) }, to: file("back.pdf"))
        XCTAssertEqual(Fixtures.pageCount(file("back.pdf")), 100)
        XCTAssertTrue(Fixtures.text(file("back.pdf"), page: 99).contains("page 100"))
        try PDFEngine.addPageNumbers(PDFInput(url: src), options: PageNumberOptions(), to: file("num.pdf"))
        XCTAssertEqual(Fixtures.pageCount(file("num.pdf")), 100)
        XCTAssertLessThan(Date().timeIntervalSince(start), 60)
    }

    // MARK: Convert

    func testImagesToPDF() throws {
        let jpg = file("photo.jpg"), png = file("shot.png"), rotated = file("rotated.jpg")
        Fixtures.writeImage(Fixtures.photo(width: 1600, height: 1200), type: .jpeg, to: jpg)
        Fixtures.writeImage(Fixtures.photo(width: 600, height: 900), type: .png, to: png)
        // EXIF orientation 6 = rotate 90° CW to display: a 1600×1200 file displays as portrait.
        Fixtures.writeImage(Fixtures.photo(width: 1600, height: 1200), type: .jpeg, to: rotated, orientation: 6)

        let out = file("images.pdf")
        try PDFEngine.imagesToPDF([.file(jpg), .file(png), .file(rotated)], pageSize: .a4, margin: 20, to: out)
        let doc = PDFDocument(url: out)!
        XCTAssertEqual(doc.pageCount, 3)
        let landscape = doc.page(at: 0)!.bounds(for: .mediaBox)
        XCTAssertEqual(landscape.width, 841.89, accuracy: 0.5)
        let portrait = doc.page(at: 2)!.bounds(for: .mediaBox)
        XCTAssertEqual(portrait.width, 595.28, accuracy: 0.5, "EXIF orientation must be honored")

        let fit = file("fit.pdf")
        try PDFEngine.imagesToPDF([.file(png)], pageSize: .fit, to: fit)
        let page = PDFDocument(url: fit)!.page(at: 0)!.bounds(for: .mediaBox)
        XCTAssertEqual(page.width / page.height, 600.0 / 900.0, accuracy: 0.01)

        XCTAssertThrowsError(try PDFEngine.imagesToPDF([.data(Data("not an image".utf8))], to: file("x.pdf")))
    }

    func testPDFToImages() throws {
        let src = file("doc.pdf")
        Fixtures.simplePDF(["One", "Two"], at: src)
        let images = try PDFEngine.pdfToImages(PDFInput(url: src), format: .png, dpi: 100, into: file("img"), baseName: "doc.pdf")
        XCTAssertEqual(images.count, 2)
        let source = CGImageSourceCreateWithURL(images[0] as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, Int((595.0 * 100 / 72).rounded()))
        let jpgs = try PDFEngine.pdfToImages(PDFInput(url: src), format: .jpeg, pages: [1], into: file("j"), baseName: "doc.pdf")
        XCTAssertEqual(jpgs.map(\.lastPathComponent), ["doc - 2.jpg"])
    }

    func testMarkdownFindsStructure() throws {
        let src = file("report.pdf")
        Fixtures.textPDF([[
            .init(text: "Quarterly Report", size: 26, bold: true),
            .init(text: "This report explains the results of the quarter in detail."),
            .init(text: "Results", size: 19, bold: true),
            .init(text: "• Sales went up"),
            .init(text: "Closing paragraph text here."),
        ]], at: src)
        let md = try PDFEngine.markdown(PDFInput(url: src))
        XCTAssertTrue(md.contains("# Quarterly Report"), md)
        XCTAssertTrue(md.contains("## Results") || md.contains("### Results"), md)
        XCTAssertTrue(md.contains("- Sales went up"), md)

        let scanned = file("scan.pdf")
        Fixtures.scannedPDF(lines: ["Hello"], at: scanned)
        XCTAssertThrowsError(try PDFEngine.markdown(PDFInput(url: scanned))) { XCTAssertEqual($0 as? WaraqaError, .noTextFound) }
    }

    func testArabicTextSurvivesProcessing() throws {
        let src = file("arabic.pdf")
        Fixtures.textPDF([[.init(text: "عقد إيجار سكني", size: 22, bold: true), .init(text: "يلتزم المستأجر بدفع الإيجار في موعده")]], at: src)
        XCTAssertTrue(containsArabic(Fixtures.text(src, page: 0)), "fixture must have an Arabic text layer")
        try PDFEngine.addPageNumbers(PDFInput(url: src), options: PageNumberOptions(), to: file("n.pdf"))
        XCTAssertTrue(containsArabic(Fixtures.text(file("n.pdf"), page: 0)), "redrawn pages must keep their text layer")
        let lines = try PDFEngine.textLines(PDFInput(url: src))
        XCTAssertGreaterThan(lines.count, 1)
    }

    func testTextToPDFArabicAndPagination() throws {
        let out = file("translated.pdf")
        let long = String(repeating: "هذه فقرة عربية طويلة لاختبار التخطيط من اليمين إلى اليسار. ", count: 400)
        try PDFEngine.textToPDF(pages: [long, "Second source page"], title: "ترجمة", rightToLeft: true, to: out)
        let doc = PDFDocument(url: out)!
        XCTAssertGreaterThan(doc.pageCount, 2)
        XCTAssertTrue(containsArabic(doc.page(at: 0)?.string ?? ""))
        XCTAssertThrowsError(try PDFEngine.textToPDF(pages: ["  "], rightToLeft: false, to: file("empty.pdf")))
    }

    // MARK: Optimize

    func testCompressionLevelsReportRealSizes() throws {
        let src = file("photos.pdf")
        Fixtures.photoPDF(pages: 3, at: src)
        let original = PDFEngine.fileSize(src)
        for level in CompressionLevel.allCases {
            let out = file("c-\(level.rawValue).pdf")
            let report = try PDFEngine.compress(PDFInput(url: src), level: level, to: out)
            XCTAssertEqual(report.originalBytes, original)
            XCTAssertEqual(report.compressedBytes, PDFEngine.fileSize(out), "\(level)")
            XCTAssertEqual(Fixtures.pageCount(out), 3)
            XCTAssertLessThanOrEqual(report.compressedBytes, original)
            print("compress \(level): \(original) → \(report.compressedBytes) (\(report.savedPercent)%)")
        }
        let strong = try PDFEngine.compress(PDFInput(url: src), level: .strong, to: file("s.pdf"))
        XCTAssertTrue(strong.isSmaller)
        XCTAssertGreaterThan(strong.savedPercent, 50)
    }

    func testCompressNeverGrowsTheFile() throws {
        let src = file("tiny.pdf")
        Fixtures.simplePDF(["Tiny"], at: src)
        let out = file("tiny-c.pdf")
        let report = try PDFEngine.compress(PDFInput(url: src), level: .strong, to: out)
        XCTAssertLessThanOrEqual(PDFEngine.fileSize(out), PDFEngine.fileSize(src))
        if !report.isSmaller { XCTAssertEqual(Fixtures.sha256(out), Fixtures.sha256(src)) }
    }

    func testRepair() throws {
        let good = file("good.pdf")
        Fixtures.simplePDF(["Recoverable page one", "Recoverable page two"], at: good)
        var junk = Data("GARBAGE-BYTES-BEFORE-HEADER\n".utf8)
        junk.append(try Data(contentsOf: good))
        let broken = file("broken.pdf")
        try junk.write(to: broken)
        let out = file("repaired.pdf")
        XCTAssertEqual(try PDFEngine.repair(PDFInput(url: broken), to: out), 2)
        XCTAssertTrue(Fixtures.text(out, page: 1).contains("page two"))

        let garbage = file("garbage.pdf")
        try Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 * 31) }).write(to: garbage)
        XCTAssertThrowsError(try PDFEngine.repair(PDFInput(url: garbage), to: file("no.pdf"))) {
            XCTAssertEqual($0 as? WaraqaError, .cannotOpen(fileName: "garbage.pdf"))
        }
        XCTAssertThrowsError(try PDFEngine.open(garbage))
    }

    // MARK: Edit

    func testPageNumbersAndTextPreservation() throws {
        let src = file("doc.pdf")
        Fixtures.simplePDF(["Body text A", "Body text B", "Body text C"], at: src)
        var options = PageNumberOptions()
        options.style = .numberOfTotal
        try PDFEngine.addPageNumbers(PDFInput(url: src), options: options, to: file("n.pdf"))
        let page2 = Fixtures.text(file("n.pdf"), page: 1)
        XCTAssertTrue(page2.contains("Body text B"), "original text must remain selectable")
        XCTAssertTrue(page2.contains("2 / 3"), page2)
    }

    func testWatermarkTextAndImage() throws {
        let src = file("doc.pdf")
        Fixtures.simplePDF(["Content one", "Content two"], at: src)
        var options = WatermarkOptions()
        options.text = "CONFIDENTIAL"
        options.pages = [1]
        try PDFEngine.addWatermark(PDFInput(url: src), options: options, to: file("w.pdf"))
        XCTAssertFalse(Fixtures.text(file("w.pdf"), page: 0).contains("CONFIDENTIAL"))
        XCTAssertTrue(Fixtures.text(file("w.pdf"), page: 1).contains("CONFIDENTIAL"))
        XCTAssertTrue(Fixtures.text(file("w.pdf"), page: 1).contains("Content two"))

        let logo = file("logo.png")
        Fixtures.writeImage(Fixtures.photo(width: 200, height: 100), type: .png, to: logo)
        var imageOptions = WatermarkOptions()
        imageOptions.imageData = try Data(contentsOf: logo)
        imageOptions.layout = .tiled
        try PDFEngine.addWatermark(PDFInput(url: src), options: imageOptions, to: file("wi.pdf"))
        XCTAssertEqual(Fixtures.pageCount(file("wi.pdf")), 2)

        var arabic = WatermarkOptions()
        arabic.text = "سري للغاية"
        try PDFEngine.addWatermark(PDFInput(url: src), options: arabic, to: file("wa.pdf"))
        XCTAssertThrowsError(try PDFEngine.addWatermark(PDFInput(url: src), options: WatermarkOptions(), to: file("none.pdf")))
    }

    func testCropAndAutoDetect() throws {
        let src = file("doc.pdf")
        Fixtures.simplePDF(["Cropped content"], at: src)
        try PDFEngine.crop(PDFInput(url: src), margins: CropMargins(top: 50, bottom: 40, left: 30, right: 20), to: file("c.pdf"))
        let box = PDFDocument(url: file("c.pdf"))!.page(at: 0)!.bounds(for: .cropBox)
        XCTAssertEqual(box.width, 595 - 50, accuracy: 0.5)
        XCTAssertEqual(box.height, 842 - 90, accuracy: 0.5)
        let auto = try PDFEngine.detectContentMargins(PDFInput(url: src), page: 0)
        XCTAssertGreaterThan(auto.right, 100, "plenty of white space right of a short line")
        XCTAssertGreaterThan(auto.bottom, 300)
        XCTAssertThrowsError(try PDFEngine.crop(PDFInput(url: src), margins: CropMargins(left: 400, right: 400), to: file("x.pdf")))
    }

    func testEditorItemsAreBurnedIn() throws {
        let src = file("doc.pdf")
        Fixtures.simplePDF(["Original"], at: src)
        let sig = file("sig.png")
        Fixtures.writeImage(Fixtures.photo(width: 300, height: 100), type: .png, to: sig)
        let items: [EditItem] = [
            EditItem(pageIndex: 0, rect: PageRect(x: 60, y: 500, width: 300, height: 40), kind: .text("Added by editor", fontSize: 14, bold: false)),
            EditItem(pageIndex: 0, rect: PageRect(x: 60, y: 400, width: 150, height: 50), kind: .image(try Data(contentsOf: sig))),
            EditItem(pageIndex: 0, rect: PageRect(x: 60, y: 300, width: 100, height: 50), kind: .rectangle(filled: false, lineWidth: 2)),
            EditItem(pageIndex: 0, rect: PageRect(x: 60, y: 200, width: 100, height: 50), kind: .ellipse(filled: true, lineWidth: 1)),
            EditItem(pageIndex: 0, rect: PageRect(x: 60, y: 100, width: 100, height: 50), kind: .line(lineWidth: 2, arrow: true)),
            EditItem(pageIndex: 0, rect: PageRect(x: 0, y: 0, width: 1, height: 1),
                     kind: .ink([[PagePoint(x: 300, y: 300), PagePoint(x: 350, y: 320), PagePoint(x: 400, y: 280)]], lineWidth: 3)),
            EditItem(pageIndex: 0, rect: PageRect(x: 55, y: 760, width: 120, height: 20), kind: .highlight, colorHex: "#FFE600"),
            EditItem(pageIndex: 0, rect: PageRect(x: 350, y: 600, width: 180, height: 60), kind: .note("ملاحظة: راجع البند")),
        ]
        try assertUntouched(src) {
            try PDFEngine.applyEdits(PDFInput(url: src), items: items, to: file("e.pdf"))
        }
        let out = PDFDocument(url: file("e.pdf"))!
        XCTAssertEqual(out.page(at: 0)?.annotations.count, 0, "items are part of the page, not removable annotations")
        let text = out.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("Added by editor"), text)
        XCTAssertTrue(text.contains("Original"), text)
    }

    func testFormsCreateAndFill() throws {
        let src = file("form.pdf")
        Fixtures.simplePDF(["Name:"], at: src)
        try PDFEngine.updateForm(PDFInput(url: src), newFields: [
            .init(pageIndex: 0, rect: PageRect(x: 150, y: 690, width: 200, height: 24), name: "full_name", kind: .text),
            .init(pageIndex: 0, rect: PageRect(x: 150, y: 650, width: 18, height: 18), name: "agree", kind: .checkbox),
        ], values: [:], to: file("f1.pdf"))
        let fields = try PDFEngine.formFields(PDFInput(url: file("f1.pdf")))
        XCTAssertEqual(fields.count, 2, "both new fields are saved as real form fields")
        print("Form field names after save:", fields.map(\.name))
        // Fill by the names the saved file actually uses, then check the values survive a reopen.
        let textName = fields.first { $0.name == "full_name" || $0.name.hasPrefix("text") }?.name ?? ""
        try PDFEngine.updateForm(PDFInput(url: file("f1.pdf")), newFields: [], values: [textName: "سارة أحمد"], to: file("f2.pdf"))
        let filled = try PDFEngine.formFields(PDFInput(url: file("f2.pdf")))
        XCTAssertEqual(filled.first { $0.name == textName }?.value, "سارة أحمد")
    }

    // MARK: Security

    func testProtectAndUnlockRoundTrip() throws {
        let src = file("doc.pdf")
        Fixtures.simplePDF(["Private data"], at: src)
        let locked = file("locked.pdf")
        try PDFEngine.protect(PDFInput(url: src), userPassword: "Waraqa#2026", to: locked)
        XCTAssertTrue(PDFDocument(url: locked)!.isLocked)
        XCTAssertTrue(PDFEngine.isPasswordProtected(locked))

        XCTAssertThrowsError(try PDFEngine.unlock(PDFInput(url: locked, password: "wrong"), to: file("u.pdf"))) {
            XCTAssertEqual($0 as? WaraqaError, .wrongPassword)
        }
        XCTAssertThrowsError(try PDFEngine.unlock(PDFInput(url: locked), to: file("u.pdf"))) {
            XCTAssertEqual($0 as? WaraqaError, .passwordRequired)
        }
        try PDFEngine.unlock(PDFInput(url: locked, password: "Waraqa#2026"), to: file("u.pdf"))
        let open = PDFDocument(url: file("u.pdf"))!
        XCTAssertFalse(open.isEncrypted)
        XCTAssertTrue(open.page(at: 0)!.string!.contains("Private data"))

        XCTAssertThrowsError(try PDFEngine.unlock(PDFInput(url: src), to: file("x.pdf"))) {
            XCTAssertEqual($0 as? WaraqaError, .notEncrypted)
        }
        // Arabic passwords: either they work end to end, or the user gets a clear message.
        do {
            try PDFEngine.protect(PDFInput(url: src), userPassword: "كلمة123", to: file("ar.pdf"))
            try PDFEngine.unlock(PDFInput(url: file("ar.pdf"), password: "كلمة123"), to: file("ar-open.pdf"))
            print("Arabic password: supported")
        } catch {
            XCTAssertEqual(error as? WaraqaError, .passwordUnsupported)
            print("Arabic password: not supported, clear message shown")
        }
        XCTAssertThrowsError(try PDFEngine.protect(PDFInput(url: src), userPassword: String(repeating: "a", count: 33), to: file("long.pdf"))) {
            XCTAssertEqual($0 as? WaraqaError, .passwordUnsupported)
        }
        let fixture = file("fixture-locked.pdf")
        Fixtures.encryptedPDF(["Known password"], password: "pass", at: fixture)
        try PDFEngine.unlock(PDFInput(url: fixture, password: "pass"), to: file("u2.pdf"))
        XCTAssertTrue(Fixtures.text(file("u2.pdf"), page: 0).contains("Known password"))
    }

    func testRedactionRemovesTextForReal() throws {
        let src = file("secret.pdf")
        Fixtures.textPDF([
            [.init(text: "Public introduction")],
            [.init(text: "Customer IBAN SA0380000000608010167519"), .init(text: "Phone 0551234567 is private")],
            [.init(text: "Closing page")],
        ], at: src)
        let report = try PDFEngine.redact(PDFInput(url: src), areas: [:], terms: ["SA0380000000608010167519", "0551234567"], to: file("r.pdf"))
        XCTAssertEqual(report.redactedPages, [1])
        XCTAssertEqual(report.redactedAreas, 2)

        let out = PDFDocument(url: file("r.pdf"))!
        let everything = (0..<out.pageCount).map { out.page(at: $0)?.string ?? "" }.joined()
        XCTAssertFalse(everything.contains("SA0380000000608010167519"))
        XCTAssertFalse(everything.contains("0551234567"))
        XCTAssertTrue(out.page(at: 0)!.string!.contains("Public introduction"), "untouched pages keep their text")
        XCTAssertTrue(out.page(at: 2)!.string!.contains("Closing page"))
        // The raw bytes must not contain the secret either.
        let raw = try Data(contentsOf: file("r.pdf"))
        XCTAssertNil(raw.range(of: Data("0551234567".utf8)))

        // Manual area redaction.
        let manual = try PDFEngine.redact(PDFInput(url: src), areas: [0: [PageRect(x: 50, y: 740, width: 300, height: 30)]], to: file("m.pdf"))
        XCTAssertEqual(manual.redactedPages, [0])
        XCTAssertThrowsError(try PDFEngine.redact(PDFInput(url: src), areas: [:], terms: ["not present anywhere"], to: file("n.pdf"))) {
            XCTAssertEqual($0 as? WaraqaError, .nothingToRedact)
        }
    }

    func testCompare() throws {
        let a = file("v1.pdf"), b = file("v2.pdf")
        Fixtures.simplePDF(["Rent is 5000 per year", "Same page"], at: a)
        Fixtures.simplePDF(["Rent is 6000 per year", "Same page", "New annex"], at: b)
        let result = try PDFEngine.compare(PDFInput(url: a), PDFInput(url: b))
        XCTAssertEqual(result.changedPages.map(\.id), [0, 2])
        let first = result.pages[0].segments
        XCTAssertTrue(first.contains { $0.kind == .deleted && $0.text.contains("5000") })
        XCTAssertTrue(first.contains { $0.kind == .inserted && $0.text.contains("6000") })
    }

    // MARK: OCR

    func testOCRMakesScannedPDFSearchable() throws {
        print("Vision languages:", OCREngine.supportedLanguages())
        let scan = file("scan.pdf")
        Fixtures.scannedPDF(lines: ["INVOICE NUMBER 4471", "Total amount due 980"], at: scan)
        XCTAssertEqual(Fixtures.text(scan, page: 0).trimmingCharacters(in: .whitespacesAndNewlines), "", "fixture has no text layer")
        let out = file("searchable.pdf")
        let results = try OCREngine.makeSearchablePDF(PDFInput(url: scan), languages: ["en"], to: out)
        XCTAssertTrue(results[0].text.uppercased().contains("INVOICE"), results[0].text)
        let layer = Fixtures.text(out, page: 0)
        XCTAssertTrue(layer.uppercased().contains("INVOICE"), "text layer: \(layer)")
        XCTAssertTrue(layer.contains("4471"), layer)
        XCTAssertFalse(PDFDocument(url: out)!.findString("4471", withOptions: []).isEmpty, "searchable")
    }

    func testArabicOCRWhenTheDeviceSupportsIt() throws {
        guard OCREngine.supportsArabic() else {
            XCTAssertThrowsError(try OCREngine.visionLanguages(for: ["ar"])) { XCTAssertEqual($0 as? WaraqaError, .ocrLanguageUnavailable) }
            throw XCTSkip("Vision on this OS has no Arabic; the app falls back to the server (Tesseract).")
        }
        let scan = file("scan-ar.pdf")
        Fixtures.scannedPDF(lines: ["فاتورة ضريبية", "المبلغ الإجمالي"], fontSize: 32, at: scan)
        let results = try OCREngine.recognize(PDFInput(url: scan), languages: ["ar", "en"])
        let text = results[0].text
        print("Arabic OCR:", text)
        XCTAssertTrue(text.contains("فاتورة") || text.contains("الإجمالي") || text.contains("المبلغ"), text)
    }

    // MARK: Validation

    func testValidationCatchesBadOutput() throws {
        let bogus = file("bogus.pdf")
        try Data("%PDF-1.4 not really".utf8).write(to: bogus)
        XCTAssertThrowsError(try PDFEngine.validate(bogus)) { XCTAssertEqual($0 as? WaraqaError, .outputValidationFailed) }
        let real = file("real.pdf")
        Fixtures.simplePDF(["a", "b"], at: real)
        XCTAssertThrowsError(try PDFEngine.validate(real, expectedPages: 3))
        XCTAssertNoThrow(try PDFEngine.validate(real, expectedPages: 2))
    }

    func testCancellationStopsWork() async throws {
        let src = file("big.pdf")
        Fixtures.simplePDF((1...300).map { "Page \($0)" }, at: src)
        let out = file("o.pdf")
        let task = Task.detached {
            try PDFEngine.addPageNumbers(PDFInput(url: src), options: PageNumberOptions(), to: out)
        }
        task.cancel()
        do {
            try await task.value
            // Finishing before the cancel was seen is fine; a partial file is not.
            XCTAssertEqual(Fixtures.pageCount(out), 300)
        } catch {
            XCTAssertEqual(error as? WaraqaError, .cancelled)
        }
    }
}
#endif
