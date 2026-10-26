import Foundation

/// Every failure a tool can report, each with a plain message for the user (never a raw
/// technical error) and whether "try again" makes sense.
public enum WaraqaError: Error, Equatable, Sendable {
    case cannotOpen(fileName: String)
    case passwordRequired
    case wrongPassword
    case notEncrypted
    case emptyDocument
    case noPagesSelected
    case cannotRemoveAllPages
    case invalidPageSelection(String)
    case unsupportedFile(fileName: String)
    case imageUnreadable(fileName: String)
    case fileTooLarge(limitBytes: Int64)
    case notEnoughStorage
    case writeFailed
    case cancelled
    case noTextFound
    case ocrLanguageUnavailable
    case serverNotConfigured
    case serverConsentRequired
    case offline
    case serverUnavailable
    case serverRejected(message: String)
    case timeout
    case conversionFailed
    case outputValidationFailed
    case aiNotConfigured
    case needsTwoFiles
    case nothingToRedact
    case missingOptions
    case passwordUnsupported

    public var message: LocalizedText {
        switch self {
        case .cannotOpen(let name):
            LocalizedText("تعذّر فتح الملف «\(name)». قد يكون تالفاً — جرّب أداة إصلاح PDF.",
                          "Couldn't open “\(name)”. It may be damaged — try Repair PDF.")
        case .passwordRequired:
            LocalizedText("هذا الملف محمي بكلمة مرور. أدخلها للمتابعة.", "This file is password-protected. Enter the password to continue.")
        case .wrongPassword:
            LocalizedText("كلمة المرور غير صحيحة.", "The password is incorrect.")
        case .notEncrypted:
            LocalizedText("هذا الملف غير محمي أصلاً.", "This file isn't password-protected.")
        case .emptyDocument:
            LocalizedText("الملف لا يحتوي على صفحات.", "The file has no pages.")
        case .noPagesSelected:
            LocalizedText("اختر صفحة واحدة على الأقل.", "Select at least one page.")
        case .cannotRemoveAllPages:
            LocalizedText("لا يمكن حذف كل الصفحات. أبقِ صفحة واحدة على الأقل.", "You can't remove every page. Keep at least one.")
        case .invalidPageSelection(let detail):
            LocalizedText("أرقام الصفحات غير صحيحة: \(detail)", "Invalid page numbers: \(detail)")
        case .unsupportedFile(let name):
            LocalizedText("نوع الملف «\(name)» غير مدعوم في هذه الأداة.", "“\(name)” isn't supported by this tool.")
        case .imageUnreadable(let name):
            LocalizedText("تعذّرت قراءة الصورة «\(name)».", "Couldn't read the image “\(name)”.")
        case .fileTooLarge(let limit):
            LocalizedText("الملف أكبر من الحد المسموح (\(ByteSize.format(limit, language: .arabic))).",
                          "The file is larger than the limit (\(ByteSize.format(limit))).")
        case .notEnoughStorage:
            LocalizedText("لا توجد مساحة كافية على الجهاز. احذف بعض الملفات ثم أعد المحاولة.",
                          "Not enough storage on this iPhone. Free some space and try again.")
        case .writeFailed:
            LocalizedText("تعذّر حفظ الملف الناتج.", "Couldn't save the result.")
        case .cancelled:
            LocalizedText("تم إلغاء العملية.", "Cancelled.")
        case .noTextFound:
            LocalizedText("لم يُعثر على نص في هذا الملف. إن كان ممسوحاً ضوئياً فاستخدم أداة OCR أولاً.",
                          "No text was found. If the file is scanned, run OCR first.")
        case .ocrLanguageUnavailable:
            LocalizedText("التعرف على هذه اللغة غير متاح على هذا الجهاز. يمكنك استخدام المعالجة عبر الخادم.",
                          "This language can't be recognized on this device. You can use server processing instead.")
        case .serverNotConfigured:
            LocalizedText("هذه الأداة تحتاج خادم المعالجة، وهو غير مفعّل في هذه النسخة.",
                          "This tool needs the processing server, which isn't enabled in this build.")
        case .serverConsentRequired:
            LocalizedText("هذه الأداة ترفع الملف إلى خادم المعالجة. يجب موافقتك أولاً.",
                          "This tool uploads the file to the processing server. Your consent is needed first.")
        case .offline:
            LocalizedText("لا يوجد اتصال بالإنترنت. هذه الأداة تحتاج اتصالاً.", "You're offline. This tool needs an internet connection.")
        case .serverUnavailable:
            LocalizedText("خادم المعالجة غير متاح الآن. أعد المحاولة بعد قليل.", "The processing server isn't available right now. Try again shortly.")
        case .serverRejected(let message):
            LocalizedText("رفض الخادم الطلب: \(message)", "The server declined the request: \(message)")
        case .timeout:
            LocalizedText("استغرقت العملية وقتاً أطول من المتوقع. أعد المحاولة.", "This took too long. Please try again.")
        case .conversionFailed:
            LocalizedText("تعذّر تحويل الملف. قد يكون تالفاً أو بتنسيق غير مدعوم.",
                          "Couldn't convert the file. It may be damaged or in an unsupported format.")
        case .outputValidationFailed:
            LocalizedText("الملف الناتج لم يجتز الفحص، لذا لم يُحفظ. أعد المحاولة.",
                          "The result failed validation, so it wasn't saved. Please try again.")
        case .aiNotConfigured:
            LocalizedText("أدوات الذكاء الاصطناعي غير مفعّلة على الخادم.", "AI tools aren't enabled on the server.")
        case .needsTwoFiles:
            LocalizedText("اختر ملفين للمقارنة.", "Choose two files to compare.")
        case .passwordUnsupported:
            LocalizedText("استخدم كلمة مرور من حروف إنجليزية وأرقام ورموز، بحد أقصى 32 خانة.",
                          "Use a password of English letters, digits and symbols, up to 32 characters.")
        case .missingOptions:
            LocalizedText("أكمل الخيارات المطلوبة أولاً.", "Complete the required options first.")
        case .nothingToRedact:
            LocalizedText("لم تحدد أي منطقة أو نص للتنقيح.", "Nothing was marked for redaction.")
        }
    }

    public var canRetry: Bool {
        switch self {
        case .offline, .serverUnavailable, .timeout, .writeFailed, .notEnoughStorage, .conversionFailed,
             .outputValidationFailed, .cancelled:
            true
        default:
            false
        }
    }
}

/// Size limits. On-device limits protect memory on older iPhones; the server limit matches the
/// backend's `MAX_UPLOAD_MB`.
public enum Limits {
    public static let maxOnDeviceBytes: Int64 = 500 * 1_000_000
    public static let maxUploadBytes: Int64 = 100 * 1_000_000
    public static let maxMergeFiles = 100
    public static let maxImages = 300
    /// Text sent to the AI tools is capped so a request always fits the model's context.
    public static let maxAICharacters = 400_000
}
