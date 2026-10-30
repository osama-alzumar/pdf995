import Foundation

// MARK: - Certified translation (a human service by the Waraqa team)

public enum TranslationPricing {
    /// Shown before sending; the server counts the pages itself and its quote is final.
    public static let pricePerPageSAR = 10
    public static let maxFiles = 10
    public static let maxPages = 200

    public static func total(pages: Int) -> Int { max(0, pages) * pricePerPageSAR }
}

public enum CertifiedLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case ar, en, fr, tr, ur, es, de, zh, id, other
    public var id: String { rawValue }

    public var title: LocalizedText {
        switch self {
        case .ar: LocalizedText("العربية", "Arabic")
        case .en: LocalizedText("الإنجليزية", "English")
        case .fr: LocalizedText("الفرنسية", "French")
        case .tr: LocalizedText("التركية", "Turkish")
        case .ur: LocalizedText("الأردية", "Urdu")
        case .es: LocalizedText("الإسبانية", "Spanish")
        case .de: LocalizedText("الألمانية", "German")
        case .zh: LocalizedText("الصينية", "Chinese")
        case .id: LocalizedText("الإندونيسية", "Indonesian")
        case .other: LocalizedText("لغة أخرى", "Other language")
        }
    }
}

public enum TranslationState: String, Codable, Sendable, CaseIterable {
    case received, awaitingPayment = "awaiting_payment", inProgress = "in_progress", ready, cancelled

    public var title: LocalizedText {
        switch self {
        case .received: LocalizedText("تم الاستلام — قيد المراجعة", "Received — under review")
        case .awaitingPayment: LocalizedText("بانتظار الدفع", "Awaiting payment")
        case .inProgress: LocalizedText("قيد الترجمة", "Being translated")
        case .ready: LocalizedText("الترجمة جاهزة", "Translation ready")
        case .cancelled: LocalizedText("ملغي", "Cancelled")
        }
    }

    public var isFinished: Bool { self == .ready || self == .cancelled }
}

public struct TranslationOrderStatus: Codable, Sendable, Hashable {
    public let id: String
    public let number: Int
    public let state: TranslationState
    public let pages: Int
    public let priceSAR: Int
    public let sourceLanguage: String
    public let targetLanguage: String
    public let message: String
    public let paid: Bool
    public let hasResult: Bool
    public let resultName: String?
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, number, state, pages, message, paid
        case priceSAR = "price_sar"
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
        case hasResult = "has_result"
        case resultName = "result_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct CreateTranslationResponse: Codable, Sendable {
    public let order: TranslationOrderStatus
    public let ownerToken: String

    enum CodingKeys: String, CodingKey { case ownerToken = "owner_token" }

    public init(from decoder: Decoder) throws {
        order = try TranslationOrderStatus(from: decoder)
        ownerToken = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .ownerToken)
    }

    public func encode(to encoder: Encoder) throws {
        try order.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ownerToken, forKey: .ownerToken)
    }
}

/// Mobile numbers as the team will use them on WhatsApp (international digits, no "+").
public enum PhoneNumber {
    public static func normalized(_ text: String) -> String? {
        let western = text.map { ch -> Character in
            if let v = ch.unicodeScalars.first?.value, (0x0660...0x0669).contains(v) {
                return Character(String(v - 0x0660))
            }
            return ch
        }
        var digits = String(western.filter(\.isASCII).filter(\.isNumber))
        if digits.hasPrefix("00") { digits.removeFirst(2) }
        if digits.hasPrefix("05") && digits.count == 10 { digits = "966" + digits.dropFirst() }
        return (9...15).contains(digits.count) ? digits : nil
    }
}

// MARK: - Free trial of the PDF tools

/// The PDF tools are free for the first `PlanRules.toolTrialDays` days after the first use;
/// after that they are part of Waraqa Plus. (Protection has its own 3 free documents.)
public struct ToolTrial: Equatable, Sendable, Codable {
    public let started: Date

    public init(started: Date) { self.started = started }

    public func isActive(now: Date = Date()) -> Bool {
        now < started.addingTimeInterval(TimeInterval(PlanRules.toolTrialDays) * 86_400)
    }

    /// Whole days left, counting a started day as one (3, 2, 1, then 0 = ended).
    public func daysLeft(now: Date = Date()) -> Int {
        let end = started.addingTimeInterval(TimeInterval(PlanRules.toolTrialDays) * 86_400)
        let seconds = end.timeIntervalSince(now)
        return seconds <= 0 ? 0 : Int((seconds / 86_400).rounded(.up))
    }

    public func allowsTools(_ entitlement: Entitlement, now: Date = Date()) -> Bool {
        if case .subscribed = entitlement { return true }
        return isActive(now: now)
    }
}
