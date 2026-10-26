import Foundation

/// Search over the tool catalog that tolerates how people actually type Arabic: with or without
/// hamza, taa marbuta, alef maqsura, diacritics, tatweel, and in either language.
public enum ToolSearch {
    public static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.lowercased().unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640: // harakat, superscript alef, tatweel
                continue
            case 0x0622, 0x0623, 0x0625, 0x0671: // آ أ إ ٱ → ا
                result.unicodeScalars.append("\u{0627}")
            case 0x0629: // ة → ه
                result.unicodeScalars.append("\u{0647}")
            case 0x0649: // ى → ي
                result.unicodeScalars.append("\u{064A}")
            case 0x0624: // ؤ → و
                result.unicodeScalars.append("\u{0648}")
            case 0x0626: // ئ → ي
                result.unicodeScalars.append("\u{064A}")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tools whose name, description or keywords contain every word of the query. Results whose
    /// title matches come first; catalog order is kept otherwise.
    public static func search(_ query: String, in tools: [ToolInfo] = ToolCatalog.all) -> [ToolInfo] {
        let words = normalize(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }

        var scored: [(ToolInfo, Int, Int)] = []
        for (index, tool) in tools.enumerated() {
            let title = normalize(tool.title.ar + " " + tool.title.en)
            let haystack = title + " " + normalize(
                tool.subtitle.ar + " " + tool.subtitle.en + " " + tool.keywords.joined(separator: " ") + " " + tool.id.rawValue
            )
            guard words.allSatisfy({ haystack.contains($0) }) else { continue }
            let titleHits = words.filter { title.contains($0) }.count
            scored.append((tool, titleHits, index))
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }
}
