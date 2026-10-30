#if canImport(PDFKit)
import XCTest
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import PDFEngine
import WaraqaCore

final class ProtectTests: XCTestCase {
    var dir: URL!

    override func setUp() { dir = Fixtures.dir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }
    func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func englishSpec(_ style: ProtectionStyle) -> ProtectionSpec {
        var s = ProtectionSpec()
        s.language = .english
        s.recipient = "Hope Real Estate"
        s.purpose = .identity
        s.style = style
        s.includeDate = false
        return s
    }

    func testEveryStyleKeepsTheDocumentAndAddsTheMark() throws {
        let src = file("doc.pdf")
        Fixtures.simplePDF(["Original content page one", "Original content page two"], at: src)
        let before = Fixtures.sha256(src)
        for style in ProtectionStyle.allCases {
            let out = file("p-\(style.rawValue).pdf")
            try PDFEngine.protect(PDFInput(url: src), spec: englishSpec(style), to: out)
            let doc = PDFDocument(url: out)!
            XCTAssertEqual(doc.pageCount, 2, "\(style)")
            let text = doc.page(at: 1)!.string ?? ""
            XCTAssertTrue(text.contains("Original content page two"), "\(style): original text stays")
            XCTAssertTrue(text.contains("Hope Real Estate"), "\(style): mark names the recipient — \(text)")
        }
        XCTAssertEqual(Fixtures.sha256(src), before, "the original is never modified")
    }

    func testArabicMarkIsWritten() throws {
        let src = file("doc.pdf")
        Fixtures.simplePDF(["Body"], at: src)
        var spec = ProtectionSpec()
        spec.recipient = "مكتب الأمل العقاري"
        spec.style = .stamp
        let out = file("ar.pdf")
        try PDFEngine.protect(PDFInput(url: src), spec: spec, to: out)
        let text = PDFDocument(url: out)!.page(at: 0)!.string ?? ""
        XCTAssertTrue(text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0xFE70...0xFEFF).contains($0.value) }, text)
    }

    func testProtectionWithRedactionRemovesTheSecret() throws {
        let src = file("id.pdf")
        Fixtures.textPDF([[.init(text: "Name Sara"), .init(text: "ID 1023456789")]], at: src)
        let areas = try PDFEngine.findAreas(of: ["1023456789"], in: PDFInput(url: src))
        let out = file("protected.pdf")
        try PDFEngine.protect(PDFInput(url: src), spec: englishSpec(.tiled), redactAreas: areas, to: out)
        let text = PDFDocument(url: out)!.page(at: 0)!.string ?? ""
        XCTAssertFalse(text.contains("1023456789"))
        XCTAssertTrue(text.contains("Hope Real Estate"), "the mark is added after redaction")
        XCTAssertNil(try Data(contentsOf: out).range(of: Data("1023456789".utf8)))
    }

    func testImagesToProtectedPDFAndJPEG() throws {
        let photo = file("id.jpg")
        Fixtures.writeImage(Fixtures.photo(width: 1600, height: 1000), type: .jpeg, to: photo)
        let outputs = try PDFEngine.protectImages([.file(photo)], spec: englishSpec(.diagonal), pdfOutput: file("id-protected.pdf"),
                                                  imagesInto: file("imgs"), baseName: "id.jpg")
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(Fixtures.pageCount(outputs[0]), 1)
        XCTAssertTrue(Fixtures.text(outputs[0], page: 0).contains("Hope Real Estate"))
        XCTAssertEqual(outputs[1].pathExtension, "jpg")
        XCTAssertNotNil(CGImageSourceCreateWithURL(outputs[1] as CFURL, nil))
    }

    func testPreviewIsRenderedFromARealProtectedPage() throws {
        let src = file("doc.pdf")
        Fixtures.simplePDF(["A", "B", "C"], at: src)
        let image = try PDFEngine.protectionPreview(PDFInput(url: src), spec: englishSpec(.intense), page: 2, maxPixels: 600)
        XCTAssertEqual(max(image.width, image.height), 600)
        XCTAssertThrowsError(try PDFEngine.protectionPreview(PDFInput(url: src), spec: englishSpec(.small), page: 9))
    }

    func testAnalyzeFindsSensitiveDataAndDocumentType() throws {
        let scan = file("scan.pdf")
        Fixtures.scannedPDF(lines: ["NATIONAL ID CARD", "ID No 1023456789", "Mobile 0551234567", "Welcome"], fontSize: 26, at: scan)
        let analysis = try PDFEngine.analyze(PDFInput(url: scan))
        print("Analysis:", analysis.kind, analysis.areas.map { ($0.kind, $0.text) })
        let kinds = Set(analysis.areas.map(\.kind))
        XCTAssertTrue(kinds.contains(.nationalID), "\(analysis.areas)")
        XCTAssertTrue(kinds.contains(.phone), "\(analysis.areas)")
        XCTAssertEqual(analysis.kind, .nationalID)
        let pageBox = PDFDocument(url: scan)!.page(at: 0)!.bounds(for: .cropBox)
        for area in analysis.areas {
            XCTAssertTrue(pageBox.insetBy(dx: -5, dy: -5).contains(CGRect(x: area.rect.x, y: area.rect.y, width: area.rect.width, height: area.rect.height)))
        }
        // Hiding the suggested areas really removes them from the result.
        var map: [Int: [PageRect]] = [:]
        for a in analysis.areas where a.hidden { map[a.pageIndex, default: []].append(a.rect) }
        let out = file("hidden.pdf")
        try PDFEngine.protect(PDFInput(url: scan), spec: englishSpec(.small), redactAreas: map, to: out)
        let reread = try OCREngine.recognize(PDFInput(url: out), languages: ["en"])
        let text = reread.map(\.text).joined()
        XCTAssertFalse(text.contains("1023456789"), text)
        XCTAssertFalse(text.contains("0551234567"), text)
        XCTAssertTrue(text.uppercased().contains("WELCOME"), "unhidden text stays readable: \(text)")
    }

    func testImageConversionAndMetadataRemoval() throws {
        let src = file("photo.jpg")
        let dest = CGImageDestinationCreateWithURL(src as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 24.7, kCGImagePropertyGPSLongitude: 46.6]
        CGImageDestinationAddImage(dest, Fixtures.photo(width: 800, height: 600), [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let png = try PDFEngine.convertImages([src], to: .png, into: file("png"))
        XCTAssertEqual(png[0].url.pathExtension, "png")
        XCTAssertEqual(png[0].pixelWidth, 600, "orientation applied: portrait")
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(png[0].url as CFURL, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "location is removed")

        let jpg = try PDFEngine.convertImages([png[0].url], to: .jpeg, quality: 0.8, into: file("jpg"))
        XCTAssertEqual(jpg[0].url.pathExtension, "jpg")
        if PDFEngine.canEncode(.heic) {
            let heic = try PDFEngine.convertImages([src], to: .heic, into: file("heic"))
            XCTAssertEqual(heic[0].url.pathExtension, "heic")
        }
    }

    func testShrinkImages() throws {
        let big = file("big.png")
        Fixtures.writeImage(Fixtures.photo(width: 3000, height: 2000), type: .png, to: big)
        let result = try PDFEngine.shrinkImages([big], maxPixels: 1200, quality: 0.7, into: file("small"))
        XCTAssertEqual(max(result[0].pixelWidth, result[0].pixelHeight), 1200)
        XCTAssertLessThan(result[0].newBytes, result[0].originalBytes)
        XCTAssertEqual(result[0].url.pathExtension, "jpg", "opaque PNG becomes a smaller JPEG")
    }
}
#endif
