import XCTest
@testable import WaraqaCore

final class CatalogTests: XCTestCase {
    func testEveryToolIsInTheCatalogExactlyOnce() {
        XCTAssertEqual(ToolCatalog.all.count, ToolID.allCases.count)
        XCTAssertEqual(Set(ToolCatalog.all.map(\.id)), Set(ToolID.allCases))
        for id in ToolID.allCases { XCTAssertEqual(ToolCatalog.info(id).id, id) }
    }

    func testEveryCategoryHasTools() {
        for category in ToolCategory.allCases {
            XCTAssertFalse(ToolCatalog.tools(in: category).isEmpty, "\(category)")
        }
    }

    func testFeaturedToolsMatchTheBrief() {
        XCTAssertEqual(ToolCatalog.featured.count, 18)
        XCTAssertEqual(Set(ToolCatalog.featured).count, 18)
    }

    func testQuickToolsMatchTheSpec() {
        XCTAssertEqual(ToolCatalog.quickTools, [.merge, .compress, .pdfToWord, .imagesToPDF])
    }

    func testTitlesExistInBothLanguages() {
        for tool in ToolCatalog.all {
            XCTAssertFalse(tool.title.ar.isEmpty)
            XCTAssertFalse(tool.title.en.isEmpty)
            XCTAssertFalse(tool.subtitle.ar.isEmpty)
            XCTAssertNotEqual(tool.title.ar, tool.title.en)
        }
    }
}

final class SearchTests: XCTestCase {
    func testArabicNormalizationIgnoresHamzaTaaMarbutaAndDiacritics() {
        XCTAssertEqual(ToolSearch.normalize("إكسل"), ToolSearch.normalize("اكسل"))
        XCTAssertEqual(ToolSearch.normalize("صفحة"), ToolSearch.normalize("صفحه"))
        XCTAssertEqual(ToolSearch.normalize("مُسْتَنَد"), "مستند")
        XCTAssertEqual(ToolSearch.normalize("ترجمــة"), ToolSearch.normalize("ترجمه"))
    }

    func testFindsToolsInBothLanguages() {
        XCTAssertEqual(ToolSearch.search("دمج").first?.id, .merge)
        XCTAssertEqual(ToolSearch.search("merge").first?.id, .merge)
        XCTAssertEqual(ToolSearch.search("ضغط").first?.id, .compress)
        XCTAssertEqual(ToolSearch.search("اكسل").map(\.id).prefix(2).sorted { $0.rawValue < $1.rawValue }, [.excelToPDF, .pdfToExcel])
        XCTAssertTrue(ToolSearch.search("توقيع").map(\.id).contains(.sign))
        XCTAssertTrue(ToolSearch.search("كلمة مرور").map(\.id).contains(.protect))
        XCTAssertTrue(ToolSearch.search("Word").map(\.id).contains(.pdfToWord))
        XCTAssertTrue(ToolSearch.search("ocr").map(\.id).contains(.ocr))
    }

    func testEmptyAndUnknownQueries() {
        XCTAssertTrue(ToolSearch.search("   ").isEmpty)
        XCTAssertTrue(ToolSearch.search("zzzz غغغغ").isEmpty)
    }
}

final class PageSelectionTests: XCTestCase {
    func testParsesRangesSinglesAndOpenEnds() throws {
        let s = try PageSelection.parse("1-3, 5, 8-", pageCount: 10)
        XCTAssertEqual(s.indices, [0, 1, 2, 4, 7, 8, 9])
        XCTAssertEqual(try PageSelection.parse("-2", pageCount: 5).indices, [0, 1])
    }

    func testArabicDigitsAndComma() throws {
        let s = try PageSelection.parse("١-٣، ٥", pageCount: 9)
        XCTAssertEqual(s.indices, [0, 1, 2, 4])
        XCTAssertEqual(try PageSelection.parse("۲", pageCount: 3).indices, [1])
    }

    func testOrderedKeepsTypedOrder() throws {
        XCTAssertEqual(try PageSelection.parse("3,1,2", pageCount: 3).orderedIndices, [2, 0, 1])
    }

    func testErrors() {
        XCTAssertThrowsError(try PageSelection.parse("", pageCount: 3)) { XCTAssertEqual($0 as? PageSelection.ParseError, .empty) }
        XCTAssertThrowsError(try PageSelection.parse("0", pageCount: 3))
        XCTAssertThrowsError(try PageSelection.parse("4", pageCount: 3)) {
            XCTAssertEqual($0 as? PageSelection.ParseError, .outOfRange(page: 4, pageCount: 3))
        }
        XCTAssertThrowsError(try PageSelection.parse("3-1", pageCount: 3)) {
            XCTAssertEqual($0 as? PageSelection.ParseError, .reversedRange("3-1"))
        }
        XCTAssertThrowsError(try PageSelection.parse("a", pageCount: 3))
        XCTAssertThrowsError(try PageSelection.parse("1-2-3", pageCount: 3))
    }

    func testDescribe() {
        XCTAssertEqual(PageSelection.describe([0, 1, 2, 4, 6, 7]), "1-3, 5, 7-8")
        XCTAssertEqual(PageSelection.describe([]), "")
    }

    func testSplitModes() throws {
        XCTAssertEqual(SplitMode.everyPage.groups(pageCount: 3), [[0], [1], [2]])
        XCTAssertEqual(SplitMode.everyN(4).groups(pageCount: 10), [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9]])
        XCTAssertEqual(SplitMode.everyN(0).groups(pageCount: 2), [[0], [1]])
        let ranges = try PageSelection.parse("1-2, 3-5", pageCount: 5)
        XCTAssertEqual(SplitMode.ranges(ranges).groups(pageCount: 5), [[0, 1], [2, 3, 4]])
    }
}

final class FileTests: XCTestCase {
    func testOutputNamesKeepArabicAndNeverReuseTheInputName() {
        XCTAssertEqual(FileNaming.output(for: "عقد الإيجار.pdf", suffix: "مضغوط", extension: "pdf"), "عقد الإيجار - مضغوط.pdf")
        XCTAssertEqual(FileNaming.output(for: "report.final.pdf", suffix: "", extension: "docx"), "report.final.docx")
        XCTAssertEqual(FileNaming.output(for: "a/b:c?.pdf", suffix: "x", extension: "pdf"), "b c - x.pdf")
        XCTAssertEqual(FileNaming.output(for: "???.pdf", suffix: "", extension: "pdf"), "Waraqa.pdf")
        XCTAssertEqual(FileNaming.part(for: "كتاب.pdf", index: 2, extension: "pdf"), "كتاب - 2.pdf")
    }

    func testExtensionsAndUnique() {
        XCTAssertEqual(FileNaming.fileExtension(of: "Photo.JPG"), "jpg")
        XCTAssertEqual(FileNaming.fileExtension(of: "noext"), "")
        XCTAssertEqual(FileNaming.unique("a.pdf", existing: ["a.pdf", "a (2).pdf"]), "a (3).pdf")
        XCTAssertEqual(FileNaming.unique("b.pdf", existing: ["a.pdf"]), "b.pdf")
    }

    func testSanitizeLimitsLengthByCharacters() {
        let long = String(repeating: "ب", count: 300)
        XCTAssertEqual(FileNaming.sanitize(long).count, 120)
    }

    func testByteSize() {
        XCTAssertEqual(ByteSize.format(512), "512 bytes")
        XCTAssertEqual(ByteSize.format(1_400_000), "1.4 MB")
        XCTAssertEqual(ByteSize.format(25_000_000), "25 MB")
        XCTAssertEqual(ByteSize.format(2_000, language: .arabic), "2.0 ك.ب")
    }

    func testCompressionReport() {
        let r = CompressionReport(originalBytes: 10_000, compressedBytes: 2_500)
        XCTAssertTrue(r.isSmaller)
        XCTAssertEqual(r.savedPercent, 75)
        XCTAssertEqual(r.savedBytes, 7_500)
        let worse = CompressionReport(originalBytes: 100, compressedBytes: 150)
        XCTAssertFalse(worse.isSmaller)
        XCTAssertEqual(worse.savedPercent, 0)
        XCTAssertEqual(worse.savedBytes, 0)
    }

    func testSuggestions() {
        XCTAssertEqual(FileSuggestion.tools(forFileNames: ["a.jpg", "b.HEIC"]), [.imagesToPDF])
        XCTAssertEqual(FileSuggestion.tools(forFileNames: ["cv.docx"]), [.wordToPDF])
        XCTAssertEqual(FileSuggestion.tools(forFileNames: ["deck.pptx"]), [.powerPointToPDF])
        XCTAssertEqual(FileSuggestion.tools(forFileNames: ["t.xlsx"]), [.excelToPDF])
        XCTAssertEqual(FileSuggestion.tools(forFileNames: ["a.pdf", "b.pdf"]).first, .merge)
        XCTAssertEqual(FileSuggestion.tools(forFileNames: ["a.pdf"]).first, .compress)
        XCTAssertEqual(FileSuggestion.tools(forFileNames: ["a.pdf", "b.jpg"]), [])
    }

    func testDeviceLanguage() {
        XCTAssertEqual(AppLanguage.deviceDefault(preferred: ["en-US"]), .english)
        XCTAssertEqual(AppLanguage.deviceDefault(preferred: ["ar-SA"]), .arabic)
        XCTAssertEqual(AppLanguage.deviceDefault(preferred: ["fr-FR"]), .arabic)
        XCTAssertEqual(AppLanguage.deviceDefault(preferred: []), .arabic)
    }
}

final class DiffTests: XCTestCase {
    func testIdentical() {
        let s = TextDiff.diff(old: "a b c", new: "a b c")
        XCTAssertEqual(s, [TextDiff.Segment(kind: .equal, words: ["a", "b", "c"])])
        XCTAssertTrue(TextDiff.summary(s).isIdentical)
        XCTAssertEqual(TextDiff.summary(s).similarityPercent, 100)
    }

    func testInsertionDeletionAndReplacement() {
        let s = TextDiff.diff(old: "الإيجار السنوي 5000 ريال", new: "الإيجار السنوي 6000 ريال تدفع مقدماً")
        XCTAssertEqual(s.map(\.kind), [.equal, .deleted, .inserted, .equal, .inserted])
        XCTAssertEqual(s[1].text, "5000")
        XCTAssertEqual(s[2].text, "6000")
        XCTAssertEqual(s[4].text, "تدفع مقدماً")
        let summary = TextDiff.summary(s)
        XCTAssertEqual(summary.insertedWords, 3)
        XCTAssertEqual(summary.deletedWords, 1)
        XCTAssertEqual(summary.unchangedWords, 3)
    }

    func testDiffReconstructsBothSides() {
        let old = TextDiff.words("the quick brown fox jumps over the lazy dog again and again")
        let new = TextDiff.words("a quick red fox jumped over the dog again and again and again")
        let segments = TextDiff.diff(old, new)
        let rebuiltOld = segments.filter { $0.kind != .inserted }.flatMap(\.words)
        let rebuiltNew = segments.filter { $0.kind != .deleted }.flatMap(\.words)
        XCTAssertEqual(rebuiltOld, old)
        XCTAssertEqual(rebuiltNew, new)
    }

    func testRandomizedReconstruction() {
        var rng = SeededRandom(seed: 42)
        let vocab = ["أ", "ب", "ت", "ث", "ج", "x", "y"]
        for _ in 0..<200 {
            let a = (0..<Int.random(in: 0...30, using: &rng)).map { _ in vocab.randomElement(using: &rng)! }
            let b = (0..<Int.random(in: 0...30, using: &rng)).map { _ in vocab.randomElement(using: &rng)! }
            let s = TextDiff.diff(a, b)
            XCTAssertEqual(s.filter { $0.kind != .inserted }.flatMap(\.words), a)
            XCTAssertEqual(s.filter { $0.kind != .deleted }.flatMap(\.words), b)
        }
    }

    func testEditLimitFallsBackToFullReplace() {
        let s = TextDiff.diff(["a", "b"], ["c", "d"], maxEdits: 1)
        XCTAssertEqual(s.map(\.kind), [.deleted, .inserted])
    }

    func testDocumentComparisonByPage() {
        let c = DocumentComparison(oldPages: ["one two", "three"], newPages: ["one two", "three four", "five"])
        XCTAssertEqual(c.changedPages.map(\.id), [1, 2])
        XCTAssertEqual(c.total.insertedWords, 2)
        XCTAssertEqual(c.oldPageCount, 2)
        XCTAssertEqual(c.newPageCount, 3)
    }
}

final class MarkdownTests: XCTestCase {
    func testHeadingsParagraphsListsAndPages() {
        let lines: [MarkdownBuilder.Line] = [
            .init(text: "تقرير الربع الأول", fontSize: 24, isBold: true),
            .init(text: "هذا نص تمهيدي طويل يشرح محتوى التقرير", fontSize: 12),
            .init(text: "ويكمل في السطر الثاني.", fontSize: 12),
            .init(text: "النتائج", fontSize: 16, isBold: true),
            .init(text: "• زيادة المبيعات", fontSize: 12),
            .init(text: "١. خفض التكاليف", fontSize: 12),
            .init(text: "نص بعد القائمة *مهم*", fontSize: 12),
            .init(text: "الصفحة الثانية", fontSize: 12, pageIndex: 1),
        ]
        let md = MarkdownBuilder.build(lines)
        XCTAssertEqual(md, """
        # تقرير الربع الأول

        هذا نص تمهيدي طويل يشرح محتوى التقرير ويكمل في السطر الثاني.

        ## النتائج

        - زيادة المبيعات
        1. خفض التكاليف

        نص بعد القائمة \\*مهم\\*

        ---

        الصفحة الثانية

        """)
    }

    func testEscapesLeadingHash() {
        XCTAssertEqual(MarkdownBuilder.escape("#1 item"), "\\#1 item")
    }
}

final class EditOptionTests: XCTestCase {
    let page = PageRect(x: 0, y: 0, width: 600, height: 800)

    func testPlacement() {
        XCTAssertEqual(PagePosition.bottomCenter.place(width: 100, height: 20, in: page, margin: 30),
                       PageRect(x: 250, y: 30, width: 100, height: 20))
        XCTAssertEqual(PagePosition.topRight.place(width: 100, height: 20, in: page, margin: 30),
                       PageRect(x: 470, y: 750, width: 100, height: 20))
        XCTAssertEqual(PagePosition.center.place(width: 100, height: 20, in: page, margin: 30),
                       PageRect(x: 250, y: 390, width: 100, height: 20))
    }

    func testPageNumberLabels() {
        var o = PageNumberOptions()
        XCTAssertEqual(o.label(index: 0, count: 10), "1")
        o.style = .numberOfTotal
        XCTAssertEqual(o.label(index: 2, count: 10), "3 / 10")
        o.style = .wordy
        o.arabicDigits = true
        XCTAssertEqual(o.label(index: 2, count: 10), "صفحة ٣ من ١٠")
        o.skipFirstPage = true
        o.arabicDigits = false
        XCTAssertNil(o.label(index: 0, count: 10))
        XCTAssertEqual(o.label(index: 1, count: 10), "صفحة 1 من 9")
        o.language = .english
        o.startAt = 5
        XCTAssertEqual(o.label(index: 1, count: 3), "Page 5 of 6")
    }

    func testCropMargins() {
        let box = PageRect(x: 0, y: 0, width: 600, height: 800)
        XCTAssertEqual(CropMargins(top: 10, bottom: 20, left: 30, right: 40).apply(to: box),
                       PageRect(x: 30, y: 20, width: 530, height: 770))
        XCTAssertNil(CropMargins(left: 300, right: 290).apply(to: box))
        XCTAssertNil(CropMargins(top: -1).apply(to: box))
    }

    func testImageLayout() {
        let fit = ImagePageLayout.layout(imageWidth: 1000, imageHeight: 500, pageSize: .fit, margin: 0)
        XCTAssertEqual(fit.page.width, 1000)
        let a4 = ImagePageLayout.layout(imageWidth: 1000, imageHeight: 500, pageSize: .a4, margin: 20)
        XCTAssertEqual(a4.page.width, 841.89, accuracy: 0.01) // landscape image → landscape page
        XCTAssertEqual(a4.image.width, 841.89 - 40, accuracy: 0.01)
        XCTAssertEqual(a4.image.midX, a4.page.midX, accuracy: 0.01)
        XCTAssertEqual(a4.image.midY, a4.page.midY, accuracy: 0.01)
    }
}

final class AIModelTests: XCTestCase {
    let pages = [AIPage(page: 1, text: "يبلغ الإيجار السنوي خمسة آلاف ريال، ويُدفع مقدماً."),
                 AIPage(page: 2, text: "The tenant must give 60 days notice.")]

    func testQuoteVerificationIsTolerantButStrict() {
        XCTAssertTrue(QuoteVerifier.verify(Citation(page: 1, quote: "الايجار السنوي خمسه الاف ريال", verified: false), in: pages))
        XCTAssertTrue(QuoteVerifier.verify(Citation(page: 2, quote: "give 60 days  notice", verified: false), in: pages))
        // Wrong page, invented text and too-short quotes are rejected.
        XCTAssertFalse(QuoteVerifier.verify(Citation(page: 2, quote: "الإيجار السنوي", verified: false), in: pages))
        XCTAssertFalse(QuoteVerifier.verify(Citation(page: 1, quote: "ستة آلاف ريال", verified: false), in: pages))
        XCTAssertFalse(QuoteVerifier.verify(Citation(page: 1, quote: "ي", verified: false), in: pages))
    }

    func testBudgetKeepsPageBoundaries() {
        let many = (1...10).map { AIPage(page: $0, text: String(repeating: "a", count: 1000)) }
        let (kept, truncated) = AIPage.budgeted(many, limit: 3500)
        XCTAssertTrue(truncated)
        XCTAssertEqual(kept.map(\.page), [1, 2, 3, 4])
        XCTAssertEqual(kept.last?.text.count, 500)
        XCTAssertFalse(AIPage.budgeted(many).truncated)
        XCTAssertEqual(AIPage.budgeted([AIPage(page: 1, text: "  ")]).pages, [])
    }
}

/// Deterministic RNG for reproducible randomized tests.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
