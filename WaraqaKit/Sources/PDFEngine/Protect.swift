#if canImport(PDFKit)
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import WaraqaCore
#if canImport(Vision)
import Vision
#endif

/// A suggested area to hide, found by reading the page on the device.
public struct SensitiveArea: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let pageIndex: Int
    /// Page space (same as PDFView / redaction coordinates).
    public let rect: PageRect
    public let kind: SensitiveDataDetector.Kind
    public let text: String
    public var hidden: Bool

    public init(id: UUID = UUID(), pageIndex: Int, rect: PageRect, kind: SensitiveDataDetector.Kind, text: String, hidden: Bool) {
        self.id = id
        self.pageIndex = pageIndex
        self.rect = rect
        self.kind = kind
        self.text = text
        self.hidden = hidden
    }
}

public struct DocumentAnalysis: Sendable {
    public let areas: [SensitiveArea]
    public let kind: DocumentKind
    public let confidence: Double
    public let recognizedCharacters: Int
}

extension PDFEngine {
    // MARK: - Protection (watermark + optional true redaction)

    /// Writes a protected copy: hidden areas are removed for real first (pages re-rendered
    /// without them), then the protection mark is drawn on every page. Metadata is not carried
    /// over. The original file is not touched.
    public static func protect(_ input: PDFInput, spec: ProtectionSpec, redactAreas: [Int: [PageRect]] = [:],
                               redactMaxSide: CGFloat = 4096, to output: URL, progress: ProgressHandler? = nil) throws {
        let spec = spec.normalized
        let work = try Workspace()
        var source = input
        if redactAreas.values.contains(where: { !$0.isEmpty }) {
            let redacted = work.file("redacted.pdf")
            _ = try redact(input, areas: redactAreas, maxSide: redactMaxSide, to: redacted, progress: { p in progress?(p * 0.5) })
            source = PDFInput(url: redacted)
        }
        let doc = try prepareForDrawing(source.url, password: source.password, work: work)
        try redraw(doc, to: output, displaySpace: { ctx, _, box in
            drawProtection(spec, in: ctx, box: box)
        }, progress: { p in progress?(redactAreas.isEmpty ? p : 0.5 + p * 0.5) })
        try validate(output, expectedPages: doc.pageCount)
    }

    /// Photos or scans → one protected PDF (and, if asked, protected JPEG images of each page).
    public static func protectImages(_ images: [ImageSource], spec: ProtectionSpec, redactAreas: [Int: [PageRect]] = [:],
                                     pdfOutput: URL, imagesInto directory: URL? = nil, baseName: String = "Waraqa",
                                     progress: ProgressHandler? = nil) throws -> [URL] {
        let work = try Workspace()
        let combined = work.file("images.pdf")
        try imagesToPDF(images, pageSize: .fit, to: combined, progress: { p in progress?(p * 0.3) })
        try protect(PDFInput(url: combined), spec: spec, redactAreas: redactAreas, to: pdfOutput,
                    progress: { p in progress?(0.3 + p * 0.5) })
        guard let directory else { return [pdfOutput] }
        let pages = try pdfToImages(PDFInput(url: pdfOutput), format: .jpeg, dpi: 200, into: directory,
                                    baseName: baseName, progress: { p in progress?(0.8 + p * 0.2) })
        return [pdfOutput] + pages
    }

    /// The exact look of the protected page, rendered from a real protected copy of that page.
    public static func protectionPreview(_ input: PDFInput, spec: ProtectionSpec, redactAreas: [Int: [PageRect]] = [:],
                                         page index: Int = 0, maxPixels: CGFloat = 900) throws -> CGImage {
        let work = try Workspace()
        let doc = try open(input.url, password: input.password)
        guard index >= 0, index < doc.pageCount else { throw WaraqaError.noPagesSelected }
        let single = try copyPages(of: doc, indices: [index])
        let pageFile = work.file("page.pdf")
        try write(single, to: pageFile)
        let out = work.file("preview.pdf")
        let areas = redactAreas[index].map { [0: $0] } ?? [:]
        // The preview only needs screen resolution; the real copy is rendered at full quality.
        try protect(PDFInput(url: pageFile), spec: spec, redactAreas: areas, redactMaxSide: max(maxPixels * 1.5, 1200), to: out)
        guard let image = thumbnail(out, page: 0, maxPixels: maxPixels) else { throw WaraqaError.writeFailed }
        return image
    }

    // MARK: Drawing

    /// Draws the protection mark in the upright visible page box.
    static func drawProtection(_ spec: ProtectionSpec, in ctx: CGContext, box: CGRect) {
        let k = max(0.35, min(box.width, box.height) / 595) // 1.0 on an A4 page
        let color = color(hex: spec.colorHex)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(spec.opacity))
        switch spec.style {
        case .diagonal:
            drawDiagonal(spec, ctx: ctx, box: box, k: k, color: color)
        case .tiled:
            drawTiled(spec, ctx: ctx, box: box, k: k, color: color, density: 1)
        case .intense:
            drawTiled(spec, ctx: ctx, box: box, k: k, color: color, density: 0.6)
            drawDiagonal(spec, ctx: ctx, box: box, k: k, color: color)
        case .stamp:
            drawStamp(spec, ctx: ctx, box: box, k: k, color: color)
        case .small:
            drawFooter(spec, ctx: ctx, box: box, k: k, color: color)
        }
        ctx.restoreGState()
    }

    private static func rotated(_ ctx: CGContext, at center: CGPoint, degrees: Double, size: CGSize, paint: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: CGFloat(degrees) * .pi / 180)
        ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        paint()
        ctx.restoreGState()
    }

    private static func drawDiagonal(_ spec: ProtectionSpec, ctx: CGContext, box: CGRect, k: CGFloat, color: CGColor) {
        var size = CGFloat(spec.fontSize) * k * 1.3
        var l = line(spec.sentence, size: size, color: color, bold: true)
        var b = bounds(of: l)
        // Fit along the page diagonal (or width when not slanted).
        let rad = abs(spec.angleDegrees) * .pi / 180
        let room = min(box.width / max(cos(rad), 0.2), box.height / max(sin(rad), 0.2)) * 0.88
        if b.width > room {
            size *= room / b.width
            l = line(spec.sentence, size: size, color: color, bold: true)
            b = bounds(of: l)
        }
        rotated(ctx, at: CGPoint(x: box.midX, y: box.midY), degrees: spec.angleDegrees, size: b) {
            draw(l, at: .zero, in: ctx)
        }
    }

    private static func drawTiled(_ spec: ProtectionSpec, ctx: CGContext, box: CGRect, k: CGFloat, color: CGColor, density: Double) {
        let size = CGFloat(spec.fontSize) * k * 0.62
        let l = line(spec.shortText, size: size, color: color, bold: true)
        let b = bounds(of: l)
        let factor = CGFloat(spec.spacing * density)
        let stepX = (b.width + 48 * k) * factor
        let stepY = max(b.height * 4.2, 40 * k) * factor
        // Cover the box even after rotation: walk a square around the page's diagonal.
        let reach = hypot(box.width, box.height)
        var row = 0
        var y = box.midY - reach / 2
        while y <= box.midY + reach / 2 {
            var x = box.midX - reach / 2 + (row.isMultiple(of: 2) ? 0 : stepX / 2)
            while x <= box.midX + reach / 2 {
                // Rotate the grid point about the page center so rows follow the angle.
                let dx = x - box.midX, dy = y - box.midY
                let a = CGFloat(spec.angleDegrees) * .pi / 180
                let px = box.midX + dx * cos(a) - dy * sin(a)
                let py = box.midY + dx * sin(a) + dy * cos(a)
                if box.insetBy(dx: -b.width, dy: -b.height).contains(CGPoint(x: px, y: py)) {
                    rotated(ctx, at: CGPoint(x: px, y: py), degrees: spec.angleDegrees, size: b) { draw(l, at: .zero, in: ctx) }
                }
                x += stepX
            }
            y += stepY
            row += 1
        }
    }

    private static func drawStamp(_ spec: ProtectionSpec, ctx: CGContext, box: CGRect, k: CGFloat, color: CGColor) {
        let lines = spec.stampLines
        let size = CGFloat(spec.fontSize) * k * 0.5
        let ctLines = lines.enumerated().map { i, text -> CTLine in
            let isLast = i == lines.count - 1
            return line(text, size: isLast ? size * 0.72 : (i == 0 ? size * 1.1 : size), color: color, bold: !isLast)
        }
        let sizes = ctLines.map(bounds(of:))
        let pad = 10 * k, gap = 4 * k
        let width = (sizes.map(\.width).max() ?? 0) + pad * 2
        let height = sizes.map(\.height).reduce(0, +) + gap * CGFloat(max(0, sizes.count - 1)) + pad * 2
        let margin = 28 * k
        let center = CGPoint(x: box.minX + margin + width / 2, y: box.minY + margin + height / 2)
        rotated(ctx, at: center, degrees: -6, size: CGSize(width: width, height: height)) {
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.55))
            ctx.fill(rect)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2 * k)
            ctx.stroke(rect.insetBy(dx: k, dy: k))
            ctx.setLineWidth(0.8 * k)
            ctx.stroke(rect.insetBy(dx: 4 * k, dy: 4 * k))
            var y = height - pad
            for (l, s) in zip(ctLines, sizes) {
                y -= s.height
                // Right-aligned for Arabic, left for English.
                let x = spec.language == .arabic ? width - pad - s.width : pad
                draw(l, at: CGPoint(x: x, y: y), in: ctx)
                y -= gap
            }
        }
    }

    private static func drawFooter(_ spec: ProtectionSpec, ctx: CGContext, box: CGRect, k: CGFloat, color: CGColor) {
        var size = CGFloat(spec.fontSize) * k * 0.42
        var l = line(spec.sentence, size: size, color: color, bold: true)
        var b = bounds(of: l)
        let maxWidth = box.width - 32 * k
        if b.width > maxWidth {
            size *= maxWidth / b.width
            l = line(spec.sentence, size: size, color: color, bold: true)
            b = bounds(of: l)
        }
        let band = CGRect(x: box.minX, y: box.minY, width: box.width, height: b.height + 14 * k)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.6))
        ctx.fill(band)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(0.8 * k)
        ctx.move(to: CGPoint(x: band.minX, y: band.maxY))
        ctx.addLine(to: CGPoint(x: band.maxX, y: band.maxY))
        ctx.strokePath()
        draw(l, at: CGPoint(x: box.midX - b.width / 2, y: band.minY + 7 * k), in: ctx)
    }

    // MARK: - Sensitive data suggestions

    #if canImport(Vision)
    /// Reads the first pages on the device, suggests areas to hide (IDs, IBANs, phones, birth
    /// dates, addresses…) and guesses the document type. Nothing leaves the device.
    public static func analyze(_ input: PDFInput, maxPages: Int = 6, progress: ProgressHandler? = nil) throws -> DocumentAnalysis {
        let work = try Workspace()
        let doc = try prepareForDrawing(input.url, password: input.password, work: work)
        let supported = OCREngine.supportedLanguages()
        var languages = supported.filter { $0.lowercased().hasPrefix("ar") }.prefix(1).map { $0 }
        if let en = supported.first(where: { $0.lowercased().hasPrefix("en") }) { languages.append(en) }
        var areas: [SensitiveArea] = []
        var allText = ""
        let count = min(doc.pageCount, maxPages)
        for i in 0..<count {
            try checkCancelled()
            guard let page = doc.page(at: i)?.pageRef else { continue }
            let size = displaySize(of: page)
            let image = try render(page, dpi: 220, maxSide: 3000) // enough for text recognition, bounded memory
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            if !languages.isEmpty { request.recognitionLanguages = languages }
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let displayRect = CGRect(origin: .zero, size: size)
            let toPage = page.getDrawingTransform(.cropBox, rect: displayRect, rotate: 0, preserveAspectRatio: true).inverted()
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                allText += text + "\n"
                for match in SensitiveDataDetector.detect(in: text) {
                    var normalized = observation.boundingBox
                    if !match.wholeLine,
                       let range = Range(NSRange(location: match.offset, length: match.length), in: text),
                       let box = try? candidate.boundingBox(for: range)?.boundingBox {
                        normalized = box
                    }
                    let display = CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
                                         width: normalized.width * size.width, height: normalized.height * size.height)
                        .insetBy(dx: -3, dy: -3)
                    let inPage = display.applying(toPage)
                    areas.append(SensitiveArea(pageIndex: i, rect: pageRect(inPage), kind: match.kind,
                                               text: match.text, hidden: match.kind.hiddenByDefault))
                }
            }
            progress?(Double(i + 1) / Double(count))
        }
        let guess = DocumentClassifier.classify(allText)
        return DocumentAnalysis(areas: areas, kind: guess.kind, confidence: guess.confidence,
                                recognizedCharacters: allText.count)
    }
    #endif

    // MARK: - Image tools

    public enum ImageOutputFormat: String, CaseIterable, Sendable, Identifiable {
        case jpeg, png, heic
        public var id: String { rawValue }
        public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        var type: UTType { self == .jpeg ? .jpeg : (self == .png ? .png : .heic) }
    }

    public struct ImageResult: Sendable {
        public let url: URL
        public let originalBytes: Int64
        public let newBytes: Int64
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    public static func canEncode(_ format: ImageOutputFormat) -> Bool {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return ids.contains(format.type.identifier)
    }

    /// Converts images between JPG, PNG and HEIC (orientation applied, metadata such as GPS
    /// location removed). `maxPixels` > 0 also downsizes the long side; `quality` applies to
    /// JPG/HEIC. Files that came out larger than the original are reported as such, not hidden.
    public static func convertImages(_ urls: [URL], to format: ImageOutputFormat, quality: Double = 0.85,
                                     maxPixels: Int = 0, into directory: URL, progress: ProgressHandler? = nil) throws -> [ImageResult] {
        guard !urls.isEmpty else { throw WaraqaError.noPagesSelected }
        guard canEncode(format) else { throw WaraqaError.unsupportedFile(fileName: format.fileExtension.uppercased()) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var results: [ImageResult] = []
        var used = Set<String>()
        for (n, url) in urls.enumerated() {
            try checkCancelled()
            try autoreleasepool {
                let image = try loadImage(url, maxPixels: maxPixels > 0 ? maxPixels : 12_000)
                let flattened = format == .png ? image : try flatten(image)
                let data = try encode(flattened, as: format.type, quality: quality)
                let stem = FileNaming.sanitize(FileNaming.stem(of: url.lastPathComponent))
                let name = FileNaming.unique((stem.isEmpty ? "image" : stem) + "." + format.fileExtension, existing: used)
                used.insert(name)
                let out = directory.appendingPathComponent(name)
                try data.write(to: out, options: .atomic)
                guard let check = CGImageSourceCreateWithURL(out as CFURL, nil), CGImageSourceGetCount(check) == 1 else {
                    throw WaraqaError.outputValidationFailed
                }
                results.append(ImageResult(url: out, originalBytes: fileSize(url), newBytes: Int64(data.count),
                                           pixelWidth: flattened.width, pixelHeight: flattened.height))
            }
            progress?(Double(n + 1) / Double(urls.count))
        }
        return results
    }

    /// Smaller images for sending: downsized to `maxPixels` on the long side and re-encoded.
    /// Keeps the original format unless it is PNG without transparency (then JPEG is smaller).
    public static func shrinkImages(_ urls: [URL], maxPixels: Int = 2000, quality: Double = 0.7,
                                    into directory: URL, progress: ProgressHandler? = nil) throws -> [ImageResult] {
        var results: [ImageResult] = []
        for (n, url) in urls.enumerated() {
            let ext = FileNaming.fileExtension(of: url.lastPathComponent)
            var format: ImageOutputFormat = ext == "heic" || ext == "heif" ? .heic : .jpeg
            if ext == "png", let image = try? loadImage(url, maxPixels: 64), hasAlpha(image) { format = .png }
            if format == .heic && !canEncode(.heic) { format = .jpeg }
            results += try convertImages([url], to: format, quality: quality, maxPixels: maxPixels, into: directory)
            progress?(Double(n + 1) / Double(urls.count))
        }
        return results
    }

    /// Removes transparency (white background) for formats without an alpha channel.
    static func flatten(_ image: CGImage) throws -> CGImage {
        guard hasAlpha(image) else { return image }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw WaraqaError.writeFailed
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let out = ctx.makeImage() else { throw WaraqaError.writeFailed }
        return out
    }
}
#endif
