import Foundation

// MARK: - Watermark protection spec

/// How the protection mark is laid out on each page.
public enum ProtectionStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// One large slanted line across the middle of the page.
    case diagonal
    /// The text repeated over the whole page.
    case tiled
    /// A bordered stamp with recipient, purpose and date. Deliberately not styled like an
    /// official seal, and it says so in its last line.
    case stamp
    /// A small line at the bottom of each page.
    case small
    /// Dense repetition plus a diagonal line, for the strongest deterrent.
    case intense

    public var id: String { rawValue }

    public var title: LocalizedText {
        switch self {
        case .diagonal: LocalizedText("قطرية", "Diagonal")
        case .tiled: LocalizedText("متكررة", "Repeated")
        case .stamp: LocalizedText("ختم", "Stamp")
        case .small: LocalizedText("صغيرة", "Small")
        case .intense: LocalizedText("مكثفة", "Intense")
        }
    }

    public var detail: LocalizedText {
        switch self {
        case .diagonal: LocalizedText("نص مائل عبر منتصف المستند", "Slanted text across the middle")
        case .tiled: LocalizedText("تكرار النص على كامل المستند", "Text repeated over the page")
        case .stamp: LocalizedText("ختم بالجهة والغرض والتاريخ", "Stamp with recipient, purpose and date")
        case .small: LocalizedText("علامة صغيرة أسفل المستند", "Small line at the bottom")
        case .intense: LocalizedText("حماية مكثفة مع بقاء المستند مقروءاً", "Dense marks, still readable")
        }
    }
}

/// Why the document is being shared. Presets fill in the watermark sentence.
public enum ProtectionPurpose: String, CaseIterable, Codable, Sendable, Identifiable {
    case identity, realEstate, bank, booking, employment, government, other

    public var id: String { rawValue }

    public var title: LocalizedText {
        switch self {
        case .identity: LocalizedText("التحقق من الهوية", "Identity verification")
        case .realEstate: LocalizedText("إجراءات عقارية", "Real-estate procedure")
        case .bank: LocalizedText("التحقق البنكي", "Bank verification")
        case .booking: LocalizedText("إتمام الحجز", "Completing a booking")
        case .employment: LocalizedText("التوظيف", "Employment")
        case .government: LocalizedText("معاملة لدى جهة", "An official transaction")
        case .other: LocalizedText("غرض آخر", "Other purpose")
        }
    }
}

public struct ProtectionSpec: Codable, Hashable, Sendable {
    public var recipient: String = ""
    public var purpose: ProtectionPurpose = .identity
    /// Free text used when `purpose` is `.other`.
    public var customPurpose: String = ""
    /// When not empty, replaces the generated sentence entirely.
    public var customText: String = ""
    public var style: ProtectionStyle = .diagonal
    public var colorHex: String = "#1E3A6E"
    public var opacity: Double = 0.30
    public var angleDegrees: Double = 30
    /// Base font size in points for an A4-sized page; scaled to the page.
    public var fontSize: Double = 22
    /// Space between repeated marks: 0.6 (tight) … 2.0 (loose).
    public var spacing: Double = 1.0
    public var includeDate: Bool = true
    public var date: Date = Date()
    public var language: AppLanguage = .arabic

    public init() {}

    public var purposeText: String {
        if purpose == .other {
            let custom = customPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? purpose.title.resolve(language) : custom
        }
        return purpose.title.resolve(language)
    }

    public var recipientText: String {
        let r = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? (language == .arabic ? "الجهة المستلمة" : "the recipient") : r
    }

    public var dateText: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    /// The sentence written on the document.
    public var sentence: String {
        let custom = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        var text: String
        if !custom.isEmpty {
            text = custom
        } else if language == .arabic {
            text = "مخصص لـ\(recipientText) — \(purposeText) فقط — غير صالح لأي استخدام آخر"
        } else {
            text = "For \(recipientText) — \(purposeText) only — not valid for any other use"
        }
        if includeDate { text += " — " + dateText }
        return text
    }

    /// Shorter text for repeated marks.
    public var shortText: String {
        let custom = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = custom.isEmpty ? "\(recipientText) · \(purposeText)" : custom
        if includeDate { text += " · " + dateText }
        return text
    }

    /// Lines of the stamp style. The last line makes clear it is not an official stamp.
    public var stampLines: [String] {
        var lines: [String] = []
        if language == .arabic {
            lines.append("نسخة مقيّدة الاستخدام")
            lines.append("الجهة: \(recipientText)")
            lines.append("الغرض: \(purposeText)")
            if includeDate { lines.append("التاريخ: \(dateText)") }
            lines.append("ليست وثيقة رسمية ولا تمثل اعتماداً من أي جهة")
        } else {
            lines.append("Restricted-use copy")
            lines.append("For: \(recipientText)")
            lines.append("Purpose: \(purposeText)")
            if includeDate { lines.append("Date: \(dateText)") }
            lines.append("Not an official document or endorsement")
        }
        return lines
    }

    /// Clamps values coming from sliders or decoded data into safe ranges.
    public var normalized: ProtectionSpec {
        var s = self
        s.opacity = min(max(opacity, 0.08), 0.9)
        s.angleDegrees = min(max(angleDegrees, -90), 90)
        s.fontSize = min(max(fontSize, 8), 72)
        s.spacing = min(max(spacing, 0.6), 2.0)
        s.recipient = String(recipient.prefix(80))
        s.customPurpose = String(customPurpose.prefix(80))
        s.customText = String(customText.prefix(200))
        return s
    }

    /// Ready-made wording the user can pick and edit.
    public static func presetSentences(recipient: String, language: AppLanguage = .arabic) -> [String] {
        let r = recipient.trimmingCharacters(in: .whitespaces).isEmpty ? "[الجهة]" : recipient
        return [
            "نسخة مخصصة للتحقق من الهوية فقط",
            "مخصص لـ\(r) وغير صالح لأي استخدام آخر",
            "نسخة مقدمة لـ\(r)",
            "مخصص لإتمام إجراءات الحجز",
            "مخصص للتحقق البنكي",
        ]
    }
}

// MARK: - Sensitive data detection

/// Finds sensitive values in recognized text so the app can suggest areas to hide.
/// Works on plain strings (one OCR line at a time), so it is fully testable; the device maps
/// matches back to image boxes.
public enum SensitiveDataDetector {
    public enum Kind: String, CaseIterable, Codable, Sendable, Identifiable {
        case nationalID, iban, phone, birthDate, address, cardNumber, email, date
        public var id: String { rawValue }

        public var title: LocalizedText {
            switch self {
            case .nationalID: LocalizedText("رقم الهوية / الإقامة", "ID / Iqama number")
            case .iban: LocalizedText("رقم الآيبان", "IBAN")
            case .phone: LocalizedText("رقم الجوال", "Phone number")
            case .birthDate: LocalizedText("تاريخ الميلاد", "Date of birth")
            case .address: LocalizedText("العنوان", "Address")
            case .cardNumber: LocalizedText("رقم بطاقة / حساب", "Card / account number")
            case .email: LocalizedText("البريد الإلكتروني", "Email")
            case .date: LocalizedText("تاريخ", "Date")
            }
        }

        /// Selected for hiding by default (the user can change every one).
        public var hiddenByDefault: Bool {
            switch self {
            case .nationalID, .iban, .cardNumber, .phone, .birthDate: true
            case .address, .email, .date: false
            }
        }
    }

    public struct Match: Equatable, Sendable {
        public let kind: Kind
        /// Range in the original line (String indices are not Sendable-friendly, so offsets).
        public let offset: Int
        public let length: Int
        public let text: String
        /// True when the whole line should be hidden (labels like "Address: …").
        public let wholeLine: Bool
    }

    static let patterns: [(Kind, String)] = [
        (.iban, #"\bSA\d{2}(?:[ ]?[0-9A-Z]{4}){4}[ ]?[0-9A-Z]{2,4}\b"#),
        (.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        (.cardNumber, #"\b(?:\d{4}[ -]?){3}\d{4}\b"#),
        (.phone, #"(?:\+?966[ -]?|0)5\d(?:[ -]?\d){7}\b"#),
        (.nationalID, #"\b[12]\d{9}\b"#),
        (.date, #"\b\d{1,4}[/\-.]\d{1,2}[/\-.]\d{1,4}\b"#),
    ]

    static let birthKeywords = ["تاريخ الميلاد", "تاريخ الولادة", "الميلاد", "date of birth", "birth date", "dob"]
    static let addressKeywords = ["العنوان", "عنوان", "حي ", "شارع", "ص.ب", "ص ب", "الرمز البريدي", "address", "street", "p.o. box"]

    /// Arabic-Indic digits → ASCII, so the same patterns cover both scripts.
    public static func normalize(_ text: String) -> String {
        PageSelection.normalizeDigits(text)
    }

    public static func detect(in line: String) -> [Match] {
        let text = normalize(line)
        let lower = text.lowercased()
        var matches: [Match] = []
        var taken: [NSRange] = []
        let ns = text as NSString

        if birthKeywords.contains(where: { lower.contains($0) }) {
            return [Match(kind: .birthDate, offset: 0, length: ns.length, text: line, wholeLine: true)]
        }
        if addressKeywords.contains(where: { lower.contains($0) }) {
            return [Match(kind: .address, offset: 0, length: ns.length, text: line, wholeLine: true)]
        }
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for result in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = result.range
                if taken.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
                // A bare 10-digit value counts as an ID only if it is not part of a longer number.
                taken.append(r)
                matches.append(Match(kind: kind, offset: r.location, length: r.length, text: ns.substring(with: r), wholeLine: false))
            }
        }
        return matches.sorted { $0.offset < $1.offset }
    }
}

// MARK: - Document type suggestion (on device, keyword based)

public enum DocumentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case nationalID, passport, driverLicense, certificate, bankStatement, contract, other
    public var id: String { rawValue }

    public var title: LocalizedText {
        switch self {
        case .nationalID: LocalizedText("هوية", "ID card")
        case .passport: LocalizedText("جواز سفر", "Passport")
        case .driverLicense: LocalizedText("رخصة قيادة", "Driver's license")
        case .certificate: LocalizedText("شهادة", "Certificate")
        case .bankStatement: LocalizedText("كشف حساب", "Bank statement")
        case .contract: LocalizedText("عقد", "Contract")
        case .other: LocalizedText("مستند شخصي", "Personal document")
        }
    }

    public var suggestedPurpose: ProtectionPurpose {
        switch self {
        case .nationalID, .passport, .driverLicense: .identity
        case .bankStatement: .bank
        case .contract: .realEstate
        case .certificate: .employment
        case .other: .other
        }
    }

    public var suggestedStyle: ProtectionStyle {
        switch self {
        case .nationalID, .passport, .driverLicense: .tiled
        case .bankStatement: .stamp
        case .contract, .certificate: .diagonal
        case .other: .diagonal
        }
    }

    /// Suggested vault folder.
    public var folder: VaultFolder {
        switch self {
        case .nationalID, .passport, .driverLicense: .identities
        case .certificate: .certificates
        case .bankStatement: .financial
        case .contract: .contracts
        case .other: .other
        }
    }
}

public enum DocumentClassifier {
    static let keywords: [(DocumentKind, [String])] = [
        (.passport, ["جواز سفر", "جواز", "passport", "p<sau", "nationality"]),
        (.driverLicense, ["رخصة قيادة", "رخصة سير", "driving licence", "driving license", "driver license"]),
        (.nationalID, ["الهوية الوطنية", "بطاقة الهوية", "رقم الهوية", "هوية مقيم", "إقامة", "national id", "identity card", "id no", "iqama"]),
        (.bankStatement, ["كشف حساب", "رقم الحساب", "الرصيد", "آيبان", "ايبان", "iban", "account statement", "balance"]),
        (.contract, ["عقد", "الطرف الأول", "الطرف الثاني", "المؤجر", "المستأجر", "contract", "agreement", "party"]),
        (.certificate, ["شهادة", "يشهد", "تخرج", "certificate", "certify", "diploma"]),
    ]

    /// The most likely kind with a confidence 0…1; `.other` when nothing matches.
    public static func classify(_ text: String) -> (kind: DocumentKind, confidence: Double) {
        let lower = ToolSearch.normalize(text)
        var best: (DocumentKind, Int) = (.other, 0)
        for (kind, words) in keywords {
            let hits = words.filter { lower.contains(ToolSearch.normalize($0)) }.count
            if hits > best.1 { best = (kind, hits) }
        }
        guard best.1 > 0 else { return (.other, 0) }
        return (best.0, min(1, 0.4 + 0.2 * Double(best.1)))
    }
}

// MARK: - Vault folders

public enum VaultFolder: String, CaseIterable, Codable, Sendable, Identifiable {
    case identities, certificates, financial, contracts, other
    public var id: String { rawValue }

    public var title: LocalizedText {
        switch self {
        case .identities: LocalizedText("هوياتي", "My IDs")
        case .certificates: LocalizedText("شهاداتي", "Certificates")
        case .financial: LocalizedText("مستنداتي المالية", "Financial")
        case .contracts: LocalizedText("عقودي", "Contracts")
        case .other: LocalizedText("مستندات أخرى", "Other")
        }
    }

    public var symbol: String {
        switch self {
        case .identities: "person.text.rectangle"
        case .certificates: "rosette"
        case .financial: "banknote"
        case .contracts: "signature"
        case .other: "folder"
        }
    }
}

// MARK: - Plans and quota

/// The commercial rules, kept in one place so prices and limits can change without touching
/// the screens. Prices are shown from StoreKit (the App Store's localized price), never typed.
public enum PlanRules {
    public static let freeProtections = 3
    public static let monthlyAllowance = 30
    /// Pages included in one "document" for a pay-per-use credit.
    public static let pagesPerDocument = 20
    /// Days the PDF tools are free from the first use; then they need Waraqa Plus.
    public static let toolTrialDays = 3
}

public enum Entitlement: Equatable, Sendable, Codable {
    case free
    case subscribed(renews: Date?, monthlyAllowance: Int)
}

/// Decides whether one more document may be protected, and what it costs.
public struct ProtectionQuota: Equatable, Sendable, Codable {
    public var freeUsed: Int
    public var credits: Int
    /// Protections used in the current subscription month, keyed "yyyy-MM".
    public var monthlyUsed: [String: Int]

    public init(freeUsed: Int = 0, credits: Int = 0, monthlyUsed: [String: Int] = [:]) {
        self.freeUsed = freeUsed
        self.credits = credits
        self.monthlyUsed = monthlyUsed
    }

    public enum Source: Equatable, Sendable {
        case free(remainingAfter: Int)
        case subscription(remainingAfter: Int)
        case credit(remainingAfter: Int)
    }

    public enum Denial: Error, Equatable, Sendable {
        case needsPurchase
        case tooManyPages(limit: Int)
        case monthlyLimitReached(limit: Int)
    }

    static func monthKey(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "Asia/Riyadh")!, from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public var freeRemaining: Int { max(0, PlanRules.freeProtections - freeUsed) }

    /// What would pay for the next protection, without consuming it.
    public func check(entitlement: Entitlement, pages: Int, now: Date = Date()) -> Result<Source, Denial> {
        if case .subscribed(_, let allowance) = entitlement {
            let used = monthlyUsed[Self.monthKey(now)] ?? 0
            if used < allowance { return .success(.subscription(remainingAfter: allowance - used - 1)) }
            if credits > 0 { return creditSource(pages: pages) }
            return .failure(.monthlyLimitReached(limit: allowance))
        }
        if freeRemaining > 0 { return .success(.free(remainingAfter: freeRemaining - 1)) }
        if credits > 0 { return creditSource(pages: pages) }
        return .failure(.needsPurchase)
    }

    private func creditSource(pages: Int) -> Result<Source, Denial> {
        guard pages <= PlanRules.pagesPerDocument else { return .failure(.tooManyPages(limit: PlanRules.pagesPerDocument)) }
        return .success(.credit(remainingAfter: credits - 1))
    }

    /// Records one protection. Call only after the protected file was written and checked.
    public mutating func consume(_ source: Source, now: Date = Date()) {
        switch source {
        case .free: freeUsed += 1
        case .subscription: monthlyUsed[Self.monthKey(now), default: 0] += 1
        case .credit: credits = max(0, credits - 1)
        }
    }
}

// MARK: - Secure share links

public enum ShareDuration: String, CaseIterable, Codable, Sendable, Identifiable {
    case tenMinutes, oneHour, oneDay, sevenDays
    public var id: String { rawValue }

    public var seconds: Int {
        switch self {
        case .tenMinutes: 600
        case .oneHour: 3600
        case .oneDay: 86_400
        case .sevenDays: 604_800
        }
    }

    public var title: LocalizedText {
        switch self {
        case .tenMinutes: LocalizedText("10 دقائق", "10 minutes")
        case .oneHour: LocalizedText("ساعة", "1 hour")
        case .oneDay: LocalizedText("24 ساعة", "24 hours")
        case .sevenDays: LocalizedText("7 أيام", "7 days")
        }
    }
}

public enum ShareState: String, Codable, Sendable {
    case active, expired, revoked, exhausted

    public var title: LocalizedText {
        switch self {
        case .active: LocalizedText("نشط", "Active")
        case .expired: LocalizedText("منتهي", "Expired")
        case .revoked: LocalizedText("ملغى", "Revoked")
        case .exhausted: LocalizedText("استُنفدت مرات الفتح", "Views used up")
        }
    }
}

public struct CreateShareResponse: Codable, Sendable {
    public let id: String
    public let url: String
    public let ownerToken: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, url
        case ownerToken = "owner_token"
        case expiresAt = "expires_at"
    }
}

public struct ShareStatus: Codable, Sendable, Equatable {
    public let id: String
    public let state: ShareState
    public let opens: Int
    public let maxViews: Int
    public let lastOpenedAt: Date?
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, state, opens
        case maxViews = "max_views"
        case lastOpenedAt = "last_opened_at"
        case expiresAt = "expires_at"
    }
}
