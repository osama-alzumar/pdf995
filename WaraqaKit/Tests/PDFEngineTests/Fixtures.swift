#if canImport(PDFKit)
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import PDFEngine

/// Builds real test documents with CoreGraphics: text PDFs (Arabic/English), large documents,
/// image-only "scanned" pages, photos, encrypted and damaged files.
enum Fixtures {
    static func dir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waraqa-fixtures-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Block {
        var text: String
        var size: CGFloat = 14
        var bold = false
    }

    /// One page per entry; each page draws its blocks top to bottom.
    static func textPDF(_ pages: [[Block]], at url: URL, size: CGSize = CGSize(width: 595, height: 842)) {
        var box = CGRect(origin: .zero, size: size)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for blocks in pages {
            ctx.beginPage(mediaBox: &box)
            var y = size.height - 72
            for block in blocks {
                let line = PDFEngine.line(block.text, size: block.size, color: CGColor(gray: 0, alpha: 1), bold: block.bold)
                y -= block.size * 1.6
                PDFEngine.draw(line, at: CGPoint(x: 60, y: y), in: ctx)
            }
            ctx.endPage()
        }
        ctx.closePDF()
    }

    static func simplePDF(_ texts: [String], at url: URL) {
        textPDF(texts.map { [Block(text: $0)] }, at: url)
    }

    /// A noisy photo-like image (compresses poorly losslessly, well as JPEG).
    static func photo(width: Int, height: Int, seed: UInt8 = 7) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        var v = UInt32(seed)
        for y in 0..<height {
            for x in 0..<width {
                v = v &* 1_103_515_245 &+ 12345
                let p = y * ctx.bytesPerRow + x * 4
                data[p] = UInt8((x * 255) / max(width, 1)) &+ UInt8(truncatingIfNeeded: v >> 24) / 4
                data[p + 1] = UInt8((y * 255) / max(height, 1))
                data[p + 2] = UInt8(truncatingIfNeeded: v >> 16)
                data[p + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    static func writeImage(_ image: CGImage, type: UTType, to url: URL, orientation: Int? = nil) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
    }

    /// A PDF whose pages contain only an embedded photo, stored losslessly (large).
    static func photoPDF(pages: Int, at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for i in 0..<pages {
            ctx.beginPage(mediaBox: &box)
            ctx.draw(photo(width: 1200, height: 1600, seed: UInt8(i + 1)), in: box.insetBy(dx: 40, dy: 40))
            let line = PDFEngine.line("Photo page \(i + 1)", size: 14, color: CGColor(gray: 0, alpha: 1))
            PDFEngine.draw(line, at: CGPoint(x: 50, y: 20), in: ctx)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// A "scanned" page: text rendered to a bitmap, embedded as an image, with no text layer.
    static func scannedPDF(lines: [String], fontSize: CGFloat = 28, at url: URL) {
        let w = 1240, h = 1754 // A4 at 150 dpi
        let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var y = CGFloat(h) - 150
        for text in lines {
            let line = PDFEngine.line(text, size: fontSize * 150 / 72, color: CGColor(gray: 0, alpha: 1))
            PDFEngine.draw(line, at: CGPoint(x: 120, y: y), in: bitmap)
            y -= fontSize * 150 / 72 * 1.8
        }
        let image = bitmap.makeImage()!
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPage(mediaBox: &box)
        ctx.draw(image, in: box)
        ctx.endPage()
        ctx.closePDF()
    }

    static func encryptedPDF(_ texts: [String], password: String, at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let aux: [CFString: Any] = [kCGPDFContextUserPassword: password, kCGPDFContextOwnerPassword: password + "-owner"]
        let ctx = CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary)!
        for t in texts {
            ctx.beginPage(mediaBox: &box)
            PDFEngine.draw(PDFEngine.line(t, size: 16, color: CGColor(gray: 0, alpha: 1)), at: CGPoint(x: 60, y: 700), in: ctx)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    static func sha256(_ url: URL) -> String {
        SHA256.hash(data: try! Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func text(_ url: URL, page: Int, password: String? = nil) -> String {
        let doc = PDFDocument(url: url)!
        if let password { _ = doc.unlock(withPassword: password) }
        return doc.page(at: page)?.string ?? ""
    }

    static func pageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? -1 }
}
#endif
