#if canImport(PDFKit)
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import WaraqaCore

extension PDFEngine {
    // MARK: - Images → PDF

    public enum ImageSource: Sendable {
        case file(URL)
        case data(Data)
    }

    /// One page per image, in order. JPEG/HEIC photos are stored as JPEG; PNG (screenshots,
    /// images with transparency) stay lossless.
    public static func imagesToPDF(_ images: [ImageSource], pageSize: PageSizeOption = .fit, margin: Double = 0,
                                   to output: URL, progress: ProgressHandler? = nil) throws {
        guard !images.isEmpty else { throw WaraqaError.noPagesSelected }
        guard images.count <= Limits.maxImages else { throw WaraqaError.fileTooLarge(limitBytes: 0) }
        try? FileManager.default.removeItem(at: output)
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw WaraqaError.writeFailed }
        for (i, source) in images.enumerated() {
            try checkCancelled()
            try autoreleasepool {
                let (image, isPNG) = try load(source)
                // Photos are placed at 72 dpi-equivalent of ~150 dpi so "fit" pages have a sane size.
                let pxToPt = 72.0 / 150.0
                let w = Double(image.width) * (pageSize == .fit ? pxToPt : 1)
                let h = Double(image.height) * (pageSize == .fit ? pxToPt : 1)
                let layout = ImagePageLayout.layout(imageWidth: w, imageHeight: h, pageSize: pageSize, margin: margin)
                var box = cgRect(layout.page)
                context.beginPage(mediaBox: &box)
                if pageSize != .fit || hasAlpha(image) {
                    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    context.fill(box)
                }
                let drawn = (isPNG || hasAlpha(image)) ? image : try jpegImage(image, quality: 0.85)
                context.interpolationQuality = .high
                context.draw(drawn, in: cgRect(layout.image))
                context.endPage()
            }
            progress?(Double(i + 1) / Double(images.count))
        }
        context.closePDF()
        try validate(output, expectedPages: images.count)
    }

    private static func load(_ source: ImageSource) throws -> (CGImage, Bool) {
        switch source {
        case .file(let url):
            let isPNG = UTType(filenameExtension: url.pathExtension)?.conforms(to: .png) ?? false
            return (try loadImage(url), isPNG)
        case .data(let data):
            let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            return (try loadImage(data: data), isPNG)
        }
    }

    // MARK: - PDF → images

    /// Renders pages to JPEG/PNG files named "<base> - <n>.<ext>". `pages` nil = all.
    public static func pdfToImages(_ input: PDFInput, format: ImageExportFormat, dpi: CGFloat = 150, pages: [Int]? = nil,
                                   into directory: URL, baseName: String, progress: ProgressHandler? = nil) throws -> [URL] {
        let work = try Workspace()
        let doc = try prepareForDrawing(input.url, password: input.password, work: work)
        let indices = pages ?? Array(0..<doc.pageCount)
        guard !indices.isEmpty else { throw WaraqaError.noPagesSelected }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for (n, index) in indices.enumerated() {
            try checkCancelled()
            try autoreleasepool {
                guard let page = doc.page(at: index)?.pageRef else { throw WaraqaError.writeFailed }
                let image = try render(page, dpi: dpi)
                let data = try encode(image, as: format == .jpeg ? .jpeg : .png, quality: 0.9)
                let url = directory.appendingPathComponent(FileNaming.part(for: baseName, index: index + 1, extension: format.fileExtension))
                try data.write(to: url, options: .atomic)
                guard CGImageSourceCreateWithURL(url as CFURL, nil).flatMap({ CGImageSourceGetCount($0) }) == 1 else {
                    throw WaraqaError.outputValidationFailed
                }
                outputs.append(url)
            }
            progress?(Double(n + 1) / Double(indices.count))
        }
        return outputs
    }

    /// A small preview image of one page, for thumbnails.
    public static func thumbnail(_ url: URL, page index: Int, maxPixels: CGFloat, password: String? = nil) -> CGImage? {
        guard let doc = try? open(url, password: password), let page = doc.page(at: index)?.pageRef else { return nil }
        let size = displaySize(of: page)
        let dpi = 72 * maxPixels / max(size.width, size.height, 1)
        return try? render(page, dpi: dpi)
    }

    // MARK: - Text

    /// Plain text of every page (empty strings for pages without a text layer).
    public static func pageTexts(_ input: PDFInput) throws -> [String] {
        let doc = try open(input.url, password: input.password)
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }

    /// Text lines with font size and weight, for Markdown structure detection.
    public static func textLines(_ input: PDFInput) throws -> [MarkdownBuilder.Line] {
        let doc = try open(input.url, password: input.password)
        var lines: [MarkdownBuilder.Line] = []
        for p in 0..<doc.pageCount {
            try checkCancelled()
            guard let attributed = doc.page(at: p)?.attributedString else { continue }
            let string = attributed.string as NSString
            var location = 0
            while location < string.length {
                let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
                let text = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
                var maxSize: CGFloat = 0
                var bold = false
                attributed.enumerateAttribute(.font, in: lineRange) { value, _, _ in
                    guard let value else { return }
                    let font = value as! CTFont // UIFont/NSFont are toll-free bridged with CTFont
                    let size = CTFontGetSize(font)
                    if size >= maxSize {
                        maxSize = size
                        let traits = CTFontGetSymbolicTraits(font)
                        let name = (CTFontCopyPostScriptName(font) as String).lowercased()
                        bold = traits.contains(.traitBold) || name.contains("bold") || name.contains("black")
                    }
                }
                lines.append(MarkdownBuilder.Line(text: text, fontSize: Double(maxSize > 0 ? maxSize : 12), isBold: bold, pageIndex: p))
                location = NSMaxRange(lineRange)
            }
        }
        return lines
    }

    /// PDF → Markdown. Throws `noTextFound` for scanned files without a text layer.
    public static func markdown(_ input: PDFInput) throws -> String {
        let lines = try textLines(input)
        guard lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw WaraqaError.noTextFound
        }
        return MarkdownBuilder.build(lines)
    }

    /// Lays out text into A4 pages (used for translations). Arabic paragraphs are right-to-left.
    public static func textToPDF(pages texts: [String], title: String? = nil, rightToLeft: Bool,
                                 to output: URL) throws {
        let pageRect = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let frameRect = pageRect.insetBy(dx: 56, dy: 64)
        let body = NSMutableAttributedString()

        let paragraphStyle: CTParagraphStyle = {
            var alignment: CTTextAlignment = .natural
            var direction: CTWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
            var spacing: CGFloat = 6
            return withUnsafePointer(to: &alignment) { a in
                withUnsafePointer(to: &direction) { d in
                    withUnsafePointer(to: &spacing) { s in
                        let settings = [
                            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a),
                            CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size, value: d),
                            CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: s),
                        ]
                        return CTParagraphStyleCreate(settings, settings.count)
                    }
                }
            }
        }()
        func attrs(_ size: CGFloat, bold: Bool = false, gray: Bool = false) -> [NSAttributedString.Key: Any] {
            [
                NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): gray
                    ? CGColor(gray: 0.45, alpha: 1) : CGColor(gray: 0.08, alpha: 1),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
            ]
        }
        if let title, !title.isEmpty {
            body.append(NSAttributedString(string: title + "\n", attributes: attrs(18, bold: true)))
        }
        for (i, text) in texts.enumerated() where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if texts.count > 1 {
                let label = rightToLeft ? "— صفحة \(i + 1) —" : "— Page \(i + 1) —"
                body.append(NSAttributedString(string: label + "\n", attributes: attrs(10, gray: true)))
            }
            body.append(NSAttributedString(string: text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n", attributes: attrs(12)))
        }
        guard body.length > 0 else { throw WaraqaError.noTextFound }

        try? FileManager.default.removeItem(at: output)
        var mediaBox = pageRect
        guard let ctx = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else { throw WaraqaError.writeFailed }
        let framesetter = CTFramesetterCreateWithAttributedString(body)
        var start = 0
        var pages = 0
        while start < body.length {
            try checkCancelled()
            ctx.beginPage(mediaBox: &mediaBox)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            start += visible.length
            pages += 1
        }
        ctx.closePDF()
        try validate(output, expectedPages: pages)
    }
}
#endif
