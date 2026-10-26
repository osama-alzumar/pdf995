#if canImport(PDFKit) && canImport(Vision)
import Foundation
import PDFKit
import Vision
import CoreGraphics
import CoreText
import WaraqaCore

/// Text recognition with Apple's Vision framework, fully on the device.
public enum OCREngine {
    public struct Line: Sendable {
        public let text: String
        /// Normalized box (0...1, origin bottom-left) in the upright page image.
        public let box: CGRect
        public let confidence: Float
    }

    public struct PageResult: Sendable {
        public let pageIndex: Int
        public let lines: [Line]
        public var text: String { lines.map(\.text).joined(separator: "\n") }
    }

    /// Languages Vision can read on this device, e.g. ["en-US", "ar-SA", …].
    public static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    public static func supportsArabic() -> Bool {
        supportedLanguages().contains { $0.lowercased().hasPrefix("ar") }
    }

    /// Picks the Vision language codes for the user's choice (“ar”, “en”).
    static func visionLanguages(for codes: [String]) throws -> [String] {
        let supported = supportedLanguages()
        var result: [String] = []
        for code in codes {
            guard let match = supported.first(where: { $0.lowercased().hasPrefix(code.lowercased()) }) else {
                throw WaraqaError.ocrLanguageUnavailable
            }
            result.append(match)
        }
        return result
    }

    public static func recognize(_ image: CGImage, languages: [String]) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = try visionLanguages(for: languages)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Line(text: candidate.string, box: observation.boundingBox, confidence: candidate.confidence)
        }
    }

    /// Recognizes every page (all when `pages` is nil).
    public static func recognize(_ input: PDFInput, languages: [String], dpi: CGFloat = 300, pages: [Int]? = nil,
                                 progress: ProgressHandler? = nil) throws -> [PageResult] {
        let work = try Workspace()
        let doc = try PDFEngine.prepareForDrawing(input.url, password: input.password, work: work)
        let indices = pages ?? Array(0..<doc.pageCount)
        var results: [PageResult] = []
        for (n, i) in indices.enumerated() {
            try PDFEngine.checkCancelled()
            try autoreleasepool {
                guard let page = doc.page(at: i)?.pageRef else { throw WaraqaError.writeFailed }
                let image = try PDFEngine.render(page, dpi: dpi)
                results.append(PageResult(pageIndex: i, lines: try recognize(image, languages: languages)))
            }
            progress?(Double(n + 1) / Double(indices.count))
        }
        return results
    }

    /// Makes a searchable PDF: each page keeps its original look, and the recognized text is
    /// laid over it as invisible text at the right positions, so it can be searched, selected and
    /// copied. Returns the recognized text per page.
    public static func makeSearchablePDF(_ input: PDFInput, languages: [String], to output: URL,
                                         progress: ProgressHandler? = nil) throws -> [PageResult] {
        let results = try recognize(input, languages: languages, progress: { p in progress?(p * 0.85) })
        guard results.contains(where: { !$0.lines.isEmpty }) else { throw WaraqaError.noTextFound }
        let byPage = Dictionary(uniqueKeysWithValues: results.map { ($0.pageIndex, $0) })
        let work = try Workspace()
        let doc = try PDFEngine.prepareForDrawing(input.url, password: input.password, work: work)
        try PDFEngine.redraw(doc, to: output, displaySpace: { ctx, index, box in
            guard let result = byPage[index] else { return }
            for line in result.lines { drawInvisible(line, pageBox: box, in: ctx) }
        }, progress: { p in progress?(0.85 + p * 0.15) })
        try PDFEngine.validate(output, expectedPages: doc.pageCount)
        return results
    }

    static func drawInvisible(_ line: Line, pageBox: CGRect, in ctx: CGContext) {
        let rect = CGRect(x: pageBox.minX + line.box.minX * pageBox.width,
                          y: pageBox.minY + line.box.minY * pageBox.height,
                          width: line.box.width * pageBox.width,
                          height: line.box.height * pageBox.height)
        guard rect.width > 1, rect.height > 1 else { return }
        let fontSize = rect.height * 0.85
        let ctLine = PDFEngine.line(line.text, size: fontSize, color: CGColor(gray: 0, alpha: 1))
        let natural = PDFEngine.bounds(of: ctLine)
        let stretch = natural.width > 0 ? rect.width / natural.width : 1
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        ctx.textMatrix = CGAffineTransform(scaleX: stretch, y: 1)
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15)
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }
}
#endif
