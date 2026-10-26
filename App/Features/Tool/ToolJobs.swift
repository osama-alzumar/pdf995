import Foundation
import PDFEngine
import WaraqaCore

/// Everything a tool can be told. Each tool screen shows only the options its tool uses.
struct ToolOptions: Sendable {
    var pageText = ""                           // "1-3, 5" for extract/remove/split/rotate
    var selectedPages: Set<Int> = []            // picked in the page grid (0-based)
    var splitMode: SplitChoice = .everyPage
    var splitEvery = 2
    var compression: CompressionLevel = .recommended
    var rotation = 90
    var rotateAll = true
    var pageNumbers = PageNumberOptions()
    var watermark = WatermarkOptions()
    var crop = CropMargins(top: 20, bottom: 20, left: 20, right: 20)
    var imageFormat: ImageExportFormat = .jpeg
    var imageDPI: Double = 150
    var pageSize: PageSizeOption = .a4
    var imageMargin: Double = 0
    var newPassword = ""
    var confirmPassword = ""
    var ocrArabic = true
    var ocrEnglish = true
    var useServer = false
    var redactTerms = ""
    var redactAreas: [Int: [PageRect]] = [:]
    var summaryLength: SummaryLength = .short
    var targetLanguage = "en"
    var organize: [PageEdit] = []
    var editItems: [EditItem] = []
    var webURL = ""
    var makeSearchable = true

    enum SplitChoice: String, CaseIterable, Identifiable {
        case everyPage, everyN, ranges
        var id: String { rawValue }
    }

    var ocrLanguages: [String] {
        var langs: [String] = []
        if ocrArabic { langs.append("ar") }
        if ocrEnglish { langs.append("en") }
        return langs.isEmpty ? ["ar", "en"] : langs
    }
}

/// Extra information shown on the result screen next to the files.
enum ToolExtra: Sendable {
    case compression(CompressionReport)
    case text(String, title: LocalizedText)
    case comparison(DocumentComparison)
    case summary(SummarizeResponse)
    case translation([AIPage])
    case redaction(PDFEngine.RedactionReport)
    case info(LocalizedText)
}

struct ToolOutput: Sendable {
    var files: [URL]
    var extra: ToolExtra?
}

/// The single entry point that runs any tool. Heavy work runs on a background thread; the
/// caller's Task can be cancelled at any time, and the engine stops at the next page.
enum ToolJobs {
    struct Context {
        let outputFolder: URL
        let language: AppLanguage
        let progress: ProgressHandler
    }

    static func run(_ tool: ToolID, files: [PickedFile], options: ToolOptions, context: Context) async throws -> ToolOutput {
        let info = ToolCatalog.info(tool)
        if info.execution == .server || (info.execution == .onDeviceWithServerFallback && options.useServer) {
            return try await runOnServer(tool, files: files, options: options, context: context)
        }
        if tool == .htmlToPDF {
            return try await runHTML(files: files, options: options, context: context)
        }
        return try await background {
            try runOnDevice(tool, files: files, options: options, context: context)
        }
    }

    /// Runs synchronous engine work off the main thread and forwards cancellation to it.
    static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - On device

    static func runOnDevice(_ tool: ToolID, files: [PickedFile], options: ToolOptions, context: Context) throws -> ToolOutput {
        guard let first = files.first else { throw WaraqaError.noPagesSelected }
        let input = PDFInput(url: first.url, password: first.password)
        let out = context.outputFolder
        let progress = context.progress
        func named(_ suffix: (String, String), ext: String = "pdf") -> URL {
            out.appendingPathComponent(FileNaming.output(for: first.name, suffix: context.language.t(suffix.0, suffix.1), extension: ext))
        }
        func pages(_ count: Int) throws -> [Int] {
            if !options.selectedPages.isEmpty { return options.selectedPages.sorted() }
            do {
                return try PageSelection.parse(options.pageText, pageCount: count).indices
            } catch let error as PageSelection.ParseError {
                throw WaraqaError.invalidPageSelection(describe(error, context.language))
            }
        }

        switch tool {
        case .merge:
            guard files.count >= 2 else { throw WaraqaError.needsTwoFiles }
            let url = out.appendingPathComponent(FileNaming.output(for: first.name, suffix: context.language.t("مدمج", "merged"), extension: "pdf"))
            try PDFEngine.merge(files.map { PDFInput(url: $0.url, password: $0.password) }, to: url, progress: progress)
            return ToolOutput(files: [url])

        case .split:
            let count = try PDFEngine.pageCount(first.url, password: first.password)
            let mode: SplitMode
            switch options.splitMode {
            case .everyPage: mode = .everyPage
            case .everyN: mode = .everyN(max(1, options.splitEvery))
            case .ranges:
                do { mode = .ranges(try PageSelection.parse(options.pageText, pageCount: count)) } catch let e as PageSelection.ParseError {
                    throw WaraqaError.invalidPageSelection(describe(e, context.language))
                }
            }
            let parts = try PDFEngine.split(input, mode: mode, into: out, baseName: first.name, progress: progress)
            return ToolOutput(files: parts)

        case .removePages:
            let count = try PDFEngine.pageCount(first.url, password: first.password)
            let url = named(("بعد الحذف", "pages removed"))
            try PDFEngine.remove(input, pages: try pages(count), to: url)
            return ToolOutput(files: [url])

        case .extractPages:
            let count = try PDFEngine.pageCount(first.url, password: first.password)
            let url = named(("صفحات مستخرجة", "extracted"))
            let selection: [Int]
            if options.selectedPages.isEmpty {
                do { selection = try PageSelection.parse(options.pageText, pageCount: count).orderedIndices } catch let e as PageSelection.ParseError {
                    throw WaraqaError.invalidPageSelection(describe(e, context.language))
                }
            } else {
                selection = options.selectedPages.sorted()
            }
            try PDFEngine.extract(input, pages: selection, to: url)
            return ToolOutput(files: [url])

        case .organize:
            let url = named(("مرتب", "organized"))
            try PDFEngine.organize(input, pages: options.organize, to: url)
            return ToolOutput(files: [url])

        case .rotate:
            let count = try PDFEngine.pageCount(first.url, password: first.password)
            let url = named(("مدوّر", "rotated"))
            try PDFEngine.rotate(input, degrees: options.rotation, pages: options.rotateAll ? nil : try pages(count), to: url)
            return ToolOutput(files: [url])

        case .imagesToPDF, .scanToPDF:
            let url = out.appendingPathComponent(FileNaming.output(
                for: tool == .scanToPDF ? context.language.t("مستند ممسوح", "Scan") : first.name,
                suffix: "", extension: "pdf"))
            try PDFEngine.imagesToPDF(files.map { .file($0.url) }, pageSize: options.pageSize, margin: options.imageMargin,
                                      to: url, progress: { p in progress(tool == .scanToPDF && options.makeSearchable ? p * 0.3 : p) })
            if tool == .scanToPDF && options.makeSearchable {
                // Searchable scan: add the recognized text as an invisible layer. If this device
                // can't read the language, keep the plain scan rather than failing.
                let searchable = out.appendingPathComponent(UUID().uuidString + ".pdf")
                if let results = try? OCREngine.makeSearchablePDF(PDFInput(url: url), languages: options.ocrLanguages, to: searchable,
                                                                  progress: { p in progress(0.3 + p * 0.7) }) {
                    try FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: searchable, to: url)
                    let text = results.map(\.text).joined(separator: "\n\n")
                    return ToolOutput(files: [url], extra: text.isEmpty ? nil : .text(text, title: LocalizedText("النص المستخرج", "Recognized text")))
                }
            }
            return ToolOutput(files: [url])

        case .compress:
            let url = named(("مضغوط", "compressed"))
            let report = try PDFEngine.compress(input, level: options.compression, to: url, progress: progress)
            return ToolOutput(files: [url], extra: .compression(report))

        case .repair:
            let url = named(("مُصلح", "repaired"))
            let pages = try PDFEngine.repair(input, to: url)
            return ToolOutput(files: [url], extra: .info(LocalizedText("تم استرجاع \(pages) صفحة.", "Recovered \(pages) page(s).")))

        case .ocr:
            let url = named(("قابل للبحث", "searchable"))
            let results = try OCREngine.makeSearchablePDF(input, languages: options.ocrLanguages, to: url, progress: progress)
            let text = results.map { r in
                context.language.t("— صفحة \(r.pageIndex + 1) —", "— Page \(r.pageIndex + 1) —") + "\n" + r.text
            }.joined(separator: "\n\n")
            return ToolOutput(files: [url], extra: .text(text, title: LocalizedText("النص المستخرج", "Recognized text")))

        case .pdfToImages:
            let images = try PDFEngine.pdfToImages(input, format: options.imageFormat, dpi: options.imageDPI,
                                                   pages: options.selectedPages.isEmpty ? nil : options.selectedPages.sorted(),
                                                   into: out, baseName: first.name, progress: progress)
            return ToolOutput(files: images)

        case .pdfToMarkdown:
            let markdown = try PDFEngine.markdown(input)
            let url = out.appendingPathComponent(FileNaming.output(for: first.name, suffix: "", extension: "md"))
            try Data(markdown.utf8).write(to: url, options: .atomic)
            return ToolOutput(files: [url], extra: .text(markdown, title: LocalizedText("Markdown", "Markdown")))

        case .pageNumbers:
            let url = named(("مرقم", "numbered"))
            var numbering = options.pageNumbers
            numbering.language = context.language
            try PDFEngine.addPageNumbers(input, options: numbering, to: url, progress: progress)
            return ToolOutput(files: [url])

        case .watermark:
            let url = named(("بعلامة مائية", "watermarked"))
            try PDFEngine.addWatermark(input, options: options.watermark, to: url, progress: progress)
            return ToolOutput(files: [url])

        case .crop:
            let url = named(("مقصوص", "cropped"))
            try PDFEngine.crop(input, margins: options.crop, to: url)
            return ToolOutput(files: [url])

        case .edit, .sign:
            guard !options.editItems.isEmpty else { throw WaraqaError.missingOptions }
            let url = named(tool == .sign ? ("موقّع", "signed") : ("معدّل", "edited"))
            try PDFEngine.applyEdits(input, items: options.editItems, to: url, progress: progress)
            return ToolOutput(files: [url])

        case .protect:
            guard !options.newPassword.isEmpty, options.newPassword == options.confirmPassword else { throw WaraqaError.missingOptions }
            let url = named(("محمي", "protected"))
            try PDFEngine.protect(input, userPassword: options.newPassword, to: url)
            return ToolOutput(files: [url], extra: .info(LocalizedText(
                "احتفظ بكلمة المرور في مكان آمن: لا يمكن استرجاعها إن نُسيت.",
                "Keep the password somewhere safe: it can't be recovered if forgotten.")))

        case .unlock:
            let url = named(("بدون حماية", "unlocked"))
            try PDFEngine.unlock(input, to: url)
            return ToolOutput(files: [url])

        case .redact:
            let terms = options.redactTerms.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == "،" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let url = named(("منقح", "redacted"))
            let report = try PDFEngine.redact(input, areas: options.redactAreas, terms: terms, to: url, progress: progress)
            return ToolOutput(files: [url], extra: .redaction(report))

        case .compare:
            guard files.count == 2 else { throw WaraqaError.needsTwoFiles }
            let result = try PDFEngine.compare(input, PDFInput(url: files[1].url, password: files[1].password))
            return ToolOutput(files: [], extra: .comparison(result))

        case .forms:
            // The form is filled in place in the viewer; the screen hands over the saved copy.
            return ToolOutput(files: files.map(\.url))

        default:
            throw WaraqaError.serverNotConfigured
        }
    }

    // MARK: - Server

    static func runOnServer(_ tool: ToolID, files: [PickedFile], options: ToolOptions, context: Context) async throws -> ToolOutput {
        guard let first = files.first else { throw WaraqaError.noPagesSelected }
        let server = await ServerService.shared

        switch tool {
        case .summarize, .intelligence, .translate:
            let texts = try await background { try PDFEngine.pageTexts(PDFInput(url: first.url, password: first.password)) }
            let pages = texts.enumerated().map { AIPage(page: $0.offset + 1, text: $0.element) }
            let (budgeted, truncated) = AIPage.budgeted(pages)
            guard !budgeted.isEmpty else { throw WaraqaError.noTextFound }
            context.progress(0.2)
            if tool == .translate {
                let response = try await server.withApprovedUpload { client in
                    try await client.postJSON("v1/ai/translate", body: TranslateRequest(pages: budgeted, target: options.targetLanguage),
                                              as: TranslateResponse.self)
                }
                let url = context.outputFolder.appendingPathComponent(
                    FileNaming.output(for: first.name, suffix: options.targetLanguage.uppercased(), extension: "pdf"))
                let rtl = ["ar", "ur"].contains(options.targetLanguage)
                try await background {
                    try PDFEngine.textToPDF(pages: response.pages.map(\.text), title: FileNaming.stem(of: first.name),
                                            rightToLeft: rtl, to: url)
                }
                return ToolOutput(files: [url], extra: .translation(response.pages))
            }
            // Summarize and "ask" share the summary call; questions are asked from the result screen.
            var response = try await server.withApprovedUpload { client in
                try await client.postJSON("v1/ai/summarize", body: SummarizeRequest(pages: budgeted, length: options.summaryLength,
                                                                                    language: context.language.rawValue),
                                          as: SummarizeResponse.self)
            }
            // Double-check on the device too: only quotes found in the file are shown.
            response.points = response.points.compactMap { point in
                var p = point
                p.citations = QuoteVerifier.check(point.citations, in: budgeted).filter(\.verified)
                return p.citations.isEmpty ? nil : p
            }
            _ = truncated
            return ToolOutput(files: [], extra: .summary(response))

        default:
            let mime = UTTypeName.mime(for: first.name)
            var fields: [String: String] = [:]
            if let password = first.password { fields["password"] = password }
            if tool == .ocr { fields["languages"] = options.ocrLanguages.joined(separator: ",") }
            if tool == .compress { fields["level"] = options.compression.rawValue }
            let part = MultipartBody.FilePart(fileName: first.name, contentType: mime, url: first.url)
            let result = try await server.withApprovedUpload { client in
                try await client.run(tool: tool, files: [part], options: fields, progress: { p in context.progress(p * 0.5) })
            }
            let target = context.outputFolder.appendingPathComponent(result.fileName)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: result.fileURL, to: target)
            if target.pathExtension.lowercased() == "pdf" {
                try PDFEngine.validate(target)
            }
            context.progress(1)
            var extra: ToolExtra?
            if let tables = result.headers["x-waraqa-tables"] {
                extra = .info(LocalizedText("تم استخراج \(tables) جدول.", "Extracted \(tables) table(s)."))
            }
            if tool == .pdfToPDFA, let level = result.headers["x-waraqa-pdfa"] {
                let verdict = result.headers["x-waraqa-verapdf"] == "pass"
                    ? LocalizedText("PDF/A-\(level.uppercased()) — اجتاز فحص veraPDF.", "PDF/A-\(level.uppercased()) — passed veraPDF validation.")
                    : LocalizedText("PDF/A-\(level.uppercased())", "PDF/A-\(level.uppercased())")
                extra = .info(verdict)
            }
            if tool == .pdfToWord || tool == .pdfToPowerPoint || tool == .pdfToExcel {
                extra = extra ?? .info(LocalizedText(
                    "التحويل يحافظ على النصوص والجداول والصور قدر الإمكان، وقد يختلف التخطيط في المستندات المعقدة. راجع الملف قبل اعتماده.",
                    "Text, tables and images are kept as far as possible; complex layouts may differ. Review the file before relying on it."))
            }
            return ToolOutput(files: [target], extra: extra)
        }
    }

    // MARK: - Web page

    @MainActor
    static func runHTML(files: [PickedFile], options: ToolOptions, context: Context) async throws -> ToolOutput {
        let source: HTMLToPDF.Source
        let name: String
        if let file = files.first {
            source = .file(file.url)
            name = file.name
        } else {
            var text = options.webURL.trimmingCharacters(in: .whitespaces)
            if !text.contains("://") { text = "https://" + text }
            guard let url = URL(string: text), let host = url.host, !host.isEmpty, ["http", "https"].contains(url.scheme ?? "") else {
                throw WaraqaError.missingOptions
            }
            source = .web(url)
            name = host
        }
        let target = context.outputFolder.appendingPathComponent(FileNaming.output(for: name, suffix: "", extension: "pdf"))
        try await HTMLToPDF.render(source, to: target)
        try PDFEngine.validate(target)
        return ToolOutput(files: [target], extra: .info(LocalizedText(
            "يتم حفظ الصفحة كما تظهر للطباعة؛ قد تختلف بعض العناصر التفاعلية.",
            "The page is saved as it prints; some interactive elements may differ.")))
    }

    static func describe(_ error: PageSelection.ParseError, _ lang: AppLanguage) -> String {
        switch error {
        case .empty: lang.t("لم تكتب أي رقم", "nothing entered")
        case .invalidToken(let t): "«\(t)»"
        case .outOfRange(let page, let count): lang.t("الصفحة \(page) غير موجودة (عدد الصفحات \(count))", "page \(page) doesn't exist (\(count) pages)")
        case .reversedRange(let t): lang.t("النطاق «\(t)» معكوس", "range “\(t)” is reversed")
        }
    }
}

enum UTTypeName {
    static func mime(for name: String) -> String {
        switch FileNaming.fileExtension(of: name) {
        case "pdf": "application/pdf"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "doc": "application/msword"
        case "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "ppt": "application/vnd.ms-powerpoint"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "xls": "application/vnd.ms-excel"
        case "csv": "text/csv"
        case "odt": "application/vnd.oasis.opendocument.text"
        case "rtf": "application/rtf"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }
}
