#if canImport(PDFKit)
import Foundation
import PDFKit
import CoreGraphics
import WaraqaCore

extension PDFEngine {
    /// Compresses a PDF. Light and recommended keep text selectable (PDFKit re-encodes images as
    /// JPEG, the second also downsamples them to screen resolution); strong re-renders every page
    /// as a JPEG image. If the result isn't smaller, the original bytes are kept and the report
    /// says so — the app never shows a fake saving.
    public static func compress(_ input: PDFInput, level: CompressionLevel, to output: URL,
                                progress: ProgressHandler? = nil) throws -> CompressionReport {
        let original = fileSize(input.url)
        let doc = try open(input.url, password: input.password)
        let pages = doc.pageCount
        let work = try Workspace()
        let candidate = work.file("compressed.pdf")

        switch level {
        case .light:
            progress?(0.2)
            try write(doc, to: candidate, options: [.saveImagesAsJPEGOption: true])
        case .recommended:
            progress?(0.2)
            try write(doc, to: candidate, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        case .strong:
            let drawable = try prepareForDrawing(input.url, password: input.password, work: work)
            try redraw(drawable, to: candidate, replacement: { _, page, _ in
                try jpegImage(try render(page, dpi: 96), quality: 0.5)
            }, progress: { p in progress?(p * 0.95) })
        }
        try validate(candidate, expectedPages: pages)

        let compressed = fileSize(candidate)
        try? FileManager.default.removeItem(at: output)
        if compressed < original {
            try FileManager.default.moveItem(at: candidate, to: output)
        } else {
            // Not smaller: hand back an exact copy of the original (protection included).
            try FileManager.default.copyItem(at: input.url, to: output)
        }
        progress?(1)
        return CompressionReport(originalBytes: original, compressedBytes: min(compressed, original))
    }

    /// Tries to recover a damaged PDF on the device: skips junk before the header, then lets
    /// CoreGraphics rebuild the cross-reference table, and writes a clean copy of every page that
    /// can be read. Throws `cannotOpen` when nothing can be recovered (the app then offers the
    /// server, which uses qpdf and Ghostscript).
    public static func repair(_ input: PDFInput, to output: URL) throws -> Int {
        guard var data = try? Data(contentsOf: input.url, options: .mappedIfSafe), !data.isEmpty else {
            throw WaraqaError.cannotOpen(fileName: input.url.lastPathComponent)
        }
        if let start = data.range(of: Data("%PDF-".utf8)), start.lowerBound > 0 {
            data = data.subdata(in: start.lowerBound..<data.endIndex)
        }
        var doc = PDFDocument(data: data)
        if doc == nil || doc?.pageCount == 0 {
            // A file cut short often only lacks its trailer marker.
            var patched = data
            patched.append(Data("\n%%EOF\n".utf8))
            doc = PDFDocument(data: patched)
        }
        guard let doc, doc.pageCount > 0 else {
            throw WaraqaError.cannotOpen(fileName: input.url.lastPathComponent)
        }
        if doc.isLocked {
            guard let password = input.password else { throw WaraqaError.passwordRequired }
            guard doc.unlock(withPassword: password) else { throw WaraqaError.wrongPassword }
        }
        let result = PDFDocument()
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i)?.copy() as? PDFPage, page.bounds(for: .mediaBox).width > 0 {
                result.insert(page, at: result.pageCount)
            }
        }
        guard result.pageCount > 0 else { throw WaraqaError.cannotOpen(fileName: input.url.lastPathComponent) }
        try write(result, to: output)
        try validate(output, expectedPages: result.pageCount)
        return result.pageCount
    }
}
#endif
