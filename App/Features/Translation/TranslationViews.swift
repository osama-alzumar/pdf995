import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import PDFEngine
import WaraqaCore

/// Home card for the certified translation service.
struct TranslationCard: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var store = TranslationsStore.shared
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: "character.book.closed.fill")
                    .font(.app(.title2, .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 54, height: 54)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 3) {
                    T("ترجمة معتمدة", "Certified translation").font(.app(.headline, .bold)).foregroundStyle(.primary)
                    Text(lang.t("أرسل مستندك ويترجمه فريق متخصص — \(TranslationPricing.pricePerPageSAR) ريال للصفحة",
                                "Send your document to our expert team — SAR \(TranslationPricing.pricePerPageSAR) per page"))
                        .font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if store.unseen > 0 {
                    Text("\(store.unseen)").font(.app(.caption, .bold)).foregroundStyle(.white)
                        .frame(minWidth: 24, minHeight: 24).background(Theme.danger, in: Capsule())
                }
                Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
            }
            .padding(16)
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("translation.open")
    }
}

/// "Certified translation": the user's orders and a button for a new one.
struct TranslationHubView: View {
    @Environment(\.appLanguage) private var lang
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TranslationsStore.shared
    @State private var ordering = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    PrimaryButton(title: lang.t("اطلب ترجمة", "Order a translation"), systemImage: "plus") { ordering = true }
                        .accessibilityIdentifier("translation.new")
                    if !store.records.isEmpty {
                        SectionTitle(text: lang.t("طلباتي", "My orders"))
                        ForEach(store.records) { record in
                            NavigationLink(value: record.id) { TranslationRow(record: record) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background)
            .navigationTitle(lang.t("ترجمة معتمدة", "Certified translation"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in TranslationOrderDetail(id: id) }
            .navigationDestination(isPresented: $ordering) { TranslationOrderForm { ordering = false } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(lang.t("إغلاق", "Close")) { dismiss() } }
            }
            .refreshable { await store.refresh() }
            .task { await store.refresh() }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            step("doc.badge.arrow.up", lang.t("أرسل المستند (PDF أو صور أو Word) واختر اللغة.", "Send the document (PDF, photos or Word) and choose the language."))
            step("message", lang.t("يراجعه فريق الترجمة ويتواصل معك على واتساب لتأكيد السعر والدفع.",
                                   "The team reviews it and contacts you on WhatsApp to confirm the price and payment."))
            step("checkmark.seal", lang.t("تصلك الترجمة هنا في التطبيق جاهزة للتنزيل والمشاركة.",
                                          "The translation arrives here in the app, ready to download and share."))
            Text(lang.t("السعر: \(TranslationPricing.pricePerPageSAR) ريال للصفحة.", "Price: SAR \(TranslationPricing.pricePerPageSAR) per page."))
                .font(.app(.subheadline, .bold)).foregroundStyle(Theme.accent)
        }
        .padding(16)
        .card()
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.app(.subheadline)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TranslationRow: View {
    @Environment(\.appLanguage) private var lang
    let record: TranslationRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t("طلب \(record.status.number)", "Order \(record.status.number)") + " · " + record.title)
                    .font(.app(.subheadline, .bold)).lineLimit(1)
                Text(lang.t(record.status.state.title)).font(.app(.footnote)).foregroundStyle(color)
                Text(lang.t("\(record.status.pages) صفحة · \(record.status.priceSAR) ريال", "\(record.status.pages) pages · SAR \(record.status.priceSAR)"))
                    .font(.app(.caption)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if !record.seen { Circle().fill(Theme.danger).frame(width: 10, height: 10).accessibilityLabel(lang.t("جديد", "New")) }
            Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
        }
        .padding(14)
        .card()
    }

    private var color: Color {
        switch record.status.state {
        case .ready: Theme.success
        case .cancelled: Theme.danger
        case .awaitingPayment: Theme.warning
        default: Theme.accent
        }
    }
}

struct TranslationOrderDetail: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var store = TranslationsStore.shared
    let id: String
    @State private var downloading = false
    @State private var resultURL: URL?
    @State private var previewURL: URL?
    @State private var error: WaraqaError?

    var body: some View {
        ScrollView {
            if let record = store.records.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lang.t("طلب رقم \(record.status.number)", "Order no. \(record.status.number)")).font(.app(.title3, .bold))
                        Text(lang.t(record.status.state.title)).font(.app(.headline)).foregroundStyle(Theme.accent)
                        Text(record.title).font(.app(.subheadline)).foregroundStyle(Theme.secondaryText)
                        Divider()
                        info(lang.t("اللغة", "Language"), language(record.status.sourceLanguage) + " ← " + language(record.status.targetLanguage))
                        info(lang.t("الصفحات", "Pages"), "\(record.status.pages)")
                        info(lang.t("السعر", "Price"), lang.t("\(record.status.priceSAR) ريال", "SAR \(record.status.priceSAR)")
                             + (record.status.paid ? lang.t(" — مدفوع", " — paid") : ""))
                    }
                    .padding(16).card()
                    if !record.status.message.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(lang.t("رسالة من فريق الترجمة", "Message from the translation team"), systemImage: "bubble.left.fill")
                                .font(.app(.subheadline, .bold))
                            Text(record.status.message).font(.app(.body)).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16).card()
                    }
                    if record.status.state == .ready && record.status.hasResult {
                        if let resultURL {
                            PrimaryButton(title: lang.t("عرض الترجمة", "View translation"), systemImage: "doc.text.magnifyingglass") {
                                previewURL = resultURL
                            }
                            ShareLink(item: resultURL) {
                                Label(lang.t("مشاركة", "Share"), systemImage: "square.and.arrow.up")
                                    .font(.app(.body, .bold)).frame(maxWidth: .infinity, minHeight: 50)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            PrimaryButton(title: downloading ? lang.t("جارٍ التنزيل…", "Downloading…") : lang.t("تنزيل الترجمة", "Download translation"),
                                          systemImage: "arrow.down.circle", isEnabled: !downloading) { download() }
                        }
                    } else if !record.status.state.isFinished {
                        NoteBox(systemImage: "clock", text: lang.t(
                            "سيتواصل معك فريق الترجمة على واتساب لتأكيد السعر وطريقة الدفع. ستظهر الترجمة هنا عند جاهزيتها.",
                            "The translation team will contact you on WhatsApp to confirm the price and payment. The translation appears here when ready."))
                    }
                }
                .padding(Theme.gutter)
                .onAppear { store.markSeen(id) }
            }
        }
        .background(Theme.background)
        .navigationTitle(lang.t("تفاصيل الطلب", "Order details"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .quickLookPreview($previewURL)
        .alert(lang.t("تنبيه", "Notice"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(lang.t("حسناً", "OK"), role: .cancel) {}
        } message: { Text(error.map { lang.t($0.message) } ?? "") }
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(Theme.secondaryText); Spacer(); Text(value) }.font(.app(.subheadline))
    }

    private func language(_ code: String) -> String {
        CertifiedLanguage(rawValue: code).map { lang.t($0.title) } ?? code
    }

    private func download() {
        downloading = true
        Task {
            do { resultURL = try await store.result(for: id); previewURL = resultURL } catch { self.error = ToolRunner.map(error) }
            downloading = false
        }
    }
}

/// New order: documents, languages, contact details, price, consent, send.
struct TranslationOrderForm: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var store = TranslationsStore.shared
    let done: () -> Void

    @AppStorage("translation.name") private var name = ""
    @AppStorage("translation.phone") private var phone = ""
    @AppStorage("translation.email") private var email = ""
    @State private var files: [PickedFile] = []
    @State private var pages: [UUID: Int] = [:]
    @State private var source: CertifiedLanguage = .en
    @State private var target: CertifiedLanguage = .ar
    @State private var notes = ""
    @State private var agreed = false
    @State private var showImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showScanner = false
    @State private var sending = false
    @State private var progress = 0.0
    @State private var error: WaraqaError?
    @State private var sent: CreateTranslationResponse?

    private var pageCount: Int { files.reduce(0) { $0 + (pages[$1.id] ?? 1) } }
    private var hasWordFile: Bool { files.contains { $0.fileExtension == "docx" } }
    private var validPhone: Bool { PhoneNumber.normalized(phone) != nil }
    private var canSend: Bool {
        !files.isEmpty && name.trimmingCharacters(in: .whitespaces).count >= 2 && validPhone && agreed && !sending
            && (source != target || source == .other) && pageCount <= TranslationPricing.maxPages
    }

    var body: some View {
        ScrollView {
            if let sent {
                success(sent)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    documents
                    languages
                    contact
                    summary
                    PrimaryButton(title: sending ? lang.t("جارٍ الإرسال… \(Int(progress * 100))٪", "Sending… \(Int(progress * 100))%")
                                                 : lang.t("أرسل الطلب", "Send order"),
                                  systemImage: "paperplane.fill", isEnabled: canSend) { send() }
                        .accessibilityIdentifier("translation.send")
                }
                .padding(Theme.gutter)
            }
        }
        .background(Theme.background)
        .navigationTitle(lang.t("طلب ترجمة معتمدة", "Certified translation order"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            add(urls.compactMap { try? FileStore.shared.importFile($0) })
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var picked: [PickedFile] = []
                for (n, item) in items.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let file = try? FileStore.shared.importData(data, name: lang.t("صورة", "Photo") + " \(files.count + n + 1).jpg") {
                        picked.append(file)
                    }
                }
                photoItems = []
                add(picked)
            }
        }
        .sheet(isPresented: $showScanner) {
            DocumentScannerView { images in
                showScanner = false
                let picked = images.enumerated().compactMap { n, image -> PickedFile? in
                    guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
                    return try? FileStore.shared.importData(data, name: lang.t("مسح", "Scan") + " \(files.count + n + 1).jpg")
                }
                add(picked)
            }
            .ignoresSafeArea()
        }
        .alert(lang.t("تنبيه", "Notice"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(lang.t("حسناً", "OK"), role: .cancel) {}
        } message: { Text(error.map { lang.t($0.message) } ?? "") }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-WaraqaSampleFiles"), files.isEmpty {
                add(DebugSamples.files(for: ToolCatalog.info(.merge)))
            }
            #endif
        }
    }

    private var importTypes: [UTType] {
        [.pdf, .image, UTType(filenameExtension: "docx") ?? .data]
    }

    // MARK: Sections

    private var documents: some View {
        VStack(alignment: .leading, spacing: 10) {
            T("المستندات", "Documents").font(.app(.subheadline, .bold))
            ForEach(files) { file in
                HStack {
                    Image(systemName: file.isPDF ? "doc.richtext" : (file.fileExtension == "docx" ? "doc.text" : "photo"))
                        .foregroundStyle(Theme.accent)
                    Text(file.name).font(.app(.subheadline)).lineLimit(1)
                    Spacer()
                    Text(lang.t("\(pages[file.id] ?? 1) صفحة", "\(pages[file.id] ?? 1) p.")).font(.app(.caption)).foregroundStyle(Theme.secondaryText)
                    Button { files.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel(lang.t("إزالة", "Remove"))
                }
                .padding(10)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
            if files.count < TranslationPricing.maxFiles {
                HStack(spacing: 8) {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: TranslationPricing.maxFiles - files.count, matching: .images) {
                        sourceButton(lang.t("الصور", "Photos"), "photo.on.rectangle")
                    }
                    Button { showImporter = true } label: { sourceButton(lang.t("الملفات", "Files"), "folder") }
                    if DocumentScannerView.isSupported {
                        Button { showScanner = true } label: { sourceButton(lang.t("تصوير", "Scan"), "camera") }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .card()
    }

    private func sourceButton(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.app(.title3))
            Text(title).font(.app(.caption, .bold))
        }
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 10) {
            T("اللغة", "Language").font(.app(.subheadline, .bold))
            Picker(lang.t("من", "From"), selection: $source) {
                ForEach(CertifiedLanguage.allCases) { Text(lang.t($0.title)).tag($0) }
            }
            Picker(lang.t("إلى", "To"), selection: $target) {
                ForEach(CertifiedLanguage.allCases) { Text(lang.t($0.title)).tag($0) }
            }
            if source == target && source != .other {
                T("اختر لغتين مختلفتين.", "Choose two different languages.").font(.app(.footnote)).foregroundStyle(Theme.danger)
            }
            TextField(lang.t("ملاحظات للمترجم (اختياري)، مثل: الاسم بالإنجليزية كما في الجواز",
                             "Notes for the translator (optional), e.g. the name as in the passport"), text: $notes, axis: .vertical)
                .lineLimit(1...4)
                .padding(12)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        }
        .padding(16)
        .card()
    }

    private var contact: some View {
        VStack(alignment: .leading, spacing: 10) {
            T("بيانات التواصل", "Contact details").font(.app(.subheadline, .bold))
            TextField(lang.t("الاسم", "Name"), text: $name)
                .textContentType(.name)
                .padding(12).background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                .accessibilityIdentifier("translation.name")
            TextField(lang.t("رقم الواتساب، مثل 05xxxxxxxx", "WhatsApp number, e.g. 05xxxxxxxx"), text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .environment(\.layoutDirection, .leftToRight)
                .padding(12).background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                .accessibilityIdentifier("translation.phone")
            if !phone.isEmpty && !validPhone {
                T("رقم الجوال غير صحيح.", "The mobile number is not valid.").font(.app(.footnote)).foregroundStyle(Theme.danger)
            }
            TextField(lang.t("البريد الإلكتروني (اختياري)", "Email (optional)"), text: $email)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never).textContentType(.emailAddress)
                .environment(\.layoutDirection, .leftToRight)
                .padding(12).background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        }
        .padding(16)
        .card()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                T("التكلفة التقديرية", "Estimated cost").font(.app(.subheadline, .bold))
                Spacer()
                Text(lang.t("\(TranslationPricing.total(pages: pageCount)) ريال", "SAR \(TranslationPricing.total(pages: pageCount))"))
                    .font(.app(.title3, .bold)).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("translation.price")
            }
            Text(lang.t("\(pageCount) صفحة × \(TranslationPricing.pricePerPageSAR) ريال. يؤكد الفريق العدد النهائي بعد مراجعة الملف\(hasWordFile ? "، وصفحات ملفات Word تُقدَّر من عدد الكلمات" : "").",
                        "\(pageCount) pages × SAR \(TranslationPricing.pricePerPageSAR). The team confirms the final count after reviewing the file\(hasWordFile ? "; Word pages are estimated from the word count" : "")."))
                .font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
            Text(lang.t("الدفع مباشرة لفريق الترجمة بعد تأكيد السعر على واتساب، ولا يبدأ العمل قبل موافقتك.",
                        "You pay the translation team directly after the price is confirmed on WhatsApp; work starts only after you agree."))
                .font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
            Toggle(isOn: $agreed) {
                Text(lang.t("أوافق على رفع المستندات لفريق ترجمة ورقة واستخدام اسمي ورقمي للتواصل بشأن هذا الطلب فقط. تُحذف الملفات بعد ٣٠ يوماً من التسليم.",
                            "I agree to upload these documents to the Waraqa translation team and to be contacted about this order only. Files are deleted 30 days after delivery."))
                    .font(.app(.footnote))
            }
            .accessibilityIdentifier("translation.agree")
        }
        .padding(16)
        .card()
    }

    private func success(_ sent: CreateTranslationResponse) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(Theme.success)
            Text(lang.t("تم إرسال طلبك رقم \(sent.order.number)", "Order no. \(sent.order.number) sent")).font(.app(.title3, .bold))
            Text(lang.t("\(sent.order.pages) صفحة · \(sent.order.priceSAR) ريال", "\(sent.order.pages) pages · SAR \(sent.order.priceSAR)"))
                .font(.app(.headline)).foregroundStyle(Theme.accent)
            Text(lang.t("سيتواصل معك فريق الترجمة على واتساب لتأكيد السعر والدفع. تابع حالة الطلب واستلم الترجمة من «طلباتي».",
                        "The translation team will contact you on WhatsApp to confirm the price and payment. Follow the order and get the translation in “My orders”."))
                .font(.app(.subheadline)).multilineTextAlignment(.center).foregroundStyle(Theme.secondaryText)
            PrimaryButton(title: lang.t("تم", "Done"), systemImage: "checkmark", action: done)
        }
        .padding(24)
        .card()
        .padding(Theme.gutter)
    }

    // MARK: Logic

    private func add(_ picked: [PickedFile]) {
        for file in picked.prefix(TranslationPricing.maxFiles - files.count) {
            files.append(file)
            if file.isPDF {
                if let count = try? PDFEngine.pageCount(file.url, password: file.password) {
                    pages[file.id] = count
                } else {
                    error = .cannotOpen(fileName: file.name)
                    files.removeAll { $0.id == file.id }
                }
            } else {
                pages[file.id] = 1
            }
        }
    }

    private func send() {
        sending = true
        progress = 0
        let parts = files.map { MultipartBody.FilePart(fileName: $0.name, contentType: Self.contentType($0), url: $0.url) }
        let title = files.first.map { FileNaming.stem(of: $0.name) } ?? ""
        Task {
            do {
                let report: @Sendable (Double) -> Void = { value in Task { @MainActor in progress = value } }
                let response = try await ServerService.shared.withApprovedUpload { client in
                    try await client.createTranslation(files: parts, name: name.trimmingCharacters(in: .whitespaces), phone: phone, email: email,
                                                       source: source, target: target, notes: notes, progress: report)
                }
                store.add(response, title: title)
                sent = response
            } catch {
                self.error = ToolRunner.map(error)
            }
            sending = false
        }
    }

    static func contentType(_ file: PickedFile) -> String {
        switch file.fileExtension {
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "heic": "image/heic"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        default: "image/jpeg"
        }
    }
}
