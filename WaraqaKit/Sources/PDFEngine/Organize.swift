#if canImport(PDFKit)
import Foundation
import PDFKit
import WaraqaCore

/// One input file plus its password, if it has one.
public struct PDFInput: Sendable {
    public let url: URL
    public let password: String?
    public init(url: URL, password: String? = nil) {
        self.url = url
        self.password = password
    }
}

/// A page in the Organize screen's order, with any extra rotation the user applied.
public struct PageEdit: Equatable, Sendable {
    public let sourceIndex: Int
    public let extraRotation: Int
    public init(sourceIndex: Int, extraRotation: Int = 0) {
        self.sourceIndex = sourceIndex
        self.extraRotation = extraRotation
    }
}

extension PDFEngine {
    /// Merge PDFs in the given order.
    public static func merge(_ inputs: [PDFInput], to output: URL, progress: ProgressHandler? = nil) throws {
        guard inputs.count >= 2 else { throw WaraqaError.needsTwoFiles }
        guard inputs.count <= Limits.maxMergeFiles else { throw WaraqaError.fileTooLarge(limitBytes: 0) }
        let result = PDFDocument()
        var expected = 0
        for (n, input) in inputs.enumerated() {
            try checkCancelled()
            let doc = try open(input.url, password: input.password)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { throw WaraqaError.writeFailed }
                result.insert(page, at: result.pageCount)
            }
            expected += doc.pageCount
            progress?(Double(n + 1) / Double(inputs.count) * 0.9)
        }
        try write(result, to: output)
        try validate(output, expectedPages: expected)
        progress?(1)
    }

    /// Split into several files. Returns the files in order.
    public static func split(_ input: PDFInput, mode: SplitMode, into directory: URL, baseName: String,
                             progress: ProgressHandler? = nil) throws -> [URL] {
        let doc = try open(input.url, password: input.password)
        let groups = mode.groups(pageCount: doc.pageCount).filter { !$0.isEmpty }
        guard !groups.isEmpty else { throw WaraqaError.noPagesSelected }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for (n, group) in groups.enumerated() {
            try checkCancelled()
            let part = try copyPages(of: doc, indices: group)
            let url = directory.appendingPathComponent(FileNaming.part(for: baseName, index: n + 1, extension: "pdf"))
            try write(part, to: url)
            try validate(url, expectedPages: group.count)
            outputs.append(url)
            progress?(Double(n + 1) / Double(groups.count))
        }
        return outputs
    }

    /// Keeps only the given pages, in the given order (Extract pages).
    public static func extract(_ input: PDFInput, pages: [Int], to output: URL) throws {
        let doc = try open(input.url, password: input.password)
        guard !pages.isEmpty else { throw WaraqaError.noPagesSelected }
        guard pages.allSatisfy({ $0 >= 0 && $0 < doc.pageCount }) else {
            throw WaraqaError.invalidPageSelection(PageSelection.describe(pages))
        }
        let result = try copyPages(of: doc, indices: pages)
        try write(result, to: output)
        try validate(output, expectedPages: pages.count)
    }

    /// Removes the given pages.
    public static func remove(_ input: PDFInput, pages: [Int], to output: URL) throws {
        let doc = try open(input.url, password: input.password)
        let removing = Set(pages)
        guard !removing.isEmpty else { throw WaraqaError.noPagesSelected }
        let keep = (0..<doc.pageCount).filter { !removing.contains($0) }
        guard !keep.isEmpty else { throw WaraqaError.cannotRemoveAllPages }
        let result = try copyPages(of: doc, indices: keep)
        try write(result, to: output)
        try validate(output, expectedPages: keep.count)
    }

    /// Writes pages in a new order with per-page rotation (Organize). Pages left out are dropped.
    public static func organize(_ input: PDFInput, pages: [PageEdit], to output: URL) throws {
        let doc = try open(input.url, password: input.password)
        guard !pages.isEmpty else { throw WaraqaError.noPagesSelected }
        let result = PDFDocument()
        for (position, edit) in pages.enumerated() {
            guard let page = doc.page(at: edit.sourceIndex)?.copy() as? PDFPage else {
                throw WaraqaError.invalidPageSelection("\(edit.sourceIndex + 1)")
            }
            page.rotation = normalizedRotation(page.rotation + edit.extraRotation)
            result.insert(page, at: position)
        }
        try write(result, to: output)
        try validate(output, expectedPages: pages.count)
    }

    /// Rotates the given pages (all when nil) by a multiple of 90°.
    public static func rotate(_ input: PDFInput, degrees: Int, pages: [Int]? = nil, to output: URL) throws {
        let doc = try open(input.url, password: input.password)
        let targets = Set(pages ?? Array(0..<doc.pageCount))
        guard !targets.isEmpty else { throw WaraqaError.noPagesSelected }
        let rotations = Dictionary(uniqueKeysWithValues: targets.map { ($0, degrees) })
        let result = try copyPages(of: doc, indices: Array(0..<doc.pageCount), rotations: rotations)
        try write(result, to: output)
        try validate(output, expectedPages: doc.pageCount)
    }
}
#endif
