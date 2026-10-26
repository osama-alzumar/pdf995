import Foundation

/// Word-level difference between two texts (Myers' O(ND) algorithm), used by Compare PDF.
public enum TextDiff {
    public enum Kind: String, Sendable, Codable {
        case equal, inserted, deleted
    }

    public struct Segment: Equatable, Sendable {
        public let kind: Kind
        public let words: [String]
        public var text: String { words.joined(separator: " ") }
    }

    public struct Summary: Equatable, Sendable {
        public let insertedWords: Int
        public let deletedWords: Int
        public let unchangedWords: Int
        public var isIdentical: Bool { insertedWords == 0 && deletedWords == 0 }
        /// Share of the old text that is unchanged, 0...100.
        public var similarityPercent: Int {
            let total = unchangedWords + max(insertedWords, deletedWords)
            return total == 0 ? 100 : Int((Double(unchangedWords) / Double(total) * 100).rounded())
        }
    }

    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    /// Compares word sequences. `maxEdits` bounds the work on completely different inputs; past
    /// it the result degrades to "everything deleted, everything inserted", which is still correct.
    public static func diff(_ old: [String], _ new: [String], maxEdits: Int = 20_000) -> [Segment] {
        let n = old.count, m = new.count
        if n == 0 && m == 0 { return [] }
        if n == 0 { return [Segment(kind: .inserted, words: new)] }
        if m == 0 { return [Segment(kind: .deleted, words: old)] }

        let max = n + m
        let limit = min(max, maxEdits)
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        var found = false

        outer: for d in 0...limit {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[k - 1 + max] < v[k + 1 + max]) {
                    x = v[k + 1 + max]
                } else {
                    x = v[k - 1 + max] + 1
                }
                var y = x - k
                while x < n, y < m, old[x] == new[y] {
                    x += 1
                    y += 1
                }
                v[k + max] = x
                if x >= n, y >= m {
                    found = true
                    break outer
                }
                k += 2
            }
        }
        guard found else {
            return [Segment(kind: .deleted, words: old), Segment(kind: .inserted, words: new)]
        }

        // Backtrack to recover the edit script.
        var ops: [(Kind, String)] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && v[k - 1 + max] < v[k + 1 + max]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = v[prevK + max]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                ops.append((.equal, old[x - 1]))
                x -= 1
                y -= 1
            }
            if d > 0 {
                if x == prevX {
                    ops.append((.inserted, new[y - 1]))
                } else {
                    ops.append((.deleted, old[x - 1]))
                }
            }
            x = prevX
            y = prevY
        }
        ops.reverse()

        var segments: [Segment] = []
        for (kind, word) in ops {
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1] = Segment(kind: kind, words: last.words + [word])
            } else {
                segments.append(Segment(kind: kind, words: [word]))
            }
        }
        return segments
    }

    public static func diff(old: String, new: String) -> [Segment] {
        diff(words(old), words(new))
    }

    public static func summary(_ segments: [Segment]) -> Summary {
        var ins = 0, del = 0, eq = 0
        for s in segments {
            switch s.kind {
            case .equal: eq += s.words.count
            case .inserted: ins += s.words.count
            case .deleted: del += s.words.count
            }
        }
        return Summary(insertedWords: ins, deletedWords: del, unchangedWords: eq)
    }
}

/// Page-by-page comparison result for two documents.
public struct DocumentComparison: Sendable {
    public struct Page: Sendable, Identifiable {
        public let id: Int // 0-based page index
        public let segments: [TextDiff.Segment]
        public let summary: TextDiff.Summary
    }

    public let pages: [Page]
    public let oldPageCount: Int
    public let newPageCount: Int

    public var changedPages: [Page] { pages.filter { !$0.summary.isIdentical } }

    public var total: TextDiff.Summary {
        TextDiff.summary(pages.flatMap(\.segments))
    }

    /// Pages are compared in order; a page missing on one side counts as fully inserted/deleted.
    public init(oldPages: [String], newPages: [String]) {
        let count = max(oldPages.count, newPages.count)
        var result: [Page] = []
        for i in 0..<count {
            let old = i < oldPages.count ? oldPages[i] : ""
            let new = i < newPages.count ? newPages[i] : ""
            let segments = TextDiff.diff(old: old, new: new)
            result.append(Page(id: i, segments: segments, summary: TextDiff.summary(segments)))
        }
        pages = result
        oldPageCount = oldPages.count
        newPageCount = newPages.count
    }
}
