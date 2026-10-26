import Foundation

/// The two interface languages Waraqa ships with. Arabic is the primary language.
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case arabic = "ar"
    case english = "en"

    public var isRightToLeft: Bool { self == .arabic }

    /// Arabic unless the device prefers English.
    public static func deviceDefault(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard let first = preferred.first?.lowercased() else { return .arabic }
        return first.hasPrefix("en") ? .english : .arabic
    }
}

/// A user-facing string in both languages. Kept in code (not string catalogs) so the core can be
/// tested on any platform and the app can switch language without a restart.
public struct LocalizedText: Hashable, Sendable, Codable {
    public let ar: String
    public let en: String

    public init(_ ar: String, _ en: String) {
        self.ar = ar
        self.en = en
    }

    public func resolve(_ language: AppLanguage) -> String {
        language == .arabic ? ar : en
    }
}
