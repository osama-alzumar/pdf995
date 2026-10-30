import SwiftUI
import StoreKit
import WaraqaCore

/// Plans: 3 free documents, then a one-document credit or Waraqa Plus (monthly / yearly).
/// Prices are the App Store's own localized prices for each product.
struct PlansView: View {
    @Environment(\.appLanguage) private var lang
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PurchaseStore.shared
    @ObservedObject private var quota = QuotaStore.shared
    var reason: ProtectionQuota.Denial?
    @State private var selected = PurchaseStore.ProductID.yearly
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let reason { NoteBox(systemImage: "info.circle", text: reasonText(reason), tint: Theme.accent) }
                    status
                    if store.products.isEmpty {
                        NoteBox(systemImage: "exclamationmark.triangle", text: lang.t(
                            "الخطط غير متاحة الآن. تأكد من الاتصال بالإنترنت ثم أعد المحاولة.",
                            "Plans aren't available right now. Check your connection and try again."), tint: Theme.warning)
                        SecondaryButton(title: lang.t("إعادة المحاولة", "Try again"), systemImage: "arrow.clockwise") {
                            Task { await store.loadProducts() }
                        }
                    }
                    plan(PurchaseStore.ProductID.yearly, lang.t("الاشتراك السنوي", "Yearly"),
                         lang.t("\(PlanRules.monthlyAllowance) مستنداً شهرياً، كل الأنماط والقوالب، والمشاركة الآمنة وفق سياسة الاستخدام — لمدة سنة.",
                                "\(PlanRules.monthlyAllowance) documents a month, every style and template, and secure sharing — for a year."))
                    plan(PurchaseStore.ProductID.monthly, lang.t("الاشتراك الشهري", "Monthly"),
                         lang.t("\(PlanRules.monthlyAllowance) مستنداً شهرياً، كل الأنماط والقوالب، والمشاركة الآمنة وفق سياسة الاستخدام.",
                                "\(PlanRules.monthlyAllowance) documents a month, every style and template, and secure sharing."))
                    plan(PurchaseStore.ProductID.credit, lang.t("حماية مستند واحد", "Protect one document"),
                         lang.t("مستند واحد حتى \(PlanRules.pagesPerDocument) صفحة. يُستخدم متى شئت ولا ينتهي.",
                                "One document up to \(PlanRules.pagesPerDocument) pages. Use it any time; it doesn't expire."))
                    PrimaryButton(title: store.purchasing ? lang.t("جارٍ الشراء…", "Purchasing…") : lang.t("متابعة", "Continue"),
                                  systemImage: "lock.shield", isEnabled: store.products[selected] != nil && !store.purchasing) { buy() }
                    if let message { Text(message).font(.app(.footnote)).foregroundStyle(Theme.secondaryText) }
                    Button(lang.t("استعادة المشتريات", "Restore purchases")) { Task { await store.restore() } }
                        .font(.app(.footnote, .bold)).frame(maxWidth: .infinity)
                    Text(lang.t("الاشتراك يتجدد تلقائياً ما لم يُلغَ قبل 24 ساعة على الأقل من نهاية الفترة، ويُدار من إعدادات حساب Apple. الأدوات المحلية الأخرى تبقى مجانية.",
                                "Subscriptions renew automatically unless cancelled at least 24 hours before the period ends, and are managed in your Apple account settings. The other on-device tools stay free."))
                        .font(.app(.caption)).foregroundStyle(Theme.secondaryText)
                    HStack {
                        Link(lang.t("شروط الاستخدام", "Terms of use"), destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        Spacer()
                        if let url = AppLinks.privacyPolicy { Link(lang.t("سياسة الخصوصية", "Privacy policy"), destination: url) }
                    }
                    .font(.app(.caption, .bold))
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background)
            .navigationTitle(lang.t("الخطط", "Plans"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(lang.t("إغلاق", "Close")) { dismiss() } } }
            .task { if store.products.isEmpty { await store.loadProducts() } }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch store.entitlement {
            case .subscribed(let renews, _):
                T("مشترك في ورقة بلس", "Waraqa Plus").font(.app(.headline))
                if let renews { Text(lang.t("يتجدد في \(renews.formatted(date: .abbreviated, time: .omitted))", "Renews \(renews.formatted(date: .abbreviated, time: .omitted))")).font(.app(.footnote)) }
            case .free:
                Text(lang.t("المستندات المجانية المتبقية: \(quota.quota.freeRemaining) من \(PlanRules.freeProtections)",
                            "Free documents left: \(quota.quota.freeRemaining) of \(PlanRules.freeProtections)")).font(.app(.subheadline, .bold))
            }
            if quota.quota.credits > 0 {
                Text(lang.t("رصيدك: \(quota.quota.credits) مستند", "Your credits: \(quota.quota.credits)")).font(.app(.footnote))
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func plan(_ id: String, _ title: String, _ detail: String) -> some View {
        let product = store.products[id]
        return Button { selected = id } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: selected == id ? "largecircle.fill.circle" : "circle").foregroundStyle(Theme.accent)
                    Text(title).font(.app(.body, .bold)).foregroundStyle(.primary)
                    Spacer()
                    Text(product?.displayPrice ?? "—").font(.app(.headline)).foregroundStyle(Theme.accent)
                }
                Text(detail).font(.app(.footnote)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected == id ? Theme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected == id ? .isSelected : [])
    }

    private func reasonText(_ reason: ProtectionQuota.Denial) -> String {
        switch reason {
        case .needsPurchase: lang.t("استخدمت مستنداتك المجانية الثلاثة. اختر خطة للمتابعة.", "You've used your 3 free documents. Choose a plan to continue.")
        case .tooManyPages(let limit): lang.t("المستند أطول من \(limit) صفحة. الاشتراك يشمل المستندات الأطول.", "The document is longer than \(limit) pages. The subscription covers longer documents.")
        case .monthlyLimitReached(let limit): lang.t("وصلت إلى \(limit) مستنداً هذا الشهر. يمكنك شراء مستند إضافي.", "You've reached \(limit) documents this month. You can buy an extra document.")
        }
    }

    private func buy() {
        Task {
            do {
                switch try await store.buy(selected) {
                case .success: message = lang.t("تم الشراء بنجاح.", "Purchase complete."); dismiss()
                case .pending: message = lang.t("الشراء بانتظار الموافقة.", "The purchase is pending approval.")
                case .cancelled: break
                }
            } catch {
                message = lang.t("تعذّر إتمام الشراء. لم يتم خصم أي مبلغ.", "The purchase couldn't be completed. You weren't charged.")
            }
        }
    }
}

enum AppLinks {
    static var privacyPolicy: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "WaraqaPrivacyPolicyURL") as? String,
              let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    static var supportEmail: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "WaraqaSupportEmail") as? String ?? ""
        return raw.contains("@") ? raw : nil
    }
}

/// "حسابي": plan, privacy and app settings. No account is needed for local protection.
struct AccountView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var store = PurchaseStore.shared
    @ObservedObject private var quota = QuotaStore.shared
    @ObservedObject private var server = ServerService.shared
    @ObservedObject private var lock = VaultLock.shared
    @AppStorage("smartSuggestion") private var smartSuggestion = true
    @AppStorage("showRecents") private var showRecents = true
    @State private var showPlans = false
    @State private var confirmWipe = false
    @State private var used: Int64 = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showPlans = true } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(planTitle).font(.app(.headline)).foregroundStyle(.white)
                            Text(planDetail).font(.app(.footnote)).foregroundStyle(.white.opacity(0.85))
                            Text(lang.t("عرض الخطط", "See plans")).font(.app(.footnote, .bold)).foregroundStyle(.white)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section(lang.t("الخصوصية والأمان", "Privacy & security")) {
                    Toggle(lang.t("قفل مستنداتي بـ \(lang.t(lock.biometryName))", "Lock My documents with \(lang.t(lock.biometryName))"),
                           isOn: Binding(get: { lock.lockEnabled }, set: { lock.lockEnabled = $0 }))
                    Toggle(lang.t("اقتراح ذكي على الجهاز", "On-device smart suggestion"), isOn: $smartSuggestion)
                    Toggle(lang.t("عرض المستندات الأخيرة في الرئيسية", "Show recent documents on Home"), isOn: $showRecents)
                    Toggle(lang.t("اسألني قبل رفع أي ملف لأدوات الخادم", "Ask before uploading for server tools"),
                           isOn: Binding(get: { !app.skipUploadNotice }, set: { app.skipUploadNotice = !$0 }))
                    LabeledContent(lang.t("خادم المعالجة والمشاركة", "Processing & sharing server"), value: serverStatus)
                }

                Section(lang.t("اللغة", "Language")) {
                    Picker(lang.t("لغة التطبيق", "App language"), selection: Binding(get: { app.language }, set: { app.setLanguage($0) })) {
                        Text("العربية").tag(AppLanguage.arabic)
                        Text("English").tag(AppLanguage.english)
                    }
                    .pickerStyle(.segmented)
                }

                Section(lang.t("التخزين", "Storage")) {
                    LabeledContent(lang.t("المساحة المستخدمة", "Space used"), value: ByteSize.format(used, language: lang))
                    Button(lang.t("حذف الملفات المؤقتة", "Delete temporary files")) {
                        FileStore.shared.clearTemporaryFiles()
                        VaultStore.shared.closeOpenedFiles()
                        ThumbCache.shared.clear()
                        used = FileStore.shared.storageUsed
                    }
                    Button(lang.t("حذف التوقيع المحفوظ", "Delete saved signature")) { SignatureStore.delete() }
                    Button(lang.t("حذف كل بياناتي من التطبيق", "Delete all my data in the app"), role: .destructive) { confirmWipe = true }
                }

                Section(lang.t("حول", "About")) {
                    Button(lang.t("استعادة المشتريات", "Restore purchases")) { Task { await store.restore() } }
                    if let url = AppLinks.privacyPolicy { Link(lang.t("سياسة الخصوصية", "Privacy policy"), destination: url) }
                    if let email = AppLinks.supportEmail, let url = URL(string: "mailto:\(email)") {
                        Link(lang.t("تواصل معنا", "Contact us"), destination: url)
                    }
                    LabeledContent(lang.t("الإصدار", "Version"), value: Bundle.main.versionString)
                    Text(lang.t("الحماية على الجهاز لا تحتاج حساباً. ورقة تطبيق مستقل لا يرتبط بأي جهة حكومية أو خدمة أخرى.",
                                "On-device protection needs no account. Waraqa is independent and not affiliated with any government body or other service."))
                        .font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                }
            }
            .font(.app(.body))
            .navigationTitle(lang.t("حسابي", "Account"))
            .sheet(isPresented: $showPlans) { PlansView() }
            .confirmationDialog(lang.t("حذف كل المستندات والملفات والمشاركات من هذا الجهاز؟", "Delete every document, file and share record on this iPhone?"),
                                isPresented: $confirmWipe, titleVisibility: .visible) {
                Button(lang.t("حذف الكل", "Delete everything"), role: .destructive) {
                    VaultStore.shared.deleteAll()
                    FileStore.shared.deleteAll()
                    for record in SharesStore.shared.records { SharesStore.shared.forget(record) }
                    SignatureStore.delete()
                    used = FileStore.shared.storageUsed
                }
            } message: {
                Text(lang.t("الروابط النشطة تبقى تعمل حتى انتهائها؛ ألغِها أولاً من «المشاركات» إن أردت.",
                            "Active links keep working until they expire; revoke them first in Shares if needed."))
            }
            .task {
                used = FileStore.shared.storageUsed
                await server.refresh()
            }
        }
    }

    private var planTitle: String {
        if case .subscribed = store.entitlement { return lang.t("ورقة بلس", "Waraqa Plus") }
        return lang.t("الخطة المجانية", "Free plan")
    }

    private var planDetail: String {
        if case .subscribed = store.entitlement { return lang.t("\(PlanRules.monthlyAllowance) مستنداً شهرياً", "\(PlanRules.monthlyAllowance) documents a month") }
        return lang.t("متبقٍ \(quota.quota.freeRemaining) من \(PlanRules.freeProtections) مستندات مجانية · رصيد \(quota.quota.credits)",
                      "\(quota.quota.freeRemaining) of \(PlanRules.freeProtections) free documents left · \(quota.quota.credits) credits")
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
