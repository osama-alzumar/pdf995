import Foundation

/// Output file names: derived from the input, never overwriting the original, safe for every
/// file system the user may save to (Files, iCloud Drive, AirDrop, WhatsApp, mail).
public enum FileNaming {
    /// "عقد الإيجار.pdf" + suffix "مضغوط" → "عقد الإيجار - مضغوط.pdf"
    public static func output(for inputName: String, suffix: String, extension ext: String) -> String {
        let base = sanitize(stem(of: inputName))
        let cleanSuffix = sanitize(suffix)
        let name = cleanSuffix.isEmpty ? base : "\(base) - \(cleanSuffix)"
        return "\(name.isEmpty ? "Waraqa" : name).\(ext)"
    }

    /// Name for part `index` (1-based) of a split.
    public static func part(for inputName: String, index: Int, extension ext: String) -> String {
        let base = sanitize(stem(of: inputName))
        return "\(base.isEmpty ? "Waraqa" : base) - \(index).\(ext)"
    }

    public static func stem(of name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return last }
        return String(last[..<dot])
    }

    public static func fileExtension(of name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return "" }
        return String(last[last.index(after: dot)...]).lowercased()
    }

    /// Removes characters that break paths or share targets, collapses whitespace and limits
    /// length (by characters, so Arabic names are not cut in the middle of a letter).
    public static func sanitize(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return String(trimmed.prefix(120))
    }

    /// A name that does not exist yet in `existing`: "a.pdf" → "a (2).pdf".
    public static func unique(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ext = fileExtension(of: name)
        let base = stem(of: name)
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }
}

public enum ByteSize {
    /// "1.4 MB" / "١٫٤ م.ب" style text. Uses decimal units like the Files app.
    public static func format(_ bytes: Int64, language: AppLanguage = .english) -> String {
        let units = language == .arabic ? ["بايت", "ك.ب", "م.ب", "ج.ب"] : ["bytes", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let number = unit == 0 ? String(Int(value)) : String(format: value < 10 ? "%.1f" : "%.0f", value)
        return "\(number) \(units[unit])"
    }
}

/// Before/after numbers shown after compression. `savedPercent` is never negative: when the
/// "compressed" file came out larger the app keeps the original instead.
public struct CompressionReport: Equatable, Sendable {
    public let originalBytes: Int64
    public let compressedBytes: Int64

    public init(originalBytes: Int64, compressedBytes: Int64) {
        self.originalBytes = originalBytes
        self.compressedBytes = compressedBytes
    }

    public var isSmaller: Bool { compressedBytes < originalBytes }

    public var savedBytes: Int64 { max(0, originalBytes - compressedBytes) }

    public var savedPercent: Int {
        guard originalBytes > 0, isSmaller else { return 0 }
        return Int((Double(savedBytes) / Double(originalBytes) * 100).rounded())
    }
}

public enum CompressionLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Keeps quality: re-encodes images as JPEG at high quality, keeps resolution.
    case light
    /// Recommended: screen-resolution images, JPEG. Text stays text.
    case recommended
    /// Smallest: every page is re-rendered as a reduced image. Text is no longer selectable.
    case strong

    public var id: String { rawValue }

    public var title: LocalizedText {
        switch self {
        case .light: LocalizedText("خفيف", "Light")
        case .recommended: LocalizedText("موصى به", "Recommended")
        case .strong: LocalizedText("أقصى ضغط", "Maximum")
        }
    }

    public var detail: LocalizedText {
        switch self {
        case .light: LocalizedText("جودة عالية وتوفير أقل", "High quality, smaller savings")
        case .recommended: LocalizedText("توازن بين الجودة والحجم", "Good quality, good savings")
        case .strong: LocalizedText("أصغر حجم، والنص يصبح صورة غير قابلة للتحديد", "Smallest size; text becomes an image")
        }
    }
}

/// Guesses the most useful tool for files the user opened or shared into the app.
public enum FileSuggestion {
    public static func tools(forFileNames names: [String]) -> [ToolID] {
        let exts = names.map { FileNaming.fileExtension(of: $0) }
        guard !exts.isEmpty else { return [] }
        let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
        if exts.allSatisfy({ images.contains($0) }) { return [.imagesToPDF] }
        if exts.allSatisfy({ ["doc", "docx", "odt", "rtf", "txt"].contains($0) }) { return [.wordToPDF] }
        if exts.allSatisfy({ ["ppt", "pptx", "odp"].contains($0) }) { return [.powerPointToPDF] }
        if exts.allSatisfy({ ["xls", "xlsx", "ods", "csv"].contains($0) }) { return [.excelToPDF] }
        if exts.allSatisfy({ ["html", "htm", "webarchive"].contains($0) }) { return [.htmlToPDF] }
        if exts.allSatisfy({ $0 == "pdf" }) {
            return exts.count > 1 ? [.merge, .compress] : [.compress, .pdfToWord, .sign, .organize]
        }
        return []
    }
}
