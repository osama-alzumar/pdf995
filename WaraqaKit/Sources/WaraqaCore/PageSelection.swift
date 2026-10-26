import Foundation

/// A set of pages typed by the user, e.g. "1-3, 5, 9-" or "١-٣، ٥". Page numbers are 1-based in
/// text and 0-based in `indices`.
public struct PageSelection: Equatable, Sendable {
    public let ranges: [ClosedRange<Int>] // 1-based, as typed (open ends resolved)

    public enum ParseError: Error, Equatable, Sendable {
        case empty
        case invalidToken(String)
        case outOfRange(page: Int, pageCount: Int)
        case reversedRange(String)
    }

    public init(ranges: [ClosedRange<Int>]) {
        self.ranges = ranges
    }

    /// Sorted, de-duplicated 0-based page indices.
    public var indices: [Int] {
        Array(Set(ranges.flatMap { Array($0) })).sorted().map { $0 - 1 }
    }

    /// 0-based indices in the order the ranges were typed (duplicates kept). Used when the order
    /// matters, e.g. "3,1,2" for extraction into a new order.
    public var orderedIndices: [Int] {
        ranges.flatMap { Array($0) }.map { $0 - 1 }
    }

    public static func parse(_ text: String, pageCount: Int) throws -> PageSelection {
        let normalized = normalizeDigits(text)
            .replacingOccurrences(of: "،", with: ",")
            .replacingOccurrences(of: "؛", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        let tokens = normalized.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw ParseError.empty }

        var ranges: [ClosedRange<Int>] = []
        for token in tokens {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            switch parts.count {
            case 1:
                guard let page = Int(parts[0]) else { throw ParseError.invalidToken(token) }
                try check(page, pageCount)
                ranges.append(page...page)
            case 2:
                let start = parts[0].isEmpty ? 1 : Int(parts[0])
                let end = parts[1].isEmpty ? pageCount : Int(parts[1])
                guard let start, let end else { throw ParseError.invalidToken(token) }
                try check(start, pageCount)
                try check(end, pageCount)
                guard start <= end else { throw ParseError.reversedRange(token) }
                ranges.append(start...end)
            default:
                throw ParseError.invalidToken(token)
            }
        }
        return PageSelection(ranges: ranges)
    }

    /// Text for a set of 0-based indices, compacted into ranges: [0,1,2,4] → "1-3, 5".
    public static func describe(_ indices: [Int]) -> String {
        let pages = Array(Set(indices)).sorted().map { $0 + 1 }
        var parts: [String] = []
        var i = 0
        while i < pages.count {
            var j = i
            while j + 1 < pages.count, pages[j + 1] == pages[j] + 1 { j += 1 }
            parts.append(i == j ? "\(pages[i])" : "\(pages[i])-\(pages[j])")
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    private static func check(_ page: Int, _ pageCount: Int) throws {
        guard page >= 1, page <= pageCount else {
            throw ParseError.outOfRange(page: page, pageCount: pageCount)
        }
    }

    /// Converts Arabic-Indic (٠-٩) and Eastern Arabic-Indic (۰-۹) digits to ASCII.
    public static func normalizeDigits(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0x0660...0x0669: Character(UnicodeScalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9: Character(UnicodeScalar(scalar.value - 0x06F0 + 0x30)!)
            default: Character(scalar)
            }
        })
    }
}

/// How a document is split into several files.
public enum SplitMode: Equatable, Sendable {
    /// One file per page.
    case everyPage
    /// Consecutive chunks of N pages.
    case everyN(Int)
    /// One file per typed range, e.g. "1-3, 4-10".
    case ranges(PageSelection)

    /// Groups of 0-based page indices, one group per output file.
    public func groups(pageCount: Int) -> [[Int]] {
        switch self {
        case .everyPage:
            return (0..<pageCount).map { [$0] }
        case .everyN(let n):
            let size = max(1, n)
            return stride(from: 0, to: pageCount, by: size).map { start in
                Array(start..<min(start + size, pageCount))
            }
        case .ranges(let selection):
            return selection.ranges.map { range in range.map { $0 - 1 } }
        }
    }
}
