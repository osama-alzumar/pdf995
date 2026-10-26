#if canImport(PDFKit)
import Foundation
import PDFKit
import CoreGraphics
import WaraqaCore

extension PDFEngine {
    // MARK: - Protect / unlock

    /// Encrypts with an open password. The owner password (for changing permissions) is a separate
    /// random value unless the user gives one, so the open password alone can't lift restrictions.
    public static func protect(_ input: PDFInput, userPassword: String, ownerPassword: String? = nil,
                               to output: URL) throws {
        guard !userPassword.isEmpty else { throw WaraqaError.missingOptions }
        let doc = try open(input.url, password: input.password)
        let plain = try copyPages(of: doc, indices: Array(0..<doc.pageCount))
        let owner = ownerPassword?.isEmpty == false ? ownerPassword! : UUID().uuidString + UUID().uuidString
        try write(plain, to: output, options: [.userPasswordOption: userPassword, .ownerPasswordOption: owner])
        // Verify: it must not open without the password and must open with it.
        guard let check = PDFDocument(url: output), check.isEncrypted, check.isLocked else {
            throw WaraqaError.outputValidationFailed
        }
        guard check.unlock(withPassword: userPassword), check.pageCount == doc.pageCount else {
            throw WaraqaError.outputValidationFailed
        }
    }

    /// Removes the password, given the correct one.
    public static func unlock(_ input: PDFInput, to output: URL) throws {
        guard let probe = PDFDocument(url: input.url) else { throw WaraqaError.cannotOpen(fileName: input.url.lastPathComponent) }
        guard probe.isEncrypted else { throw WaraqaError.notEncrypted }
        let doc = try open(input.url, password: input.password)
        let plain = try copyPages(of: doc, indices: Array(0..<doc.pageCount))
        try write(plain, to: output)
        var result = PDFDocument(url: output)
        if result?.isEncrypted == true {
            // Page copies kept the encryption: redraw the pages into a fresh, unencrypted file.
            let work = try Workspace()
            let drawable = try prepareForDrawing(input.url, password: input.password, work: work)
            try redraw(drawable, to: output)
            result = PDFDocument(url: output)
        }
        guard let result, !result.isEncrypted, !result.isLocked, result.pageCount == doc.pageCount else {
            throw WaraqaError.outputValidationFailed
        }
    }

    // MARK: - Redaction

    public struct RedactionReport: Sendable {
        public let redactedAreas: Int
        public let redactedPages: [Int]
    }

    /// Areas of the given terms in the document, by page (page space). Used to preview a search
    /// redaction before applying it.
    public static func findAreas(of terms: [String], in input: PDFInput) throws -> [Int: [PageRect]] {
        let doc = try open(input.url, password: input.password)
        var areas: [Int: [PageRect]] = [:]
        for term in terms.map({ $0.trimmingCharacters(in: .whitespaces) }) where !term.isEmpty {
            for selection in doc.findString(term, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
                for page in selection.pages {
                    let index = doc.index(for: page)
                    // One box per line keeps multi-line matches tight.
                    for line in selection.selectionsByLine() {
                        let b = line.bounds(for: page)
                        guard b.width > 0, b.height > 0 else { continue }
                        areas[index, default: []].append(pageRect(b.insetBy(dx: -1.5, dy: -1.5)))
                    }
                }
            }
        }
        return areas
    }

    /// True redaction. Every page that has a marked area is re-rendered as an image with the areas
    /// painted black, so the text, vector drawings and images underneath no longer exist in the
    /// output (a black box drawn on top would leave them extractable). Other pages are copied as
    /// they are. Document metadata is dropped. The output is checked: none of the searched terms
    /// may be extractable from it.
    public static func redact(_ input: PDFInput, areas: [Int: [PageRect]], terms: [String] = [],
                              dpi: CGFloat = 200, to output: URL, progress: ProgressHandler? = nil) throws -> RedactionReport {
        var all = areas
        if !terms.isEmpty {
            for (page, rects) in try findAreas(of: terms, in: input) { all[page, default: []] += rects }
        }
        let total = all.values.reduce(0) { $0 + $1.count }
        guard total > 0 else { throw WaraqaError.nothingToRedact }

        let work = try Workspace()
        let doc = try prepareForDrawing(input.url, password: input.password, work: work)
        try redraw(doc, to: output, replacement: { index, page, _ in
            guard let rects = all[index], !rects.isEmpty else { return nil }
            return try render(page, dpi: dpi) { ctx, transform in
                ctx.saveGState()
                ctx.concatenate(transform)
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                for r in rects { ctx.fill(cgRect(r)) }
                ctx.restoreGState()
            }
        }, progress: progress)

        let check = try validate(output, expectedPages: doc.pageCount)
        let fullText = (0..<check.pageCount).map { check.page(at: $0)?.string ?? "" }.joined(separator: "\n")
        for term in terms where !term.trimmingCharacters(in: .whitespaces).isEmpty {
            if fullText.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                try? FileManager.default.removeItem(at: output)
                throw WaraqaError.outputValidationFailed
            }
        }
        for index in all.keys where !(check.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: output)
            throw WaraqaError.outputValidationFailed
        }
        return RedactionReport(redactedAreas: total, redactedPages: all.keys.sorted())
    }

    // MARK: - Compare

    public static func compare(_ old: PDFInput, _ new: PDFInput) throws -> DocumentComparison {
        let a = try pageTexts(old), b = try pageTexts(new)
        let hasText = (a + b).contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasText else { throw WaraqaError.noTextFound }
        return DocumentComparison(oldPages: a, newPages: b)
    }
}
#endif
