import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFEngine
import WaraqaCore

/// Full-screen "Protect your document" journey.
struct ProtectFlowView: View {
    @Environment(\.appLanguage) private var lang
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow: ProtectFlow
    @ObservedObject private var purchases = PurchaseStore.shared
    @State private var showPlans = false

    init(language: AppLanguage, files: [PickedFile] = []) {
        _flow = StateObject(wrappedValue: ProtectFlow(language: language, files: files))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch flow.step {
                case .pick: ProtectPickView(flow: flow)
                case .edit: ProtectEditorView(flow: flow)
                case .hide: ProtectHideView(flow: flow)
                case .result: ProtectResultView(flow: flow) { dismiss() }
                }
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(flow.step == .result ? lang.t("تم", "Done") : lang.t("إغلاق", "Close")) {
                        flow.reset()
                        dismiss()
                    }
                }
                if flow.step == .hide {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { flow.step = .edit } label: { Image(systemName: "chevron.backward") }
                            .accessibilityLabel(lang.t("رجوع", "Back"))
                    }
                }
            }
            .overlay {
                if flow.working && flow.step != .result {
                    ProgressView(value: flow.progress > 0 ? flow.progress : nil) {
                        T("جارٍ التجهيز على جهازك…", "Preparing on your iPhone…")
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .padding(40)
                }
            }
            .alert(lang.t("تنبيه", "Notice"), isPresented: Binding(get: { flow.error != nil }, set: { if !$0 { flow.error = nil } })) {
                Button(lang.t("حسناً", "OK"), role: .cancel) {}
            } message: { Text(flow.error.map { lang.t($0.message) } ?? "") }
            .onChange(of: flow.needsPurchase) { _, denial in if denial != nil { showPlans = true } }
            .sheet(isPresented: $showPlans, onDismiss: { flow.needsPurchase = nil }) {
                PlansView(reason: flow.needsPurchase)
            }
        }
    }

    private var title: String {
        switch flow.step {
        case .pick: lang.t("احمِ مستندك", "Protect a document")
        case .edit: lang.t("العلامة المائية", "Watermark")
        case .hide: lang.t("إخفاء البيانات", "Hide data")
        case .result: lang.t("النسخة المحمية", "Protected copy")
        }
    }
}

// MARK: - Step 1: pick

struct ProtectPickView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject var flow: ProtectFlow
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showScanner = false
    @State private var showImporter = false
    @State private var importTypes: [UTType] = [.pdf]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(lang.t("اختر المستند الذي تريد حمايته. تبقى النسخة الأصلية كما هي دون تعديل.",
                            "Choose the document to protect. The original stays exactly as it is."))
                    .font(.app(.subheadline)).foregroundStyle(Theme.secondaryText)
                PhotosPicker(selection: $photoItems, maxSelectionCount: 20, matching: .images) {
                    sourceRow(lang.t("من الصور", "From Photos"), lang.t("صورة هوية أو شهادة", "A photo of an ID or certificate"), "photo.on.rectangle")
                }
                .buttonStyle(.plain)
                if DocumentScannerView.isSupported {
                    Button { showScanner = true } label: {
                        sourceRow(lang.t("التصوير بالكاميرا", "Scan with camera"), lang.t("مسح مع تصحيح الحواف", "Edge-corrected scan"), "camera")
                    }
                    .buttonStyle(.plain)
                }
                Button { importTypes = [.pdf]; showImporter = true } label: {
                    sourceRow(lang.t("ملف PDF", "PDF file"), lang.t("يدعم الصفحات المتعددة", "Multi-page supported"), "doc.richtext")
                }
                .buttonStyle(.plain)
                Button { importTypes = [.pdf, .image]; showImporter = true } label: {
                    sourceRow(lang.t("من تطبيق الملفات", "From Files"), lang.t("iCloud Drive وغيره", "iCloud Drive and more"), "folder")
                }
                .buttonStyle(.plain)
                NoteBox(systemImage: "lock.iphone", text: lang.t(
                    "تتم الحماية على جهازك بالكامل؛ لا يُرفع المستند إلى أي خادم.",
                    "Protection happens entirely on your iPhone; nothing is uploaded."))
            }
            .padding(Theme.gutter)
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var files: [PickedFile] = []
                for (n, item) in items.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let file = try? FileStore.shared.importData(data, name: lang.t("مستند", "Document") + " \(n + 1).jpg") {
                        files.append(file)
                    }
                }
                photoItems = []
                await flow.load(files)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let files = urls.compactMap { try? FileStore.shared.importFile($0) }
            let pdfs = files.filter(\.isPDF)
            Task { await flow.load(pdfs.isEmpty ? files : [pdfs[0]]) }
        }
        .sheet(isPresented: $showScanner) {
            DocumentScannerView { images in
                showScanner = false
                let files = images.enumerated().compactMap { n, image -> PickedFile? in
                    guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
                    return try? FileStore.shared.importData(data, name: lang.t("مسح", "Scan") + " \(n + 1).jpg")
                }
                Task { await flow.load(files) }
            }
            .ignoresSafeArea()
        }
    }

    private func sourceRow(_ title: String, _ hint: String, _ symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.app(.title3, .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 48, height: 48)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(.body, .bold)).foregroundStyle(.primary)
                Text(hint).font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(minHeight: 72)
        .card()
        .contentShape(Rectangle())
    }
}

// MARK: - Step 2: customize

struct ProtectEditorView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject var flow: ProtectFlow
    @ObservedObject private var purchases = PurchaseStore.shared
    @State private var showCustomText = false

    private let colors = ["#1E3A6E", "#B42318", "#475467", "#067647", "#6941C6", "#111111"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                previewCard
                if let kind = flow.analysis?.kind, kind != .other, UserDefaults.standard.object(forKey: "smartSuggestion") as? Bool ?? true {
                    suggestion(kind)
                }
                field
                purposes
                textOptions
                styles
                appearance
            }
            .padding(Theme.gutter)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onChange(of: flow.spec) { _, _ in flow.schedulePreview() }
        .onChange(of: flow.previewPage) { _, _ in flow.schedulePreview(immediate: true) }
    }

    private var previewCard: some View {
        VStack(spacing: 8) {
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                if let image = flow.preview {
                    Image(uiImage: image).resizable().scaledToFit().padding(8)
                        .accessibilityLabel(lang.t("معاينة المستند المحمي", "Preview of the protected document"))
                } else {
                    ProgressView()
                }
                if flow.previewing {
                    ProgressView().padding(8).background(.thinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10)
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            if flow.pageCount > 1 {
                Stepper(value: $flow.previewPage, in: 0...(flow.pageCount - 1)) {
                    Text(lang.t("معاينة الصفحة \(flow.previewPage + 1) من \(flow.pageCount)",
                                "Previewing page \(flow.previewPage + 1) of \(flow.pageCount)")).font(.app(.footnote))
                }
            }
        }
    }

    private func suggestion(_ kind: DocumentKind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(lang.t("اقتراح ذكي على جهازك: يبدو أنه «\(lang.t(kind.title))». نقترح الغرض «\(lang.t(kind.suggestedPurpose.title))» ونمط «\(lang.t(kind.suggestedStyle.title))».",
                            "On-device suggestion: this looks like a \(lang.t(kind.title)). Try “\(lang.t(kind.suggestedPurpose.title))” with the “\(lang.t(kind.suggestedStyle.title))” style."))
                    .font(.app(.footnote))
                Button(lang.t("طبّق الاقتراح", "Apply suggestion")) { flow.applySuggestion() }
                    .font(.app(.footnote, .bold))
            }
        }
        .padding(12)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            T("الجهة المستلمة", "Recipient").font(.app(.subheadline, .bold))
            TextField(lang.t("مثال: مكتب الأمل العقاري", "e.g. Hope Real Estate"), text: $flow.spec.recipient)
                .font(.app(.body))
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius).stroke(Theme.line))
        }
    }

    private var purposes: some View {
        VStack(alignment: .leading, spacing: 8) {
            T("الغرض من المشاركة", "Purpose").font(.app(.subheadline, .bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ProtectionPurpose.allCases) { p in
                        chip(lang.t(p.title), selected: flow.spec.purpose == p) { flow.spec.purpose = p }
                    }
                }
            }
            if flow.spec.purpose == .other {
                TextField(lang.t("اكتب الغرض", "Type the purpose"), text: $flow.spec.customPurpose)
                    .font(.app(.body))
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
        }
    }

    private var textOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                T("نص العلامة", "Mark text").font(.app(.subheadline, .bold))
                Spacer()
                Menu {
                    ForEach(ProtectionSpec.presetSentences(recipient: flow.spec.recipient), id: \.self) { s in
                        Button(s) { flow.spec.customText = s; showCustomText = true }
                    }
                    Button(lang.t("تلقائي من الجهة والغرض", "Automatic from recipient and purpose")) { flow.spec.customText = ""; showCustomText = false }
                } label: { Label(lang.t("قوالب", "Templates"), systemImage: "text.badge.plus").font(.app(.footnote, .bold)) }
            }
            if showCustomText || !flow.spec.customText.isEmpty {
                TextField(lang.t("اكتب نص العلامة", "Write the mark text"), text: $flow.spec.customText, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.app(.body))
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            } else {
                Text(flow.spec.sentence).font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
            }
            Toggle(lang.t("إضافة التاريخ", "Add the date"), isOn: $flow.spec.includeDate).font(.app(.subheadline))
        }
    }

    private var styles: some View {
        VStack(alignment: .leading, spacing: 8) {
            T("نمط العلامة", "Style").font(.app(.subheadline, .bold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(ProtectionStyle.allCases) { style in
                    Button { flow.spec.style = style } label: {
                        Text(lang.t(style.title)).font(.app(.footnote, .bold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .foregroundStyle(flow.spec.style == style ? Color.white : Color.primary)
                            .background(flow.spec.style == style ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(flow.spec.style == style ? Color.clear : Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(lang.t(style.detail))
                    .accessibilityAddTraits(flow.spec.style == style ? .isSelected : [])
                }
            }
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 12) {
            T("المظهر", "Appearance").font(.app(.subheadline, .bold))
            HStack(spacing: 12) {
                ForEach(colors, id: \.self) { hex in
                    Button { flow.spec.colorHex = hex } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 34, height: 34)
                            .overlay(Circle().stroke(flow.spec.colorHex == hex ? Color.primary : .clear, lineWidth: 3).padding(-4))
                    }
                    .accessibilityLabel(hex)
                }
            }
            slider(lang.t("الشفافية", "Opacity"), value: $flow.spec.opacity, range: 0.1...0.8, display: "\(Int(flow.spec.opacity * 100))٪")
            slider(lang.t("زاوية الميل", "Angle"), value: $flow.spec.angleDegrees, range: 0...60, display: "\(Int(flow.spec.angleDegrees))°")
            slider(lang.t("حجم الخط", "Text size"), value: $flow.spec.fontSize, range: 12...40, display: "\(Int(flow.spec.fontSize))")
            if flow.spec.style == .tiled || flow.spec.style == .intense {
                slider(lang.t("المسافة بين العلامات", "Spacing"), value: $flow.spec.spacing, range: 0.6...2.0,
                       display: String(format: "%.1f", flow.spec.spacing))
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(display).monospacedDigit().foregroundStyle(Theme.secondaryText) }.font(.app(.footnote))
            Slider(value: value, in: range).accessibilityLabel(title).accessibilityValue(display)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.app(.footnote, .bold))
                .padding(.horizontal, 14).frame(minHeight: 40)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Theme.accent : Theme.card, in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.line))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { flow.step = .hide } label: {
                Label(flow.hiddenCount > 0 ? lang.t("إخفاء بيانات (\(flow.hiddenCount))", "Hide data (\(flow.hiddenCount))")
                                           : lang.t("إخفاء بيانات", "Hide data"), systemImage: "eye.slash")
                    .font(.app(.subheadline, .bold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: Theme.smallRadius))
            Button {
                Task { await flow.protect(entitlement: purchases.entitlement) }
            } label: {
                Text(lang.t("إنشاء النسخة المحمية", "Create protected copy")).font(.app(.subheadline, .bold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: Theme.smallRadius))
            .disabled(flow.working)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Step 2b: hide sensitive data

struct ProtectHideView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject var flow: ProtectFlow
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(lang.t("قرأنا المستند على جهازك واقترحنا ما يُستحسن إخفاؤه. اختر ما لا يحتاج المستلم رؤيته.",
                            "We read the document on your iPhone and suggested what to hide. Choose what the recipient doesn't need."))
                    .font(.app(.subheadline)).foregroundStyle(Theme.secondaryText)
                if flow.analyzing {
                    HStack { ProgressView(); T("جارٍ قراءة المستند…", "Reading the document…").font(.app(.footnote)) }
                } else if flow.areas.isEmpty {
                    NoteBox(systemImage: "magnifyingglass", text: lang.t(
                        "لم نجد أرقاماً حساسة معروفة. يمكنك تحديد أي منطقة يدوياً.",
                        "No known sensitive numbers found. You can mark any area by hand."))
                }
                ForEach($flow.areas) { $area in
                    Toggle(isOn: $area.hidden) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lang.t(area.kind.title)).font(.app(.body, .bold))
                            Text(lang.t("صفحة \(area.pageIndex + 1): ", "Page \(area.pageIndex + 1): ") + masked(area.text))
                                .font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(12)
                    .card()
                }
                Button { showEditor = true } label: {
                    Label(manualLabel, systemImage: "rectangle.dashed")
                        .font(.app(.subheadline, .bold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                NoteBox(systemImage: "checkmark.shield", text: lang.t(
                    "إخفاء نهائي: الصفحات التي فيها مناطق مخفية تُعاد رسمها كصور بلا تلك البيانات، فلا يمكن استخراجها من النسخة الناتجة. الأصل يبقى منفصلاً دون تعديل.",
                    "Permanent: pages with hidden areas are re-drawn as images without that data, so it can't be extracted from the result. The original stays separate and unchanged."),
                        tint: Theme.success)
            }
            .padding(Theme.gutter)
        }
        .safeAreaInset(edge: .bottom) {
            Button { flow.schedulePreview(immediate: true); flow.step = .edit } label: {
                Text(lang.t("تم", "Done")).font(.app(.body, .bold)).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .padding(Theme.gutter)
            .background(.bar)
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let source = flow.source {
                PDFEditorView(file: source, mode: .redact, initialItems: []) { _, areas in
                    for (page, rects) in areas { flow.manualAreas[page, default: []] += rects }
                    showEditor = false
                }
            }
        }
    }

    private var manualLabel: String {
        let n = flow.manualAreas.values.reduce(0) { $0 + $1.count }
        return n == 0 ? lang.t("تحديد منطقة يدوياً", "Mark an area by hand") : lang.t("مناطق يدوية: \(n) — أضف أخرى", "Manual areas: \(n) — add more")
    }

    /// Shows only the last digits of a detected value on screen.
    private func masked(_ text: String) -> String {
        guard text.count > 4 else { return text }
        return String(repeating: "•", count: min(8, text.count - 4)) + text.suffix(4)
    }
}

// MARK: - Step 3: result

struct ProtectResultView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject var flow: ProtectFlow
    let close: () -> Void
    @State private var exporting = false
    @State private var previewURL: URL?
    @State private var folder = VaultFolder.identities.rawValue
    @State private var keepOriginal = true
    @State private var showShare = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 40)).foregroundStyle(Theme.success)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        T("تمت حماية المستند", "Document protected").font(.app(.title3, .bold))
                        Text(paidLine).font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                    }
                }
                if let image = flow.preview {
                    Button { previewURL = flow.output } label: {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280).frame(maxWidth: .infinity)
                            .padding(8).card()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(lang.t("فتح النسخة المحمية", "Open the protected copy"))
                }
                ShareLink(items: flow.outputs) {
                    Label(lang.t("مشاركة مباشرة", "Share"), systemImage: "square.and.arrow.up")
                        .font(.app(.body, .bold)).frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: Theme.smallRadius))
                HStack(spacing: 10) {
                    SecondaryButton(title: lang.t("حفظ في الملفات", "Save to Files"), systemImage: "square.and.arrow.down") { exporting = true }
                    if ToolAvailability.linkSharing {
                        SecondaryButton(title: lang.t("مشاركة آمنة برابط", "Secure link"), systemImage: "link") { showShare = true }
                    }
                }
                vaultCard
                NoteBox(systemImage: "exclamationmark.triangle", text: lang.t(
                    "العلامة المائية توضّح الغرض وتقلّل إساءة الاستخدام، لكنها لا تمنعها تماماً.",
                    "A watermark states the purpose and discourages misuse, but can't fully prevent it."), tint: Theme.warning)
            }
            .padding(Theme.gutter)
        }
        .fileExporter(isPresented: $exporting, items: flow.outputs.map { ExportedFile(url: $0) }, contentTypes: [.data]) { _ in }
        .quickLookPreview($previewURL, in: flow.outputs)
        .sheet(isPresented: $showShare) {
            if let pdf = flow.output {
                SecureShareView(file: pdf, title: flow.displayName, recipient: flow.spec.recipient, purpose: flow.spec.purposeText)
            }
        }
        .onAppear {
            if let kind = flow.analysis?.kind { folder = kind.folder.rawValue }
        }
    }

    private var paidLine: String {
        switch flow.paidWith {
        case .free(let left)?: lang.t("من المستندات المجانية — متبقٍ \(left)", "Free document — \(left) left")
        case .subscription(let left)?: lang.t("ضمن اشتراكك — متبقٍ هذا الشهر \(left)", "Included — \(left) left this month")
        case .credit(let left)?: lang.t("رصيد مدفوع — متبقٍ \(left)", "Paid credit — \(left) left")
        case nil: ""
        }
    }

    private var vaultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(lang.t("حفظ في مستنداتي (مشفّر)", "Save to My documents (encrypted)"), systemImage: "lock.doc")
                .font(.app(.subheadline, .bold))
            if flow.savedToVault {
                Label(lang.t("حُفظ في «مستنداتي»", "Saved to My documents"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success).font(.app(.subheadline))
            } else {
                Picker(lang.t("المجلد", "Folder"), selection: $folder) {
                    ForEach(VaultFolder.allCases) { Text(lang.t($0.title)).tag($0.rawValue) }
                    ForEach(VaultStore.shared.customFolders, id: \.self) { Text($0).tag("custom:" + $0) }
                }
                .font(.app(.subheadline))
                Toggle(lang.t("احفظ الأصل أيضاً (لإزالة العلامة لاحقاً)", "Keep the original too (to remove the mark later)"),
                       isOn: $keepOriginal).font(.app(.footnote))
                Button(lang.t("حفظ", "Save")) { flow.saveToVault(folder: folder, keepOriginal: keepOriginal) }
                    .font(.app(.subheadline, .bold))
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .card()
    }
}
