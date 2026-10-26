import SwiftUI
import PDFEngine
import WaraqaCore

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var server = ServerService.shared
    @ObservedObject private var store = FileStore.shared
    @State private var used: Int64 = 0
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section(lang.t("اللغة", "Language")) {
                    Picker(lang.t("لغة التطبيق", "App language"), selection: Binding(get: { app.language }, set: { app.setLanguage($0) })) {
                        Text("العربية").tag(AppLanguage.arabic)
                        Text("English").tag(AppLanguage.english)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    LabeledContent(lang.t("المعالجة على الجهاز", "On-device processing"), value: lang.t("مفعلة دائماً", "Always on"))
                    LabeledContent(lang.t("خادم المعالجة", "Processing server"), value: serverStatus)
                    Toggle(lang.t("اسألني قبل كل رفع", "Ask me before every upload"), isOn: Binding(
                        get: { !app.skipUploadNotice }, set: { app.skipUploadNotice = !$0 }))
                    LabeledContent(lang.t("التعرف على العربية محلياً", "On-device Arabic OCR"),
                                   value: OCREngine.supportsArabic() ? lang.t("متاح", "Available") : lang.t("غير متاح في هذا الإصدار", "Not on this iOS version"))
                } header: {
                    Text(lang.t("الخصوصية", "Privacy"))
                } footer: {
                    Text(lang.t(
                        "معظم الأدوات تعمل على جهازك ولا يغادر الملف هاتفك. الأدوات التي تحمل رمز السحابة ترفع الملف فقط بعد موافقتك، ويُحذف من الخادم خلال \(server.retentionMinutes) دقائق كحد أقصى.",
                        "Most tools run on your iPhone and the file never leaves it. Tools marked with a cloud upload only after you agree, and files are deleted from the server within \(server.retentionMinutes) minutes at most."))
                }

                Section(lang.t("التخزين", "Storage")) {
                    LabeledContent(lang.t("المساحة المستخدمة", "Space used"), value: ByteSize.format(used, language: lang))
                    Button(cleared ? lang.t("تم التنظيف ✓", "Cleaned ✓") : lang.t("حذف الملفات المؤقتة", "Delete temporary files")) {
                        store.clearTemporaryFiles()
                        ThumbCache.shared.clear()
                        cleared = true
                        used = store.storageUsed
                    }
                    Button(lang.t("حذف التوقيع المحفوظ", "Delete saved signature"), role: .destructive) { SignatureStore.delete() }
                }

                Section(lang.t("حول", "About")) {
                    LabeledContent(lang.t("الإصدار", "Version"), value: Bundle.main.versionString)
                    if let url = URL(string: Bundle.main.object(forInfoDictionaryKey: "WaraqaPrivacyPolicyURL") as? String ?? ""), url.scheme == "https" {
                        Link(lang.t("سياسة الخصوصية", "Privacy policy"), destination: url)
                    }
                    if let url = URL(string: "mailto:" + (Bundle.main.object(forInfoDictionaryKey: "WaraqaSupportEmail") as? String ?? "")),
                       (Bundle.main.object(forInfoDictionaryKey: "WaraqaSupportEmail") as? String ?? "").contains("@") {
                        Link(lang.t("تواصل معنا", "Contact us"), destination: url)
                    }
                    Text(lang.t("ورقة تطبيق مستقل، لا يرتبط بأي خدمة أو علامة تجارية أخرى.",
                                "Waraqa is an independent app, not affiliated with any other service or brand."))
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
            .navigationTitle(lang.t("الإعدادات", "Settings"))
            .task {
                used = store.storageUsed
                await server.refresh()
            }
        }
    }

    private var serverStatus: String {
        switch server.availability {
        case .notConfigured: lang.t("غير مفعّل في هذه النسخة", "Not enabled in this build")
        case .unknown: lang.t("جارٍ التحقق…", "Checking…")
        case .available: lang.t("متصل", "Connected")
        case .unreachable: lang.t("غير متاح الآن", "Unavailable now")
        }
    }
}

extension Bundle {
    var versionString: String {
        let v = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
