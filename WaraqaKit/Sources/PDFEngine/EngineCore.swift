#if canImport(PDFKit)
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import WaraqaCore

/// Reports progress 0...1. Called from the worker thread.
public typealias ProgressHandler = @Sendable (Double) -> Void

/// The on-device PDF engine. Every operation:
///  - reads from the input URL and writes a *new* file (the original is never modified),
///  - runs synchronously; callers run it off the main thread (see `ToolRunner` in the app),
///  - stops with `WaraqaError.cancelled` when the surrounding Task is cancelled,
///  - re-opens and checks its output before returning it.
public enum PDFEngine {

    // MARK: - Opening

    /// Opens a PDF, unlocking it with `password` when needed.
    public static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw WaraqaError.cannotOpen(fileName: url.lastPathComponent)
        }
        if document.isLocked {
            guard let password, !password.isEmpty else { throw WaraqaError.passwordRequired }
            guard document.unlock(withPassword: password) else { throw WaraqaError.wrongPassword }
        }
        guard document.pageCount > 0 else { throw WaraqaError.emptyDocument }
        return document
    }

    public static func isPasswordProtected(_ url: URL) -> Bool {
        PDFDocument(url: url)?.isLocked ?? false
    }

    public static func pageCount(_ url: URL, password: String? = nil) throws -> Int {
        try open(url, password: password).pageCount
    }

    /// A document ready for low-level drawing: decrypted and with annotations burned into the
    /// page content, so CoreGraphics renders exactly what the user sees in a viewer.
    static func prepareForDrawing(_ url: URL, password: String?, work: Workspace) throws -> PDFDocument {
        var document = try open(url, password: password)
        if document.isEncrypted {
            let plain = try copyPages(of: document, indices: Array(0..<document.pageCount))
            let tmp = work.file("decrypted.pdf")
            try write(plain, to: tmp)
            document = try open(tmp)
        }
        let hasAnnotations = (0..<document.pageCount).contains { !(document.page(at: $0)?.annotations.isEmpty ?? true) }
        if hasAnnotations {
            let tmp = work.file("flattened.pdf")
            guard document.write(to: tmp, withOptions: [.burnInAnnotationsOption: true]),
                  let flat = PDFDocument(url: tmp), flat.pageCount == document.pageCount else {
                return document
            }
            document = flat
        }
        return document
    }

    // MARK: - Writing & validation

    static func write(_ document: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        try ensureSpace(for: url, estimate: Int64(document.pageCount) * 50_000)
        try? FileManager.default.removeItem(at: url)
        let ok = options.isEmpty ? document.write(to: url) : document.write(to: url, withOptions: options)
        guard ok else { throw WaraqaError.writeFailed }
    }

    /// Re-opens a result and checks it really is a readable PDF with the expected page count.
    @discardableResult
    public static func validate(_ url: URL, expectedPages: Int? = nil, password: String? = nil) throws -> PDFDocument {
        guard FileManager.default.fileExists(atPath: url.path),
              let doc = PDFDocument(url: url) else { throw WaraqaError.outputValidationFailed }
        if doc.isLocked {
            guard let password, doc.unlock(withPassword: password) else { throw WaraqaError.outputValidationFailed }
        }
        guard doc.pageCount > 0 else { throw WaraqaError.outputValidationFailed }
        if let expectedPages, doc.pageCount != expectedPages { throw WaraqaError.outputValidationFailed }
        return doc
    }

    static func ensureSpace(for url: URL, estimate: Int64) throws {
        let dir = url.deletingLastPathComponent()
        #if os(iOS)
        if let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, free < estimate + 20_000_000 {
            throw WaraqaError.notEnoughStorage
        }
        #else
        if let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let free = values.volumeAvailableCapacity, Int64(free) < estimate + 20_000_000 {
            throw WaraqaError.notEnoughStorage
        }
        #endif
    }

    static func checkCancelled() throws {
        if Task.isCancelled { throw WaraqaError.cancelled }
    }

    public static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: - Page copies

    /// A new, unencrypted document with copies of the given pages in the given order.
    static func copyPages(of document: PDFDocument, indices: [Int], rotations: [Int: Int] = [:]) throws -> PDFDocument {
        let result = PDFDocument()
        for (position, index) in indices.enumerated() {
            try checkCancelled()
            guard let page = document.page(at: index)?.copy() as? PDFPage else { throw WaraqaError.writeFailed }
            if let extra = rotations[index] {
                page.rotation = normalizedRotation(page.rotation + extra)
            }
            result.insert(page, at: position)
        }
        return result
    }

    static func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    // MARK: - Low-level drawing

    /// Visible size of a page (crop box, with /Rotate applied).
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let r = normalizedRotation(Int(page.rotationAngle))
        return (r == 90 || r == 270) ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Re-draws every page into a new PDF, letting callers draw on top. `pageSpace` draws in the
    /// page's own coordinates (same as PDFKit/PDFView page coordinates); `displaySpace` draws in
    /// the upright visible page (origin bottom-left), which is what page numbers and watermarks need.
    /// `replacement` may supply an image that replaces a page's content entirely (redaction, strong
    /// compression).
    static func redraw(_ document: PDFDocument, to output: URL,
                       pageSpace: ((CGContext, Int, CGPDFPage) throws -> Void)? = nil,
                       displaySpace: ((CGContext, Int, CGRect) throws -> Void)? = nil,
                       replacement: ((Int, CGPDFPage, CGSize) throws -> CGImage?)? = nil,
                       progress: ProgressHandler? = nil) throws {
        try ensureSpace(for: output, estimate: fileSize(document.documentURL ?? output))
        try? FileManager.default.removeItem(at: output)
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw WaraqaError.writeFailed }
        let count = document.pageCount
        do {
            try drawPages()
        } catch {
            // Never leave a half-written file behind.
            context.closePDF()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        context.closePDF()

        func drawPages() throws {
        for i in 0..<count {
            try checkCancelled()
            try autoreleasepool {
                guard let pdfPage = document.page(at: i), let page = pdfPage.pageRef else { throw WaraqaError.writeFailed }
                let size = displaySize(of: page)
                var mediaBox = CGRect(origin: .zero, size: size)
                context.beginPage(mediaBox: &mediaBox)
                if let image = try replacement?(i, page, size) {
                    context.interpolationQuality = .high
                    context.draw(image, in: mediaBox)
                } else {
                    context.saveGState()
                    context.concatenate(page.getDrawingTransform(.cropBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true))
                    context.clip(to: page.getBoxRect(.cropBox))
                    context.drawPDFPage(page)
                    try pageSpace?(context, i, page)
                    context.restoreGState()
                }
                try displaySpace?(context, i, mediaBox)
                context.endPage()
            }
            progress?(Double(i + 1) / Double(count))
        }
        }
    }

    /// Renders a page to an RGB bitmap at `dpi` (72 = 1 point per pixel).
    /// Renders a page at `dpi`, but never larger than `maxSide` pixels on the long side: photo
    /// pages are physically big, and an uncapped bitmap can use hundreds of MB on a phone.
    static func render(_ page: CGPDFPage, dpi: CGFloat, maxSide: CGFloat = 4096,
                       drawExtra: ((CGContext, CGAffineTransform) -> Void)? = nil) throws -> CGImage {
        let size = displaySize(of: page)
        let scale = min(dpi / 72, maxSide / max(size.width, size.height, 1))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard width * height <= 8_192 * 8_192,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw WaraqaError.writeFailed
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        let transform = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        ctx.saveGState()
        ctx.concatenate(transform)
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        drawExtra?(ctx, transform)
        guard let image = ctx.makeImage() else { throw WaraqaError.writeFailed }
        return image
    }

    // MARK: - Images

    static func encode(_ image: CGImage, as type: UTType, quality: Double = 0.85) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw WaraqaError.writeFailed
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw WaraqaError.writeFailed }
        return data as Data
    }

    /// A JPEG-backed CGImage: CoreGraphics embeds its DCT data as-is in PDFs, which keeps image
    /// PDFs small instead of storing raw pixels.
    static func jpegImage(_ image: CGImage, quality: Double) throws -> CGImage {
        let data = try encode(image, as: .jpeg, quality: quality)
        guard let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw WaraqaError.writeFailed
        }
        return jpeg
    }

    /// Loads an image with its EXIF orientation applied, limited to `maxPixels` on the long side.
    static func loadImage(_ url: URL, maxPixels: Int = 4096) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw WaraqaError.imageUnreadable(fileName: url.lastPathComponent)
        }
        return try loadImage(source, name: url.lastPathComponent, maxPixels: maxPixels)
    }

    static func loadImage(data: Data, maxPixels: Int = 4096) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw WaraqaError.imageUnreadable(fileName: "")
        }
        return try loadImage(source, name: "", maxPixels: maxPixels)
    }

    private static func loadImage(_ source: CGImageSource, name: String, maxPixels: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw WaraqaError.imageUnreadable(fileName: name)
        }
        return image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    // MARK: - Text drawing

    static func color(hex: String, alpha: Double = 1) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0x1F5FAD
        return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    /// A system font that covers Arabic and Latin.
    static func font(size: CGFloat, bold: Bool = false) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, "ar" as CFString)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return base
    }

    /// A single line, shaped by CoreText (handles Arabic joining and right-to-left order).
    static func line(_ text: String, size: CGFloat, color: CGColor, bold: Bool = false) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    static func bounds(of line: CTLine) -> CGSize {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return CGSize(width: CGFloat(width), height: ascent + descent)
    }

    /// Draws a line with its bottom-left at `origin` (the descent is accounted for).
    static func draw(_ line: CTLine, at origin: CGPoint, in ctx: CGContext) {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: origin.x, y: origin.y + descent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func cgRect(_ r: PageRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }
    static func pageRect(_ r: CGRect) -> PageRect { PageRect(x: r.minX, y: r.minY, width: r.width, height: r.height) }
}

/// A private temporary folder for one operation. Removed when the operation ends; on iOS its
/// files are encrypted while the device is locked (complete file protection).
public final class Workspace {
    public let url: URL

    public init(parent: URL = FileManager.default.temporaryDirectory) throws {
        url = parent.appendingPathComponent("waraqa-work-\(UUID().uuidString)", isDirectory: true)
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
    }

    public func file(_ name: String) -> URL {
        url.appendingPathComponent(UUID().uuidString + "-" + name)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
