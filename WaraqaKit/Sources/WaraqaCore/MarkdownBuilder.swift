import Foundation

/// Builds Markdown from text lines extracted from a PDF (text + font size + boldness). The PDF
/// engine supplies the lines; the structure rules live here so they can be tested anywhere.
public enum MarkdownBuilder {
    public struct Line: Equatable, Sendable {
        public let text: String
        public let fontSize: Double
        public let isBold: Bool
        public let pageIndex: Int

        public init(text: String, fontSize: Double, isBold: Bool = false, pageIndex: Int = 0) {
            self.text = text
            self.fontSize = fontSize
            self.isBold = isBold
            self.pageIndex = pageIndex
        }
    }

    private static let bulletPrefixes: [String] = ["•", "●", "▪", "◦", "–", "- ", "* ", "·"]

    public static func build(_ lines: [Line]) -> String {
        let body = bodyFontSize(lines)
        var out: [String] = []
        var paragraph: [String] = []
        var lastPage = lines.first?.pageIndex ?? 0

        func flush() {
            if !paragraph.isEmpty {
                out.append(paragraph.joined(separator: " "))
                out.append("")
                paragraph.removeAll()
            }
        }

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if line.pageIndex != lastPage {
                flush()
                out.append("---")
                out.append("")
                lastPage = line.pageIndex
            }
            if text.isEmpty {
                flush()
                continue
            }
            if let level = headingLevel(line, body: body) {
                flush()
                out.append(String(repeating: "#", count: level) + " " + escape(text))
                out.append("")
                continue
            }
            if let item = listItem(text) {
                flush()
                out.append(item)
                continue
            }
            // A previous list item ends when ordinary text starts.
            if let last = out.last, last.hasPrefix("- ") || last.range(of: #"^\d+\. "#, options: .regularExpression) != nil,
               paragraph.isEmpty {
                out.append("")
            }
            paragraph.append(escape(text))
        }
        flush()

        while out.last == "" || out.last == "---" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    /// The most common font size, weighted by text length: the size of body text.
    static func bodyFontSize(_ lines: [Line]) -> Double {
        var weight: [Double: Int] = [:]
        for line in lines where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
            weight[(line.fontSize * 2).rounded() / 2, default: 0] += line.text.count
        }
        return weight.max { $0.value < $1.value }?.key ?? 12
    }

    static func headingLevel(_ line: Line, body: Double) -> Int? {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard text.count <= 120, !text.hasSuffix(".") || text.count < 40 else { return nil }
        let ratio = line.fontSize / max(body, 1)
        if ratio >= 1.6 { return 1 }
        if ratio >= 1.3 { return 2 }
        if ratio >= 1.12 { return 3 }
        if line.isBold, text.count <= 80, ratio >= 0.98 { return 4 }
        return nil
    }

    static func listItem(_ text: String) -> String? {
        for prefix in bulletPrefixes where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : "- " + escape(rest)
        }
        // "1." "1)" "١." numbered items
        let digitsNormalized = PageSelection.normalizeDigits(text)
        if let match = digitsNormalized.range(of: #"^(\d{1,3})[\.\)]\s+"#, options: .regularExpression) {
            let number = digitsNormalized[match].filter(\.isNumber)
            let rest = String(digitsNormalized[match.upperBound...])
            return "\(number). " + escape(rest)
        }
        return nil
    }

    /// Escapes characters that would otherwise turn plain text into Markdown syntax.
    static func escape(_ text: String) -> String {
        var s = ""
        for ch in text {
            if "\\`*_[]<>".contains(ch) { s.append("\\") }
            s.append(ch)
        }
        if s.hasPrefix("#") { s = "\\" + s }
        return s
    }
}
