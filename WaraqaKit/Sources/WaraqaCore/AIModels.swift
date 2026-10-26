import Foundation

/// Request/response types for the AI endpoints, plus the client-side check that every quote
/// the model returns really appears in the document. Nothing unverified is shown as a fact.
public struct AIPage: Codable, Equatable, Sendable {
    public let page: Int // 1-based
    public let text: String
    public init(page: Int, text: String) {
        self.page = page
        self.text = text
    }

    /// Trims pages to the AI character budget, keeping page boundaries.
    public static func budgeted(_ pages: [AIPage], limit: Int = Limits.maxAICharacters) -> (pages: [AIPage], truncated: Bool) {
        var used = 0
        var result: [AIPage] = []
        for page in pages {
            let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if used + text.count > limit {
                let room = limit - used
                if room > 200 { result.append(AIPage(page: page.page, text: String(text.prefix(room)))) }
                return (result, true)
            }
            used += text.count
            result.append(AIPage(page: page.page, text: text))
        }
        return (result, false)
    }
}

public enum SummaryLength: String, Codable, CaseIterable, Sendable, Identifiable {
    case short, detailed
    public var id: String { rawValue }
    public var title: LocalizedText {
        self == .short ? LocalizedText("قصير", "Short") : LocalizedText("مفصّل", "Detailed")
    }
}

public struct Citation: Codable, Equatable, Sendable, Identifiable {
    public let page: Int
    public let quote: String
    public var verified: Bool
    public var id: String { "\(page)-\(quote)" }

    public init(page: Int, quote: String, verified: Bool = false) {
        self.page = page
        self.quote = quote
        self.verified = verified
    }

    enum CodingKeys: String, CodingKey { case page, quote, verified }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = try c.decode(Int.self, forKey: .page)
        quote = try c.decode(String.self, forKey: .quote)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
    }
}

public struct SummaryPoint: Codable, Equatable, Sendable, Identifiable {
    public let text: String
    public var citations: [Citation]
    public var id: String { text }
}

public struct SummarizeRequest: Codable, Sendable {
    public let pages: [AIPage]
    public let length: SummaryLength
    public let language: String
    public init(pages: [AIPage], length: SummaryLength, language: String) {
        self.pages = pages
        self.length = length
        self.language = language
    }
}

public struct SummarizeResponse: Codable, Sendable {
    public let overview: String
    public var points: [SummaryPoint]

    public init(overview: String, points: [SummaryPoint]) {
        self.overview = overview
        self.points = points
    }
}

public struct AskRequest: Codable, Sendable {
    public let pages: [AIPage]
    public let question: String
    public let language: String
    public init(pages: [AIPage], question: String, language: String) {
        self.pages = pages
        self.question = question
        self.language = language
    }
}

public struct AskResponse: Codable, Sendable {
    /// False when the document does not contain the answer; the app then says so plainly.
    public let found: Bool
    public let answer: String
    public var citations: [Citation]

    public init(found: Bool, answer: String, citations: [Citation]) {
        self.found = found
        self.answer = answer
        self.citations = citations
    }
}

public struct TranslateRequest: Codable, Sendable {
    public let pages: [AIPage]
    public let target: String
    public init(pages: [AIPage], target: String) {
        self.pages = pages
        self.target = target
    }
}

public struct TranslateResponse: Codable, Sendable {
    public let pages: [AIPage]
}

public struct TranslationLanguage: Identifiable, Hashable, Sendable {
    public let code: String
    public let name: LocalizedText
    public var id: String { code }

    public static let supported: [TranslationLanguage] = [
        .init(code: "ar", name: LocalizedText("العربية", "Arabic")),
        .init(code: "en", name: LocalizedText("الإنجليزية", "English")),
        .init(code: "fr", name: LocalizedText("الفرنسية", "French")),
        .init(code: "es", name: LocalizedText("الإسبانية", "Spanish")),
        .init(code: "de", name: LocalizedText("الألمانية", "German")),
        .init(code: "tr", name: LocalizedText("التركية", "Turkish")),
        .init(code: "ur", name: LocalizedText("الأردية", "Urdu")),
        .init(code: "id", name: LocalizedText("الإندونيسية", "Indonesian")),
        .init(code: "zh", name: LocalizedText("الصينية", "Chinese")),
    ]
}

public enum QuoteVerifier {
    /// Whitespace-, diacritic- and hamza-insensitive form used to compare quotes with the source.
    public static func canonical(_ text: String) -> String {
        ToolSearch.normalize(text)
            .unicodeScalars
            .filter { !CharacterSet.punctuationCharacters.contains($0) }
            .map(String.init).joined()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    public static func verify(_ citation: Citation, in pages: [AIPage]) -> Bool {
        let quote = canonical(citation.quote)
        guard quote.count >= 4 else { return false }
        if let page = pages.first(where: { $0.page == citation.page }), canonical(page.text).contains(quote) {
            return true
        }
        return false
    }

    /// Marks each citation as verified or not against the source pages.
    public static func check(_ citations: [Citation], in pages: [AIPage]) -> [Citation] {
        citations.map { c in
            var copy = c
            copy.verified = verify(c, in: pages)
            return copy
        }
    }
}
