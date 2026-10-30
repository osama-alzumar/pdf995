import SwiftUI
import PDFEngine
import WaraqaCore

/// The screen every tool uses: add the file → choose options (only if needed) → run →
/// save / share / open the result.
struct ToolView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.appLanguage) private var lang
    @StateObject private var runner = ToolRunner()
    @ObservedObject private var server = ServerService.shared
    @ObservedObject private var purchases = PurchaseStore.shared
    @State private var showPlans = false

    let tool: ToolInfo
    @State private var files: [PickedFile]
    @State private var options = ToolOptions()
    @State private var inputError: WaraqaError?
    @State private var showUploadNotice = false
    @State private var showEditor = false
    @State private var showForms = false

    init(tool: ToolID, files: [PickedFile] = []) {
        self.tool = ToolCatalog.info(tool)
        _files = State(initialValue: files)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                switch runner.phase {
                case .idle:
                    setup
                case .running(let progress):
                    RunningView(progress: progress, isServer: needsServer) { runner.cancel() }
                case .finished(let output, let recents):
                    ResultView(tool: tool.id, output: output, recents: recents, sourceFiles: files) {
                        runner.reset()
                    }
                case .failed(let error):
                    FailureView(error: error, canUseServerRepair: tool.id == .repair && server.isConfigured && !options.useServer) {
                        runner.reset()
                    } retry: {
                        start()
                    } useServer: {
                        options.useServer = true
                        runner.reset()
                        askAndRun()
                    }
                }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .navigationTitle(lang.t(tool.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.toggleFavorite(tool.id) } label: {
                    Image(systemName: app.isFavorite(tool.id) ? "star.fill" : "star")
                }
                .accessibilityLabel(app.isFavorite(tool.id) ? lang.t("إزالة من المفضلة", "Remove from favorites")
                                                            : lang.t("إضافة إلى المفضلة", "Add to favorites"))
            }
        }
        .alert(lang.t("تنبيه", "Notice"), isPresented: Binding(get: { inputError != nil }, set: { if !$0 { inputError = nil } })) {
            Button(lang.t("حسناً", "OK"), role: .cancel) {}
        } message: {
            Text(inputError.map { lang.t($0.message) } ?? "")
        }
        .sheet(isPresented: $showUploadNotice) {
            UploadNoticeSheet(retentionMinutes: server.retentionMinutes) { agreed, remember in
                showUploadNotice = false
                if agreed {
                    if remember { app.skipUploadNotice = true }
                    start()
                }
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let file = files.first {
                PDFEditorView(file: file, mode: editorMode, initialItems: options.editItems) { items, areas in
                    options.editItems = items
                    if tool.id == .redact { options.redactAreas = areas }
                    showEditor = false
                    if tool.id != .redact && !items.isEmpty { start() }
                }
            }
        }
        .navigationDestination(isPresented: $showForms) {
            if let file = files.first { FormsView(file: file) }
        }
        .task { if needsServer { await server.refresh() } }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            ToolIcon(tool: tool, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t(tool.title)).font(.app(.title2, .bold))
                Text(lang.t(tool.subtitle)).font(.app(.subheadline)).foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var setup: some View {
        privacyBadge
        if needsServer && !server.isConfigured {
            NoteBox(systemImage: "icloud.slash", text: lang.t(
                "هذه الأداة تعمل عبر خادم المعالجة، وهو غير مفعّل في هذه النسخة من التطبيق، لذلك لا يمكن تشغيلها الآن.",
                "This tool runs on the processing server, which isn't enabled in this build, so it can't run right now."), tint: .orange)
        }
        VStack(alignment: .leading, spacing: 14) {
            FileInputSection(tool: tool, files: $files, webURL: $options.webURL, error: $inputError)
        }
        .padding(Theme.gutter)
        .card()

        if let file = files.first, file.isPDF, showsPagePreview {
            PageGridView(file: file, mode: pageGridMode, selection: $options.selectedPages, order: $options.organize)
                .padding(.vertical, 4)
        }

        if hasOptions && !files.isEmpty {
            ToolOptionsView(tool: tool.id, options: $options, file: files.first)
                .padding(Theme.gutter)
                .card()
        }

        if tool.id == .redact && !files.isEmpty {
            SecondaryButton(title: lang.t("حدّد مناطق على الصفحات", "Mark areas on the pages"), systemImage: "rectangle.dashed") {
                showEditor = true
            }
        }

        if let hint = hint { NoteBox(systemImage: "info.circle", text: hint) }

        if ToolTrialStore.shared.allowsTools(purchases.entitlement) {
            PrimaryButton(title: runTitle, systemImage: runSymbol, isEnabled: canRun) { primaryAction() }
                .accessibilityHint(canRun ? "" : lang.t("أضف الملف المطلوب أولاً", "Add the required file first"))
        } else {
            trialEnded
        }
    }

    private var trialEnded: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(lang.t("انتهت التجربة المجانية للأدوات", "The free tools trial has ended"), systemImage: "crown.fill")
                .font(.app(.headline, .bold)).foregroundStyle(Theme.accent)
            Text(lang.t("كانت أدوات PDF مجانية لمدة \(PlanRules.toolTrialDays) أيام. اشترك في «ورقة بلس» لاستخدام جميع الأدوات بلا حدود، مع \(PlanRules.monthlyAllowance) حماية شهرياً.",
                        "The PDF tools were free for \(PlanRules.toolTrialDays) days. Subscribe to Waraqa Plus for unlimited use of every tool, plus \(PlanRules.monthlyAllowance) protections a month."))
                .font(.app(.subheadline)).fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: lang.t("اشترك في ورقة بلس", "Subscribe to Waraqa Plus"), systemImage: "crown") { showPlans = true }
                .accessibilityIdentifier("tool.subscribe")
        }
        .padding(16)
        .card()
        .sheet(isPresented: $showPlans) { PlansView() }
    }

    private var privacyBadge: some View {
        Group {
            if needsServer {
                Label(lang.t("يُرفع الملف إلى خادم المعالجة بعد موافقتك فقط، ويُحذف تلقائياً",
                             "Uploaded to the processing server only after you agree, then deleted automatically"),
                      systemImage: "icloud.and.arrow.up")
            } else {
                Label(lang.t("يُعالج على جهازك — لا يغادر الملف هاتفك", "Processed on your iPhone — the file never leaves it"),
                      systemImage: "lock.iphone")
            }
        }
        .font(.app(.footnote))
        .foregroundStyle(Theme.secondaryText)
    }

    // MARK: Logic

    private var needsServer: Bool {
        tool.execution == .server || (tool.execution == .onDeviceWithServerFallback && options.useServer)
    }

    private var editorMode: PDFEditorView.Mode {
        switch tool.id {
        case .sign: .sign
        case .redact: .redact
        default: .edit
        }
    }

    private var showsPagePreview: Bool {
        [.removePages, .extractPages, .organize, .rotate, .pdfToImages].contains(tool.id)
    }

    private var pageGridMode: PageGridView.Mode {
        switch tool.id {
        case .organize: .reorder
        case .removePages, .extractPages, .pdfToImages: .select
        case .rotate: options.rotateAll ? .preview : .select
        default: .preview
        }
    }

    private var hasOptions: Bool {
        [.split, .removePages, .extractPages, .rotate, .compress, .ocr, .scanToPDF, .imagesToPDF, .pdfToImages,
         .pageNumbers, .watermark, .crop, .protect, .redact, .summarize, .translate, .convertImages, .shrinkImages].contains(tool.id)
    }

    private var hint: String? {
        switch tool.id {
        case .sign: lang.t("التوقيع المرسوم أو المكتوب توقيع مرئي، وليس توقيعاً رقمياً معتمداً بشهادة.",
                           "A drawn or typed signature is a visual signature, not a certificate-based digital signature.")
        case .unlock: lang.t("استخدم هذه الأداة فقط لملفات تملك حق تعديلها وتعرف كلمة مرورها.",
                             "Use this only for files you're allowed to modify and whose password you know.")
        case .intelligence: lang.t("ستظهر الإجابات مع الصفحة والاقتباس من ملفك، ولا يُعرض ما لا يوجد في الملف.",
                                   "Answers show the page and quote from your file; nothing outside the file is presented.")
        case .summarize, .translate: lang.t("يُرسل نص الملف فقط (وليس الملف نفسه) للمعالجة بالذكاء الاصطناعي بعد موافقتك.",
                                            "Only the file's text (not the file) is sent for AI processing, after you agree.")
        case .pdfToWord, .pdfToExcel, .pdfToPowerPoint: lang.t("لا يوجد تحويل مطابق ١٠٠٪. المستندات المعقدة قد تحتاج مراجعة بعد التحويل.",
                                                               "No conversion is 100% exact. Complex documents may need a review afterwards.")
        default: nil
        }
    }

    private var canRun: Bool {
        if needsServer && !server.isConfigured { return false }
        switch tool.input {
        case .webPage: return !files.isEmpty || !options.webURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .multiplePDFs, .twoPDFs: return files.count >= 2
        default: break
        }
        guard !files.isEmpty else { return false }
        switch tool.id {
        case .protect: return !options.newPassword.isEmpty && options.newPassword == options.confirmPassword
        case .removePages, .extractPages: return !options.selectedPages.isEmpty || !options.pageText.isEmpty
        case .organize: return !options.organize.isEmpty
        case .watermark: return options.watermark.hasContent
        case .redact: return !options.redactAreas.isEmpty || !options.redactTerms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return true
        }
    }

    private var runTitle: String {
        switch tool.id {
        case .edit: lang.t("افتح المحرر", "Open editor")
        case .sign: lang.t("ضع توقيعك", "Place your signature")
        case .forms: lang.t("افتح النموذج", "Open the form")
        case .intelligence: lang.t("حلّل الملف", "Analyze file")
        default: lang.t("تنفيذ", "Run")
        }
    }

    private var runSymbol: String {
        switch tool.id {
        case .edit, .sign: "pencil.tip"
        case .forms: "list.bullet.rectangle"
        default: "play.fill"
        }
    }

    private func primaryAction() {
        switch tool.id {
        case .edit, .sign: showEditor = true
        case .forms: showForms = true
        default: askAndRun()
        }
    }

    private func askAndRun() {
        if needsServer && !app.skipUploadNotice {
            showUploadNotice = true
        } else {
            start()
        }
    }

    private func start() {
        runner.run(tool.id, files: files, options: options, language: lang)
    }
}

// MARK: - Running / failure

struct RunningView: View {
    @Environment(\.appLanguage) private var lang
    let progress: Double
    let isServer: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
            Text(statusText).font(.app(.headline, .bold))
            Text("\(Int(progress * 100))%").font(.app(.subheadline).monospacedDigit()).foregroundStyle(Theme.secondaryText)
            Button(lang.t("إلغاء", "Cancel"), role: .cancel, action: cancel)
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .card()
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if isServer && progress < 0.5 { return lang.t("جارٍ الرفع الآمن…", "Uploading securely…") }
        if isServer { return lang.t("جارٍ المعالجة على الخادم…", "Processing on the server…") }
        return lang.t("جارٍ المعالجة على جهازك…", "Processing on your iPhone…")
    }
}

struct FailureView: View {
    @Environment(\.appLanguage) private var lang
    let error: WaraqaError
    var canUseServerRepair = false
    let reset: () -> Void
    let retry: () -> Void
    var useServer: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: error == .cancelled ? "stop.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(error == .cancelled ? Color.secondary : Color.orange)
                .accessibilityHidden(true)
            Text(lang.t(error.message)).font(.app(.body)).multilineTextAlignment(.center)
            if error.canRetry {
                PrimaryButton(title: lang.t("إعادة المحاولة", "Try again"), systemImage: "arrow.clockwise", action: retry)
            }
            if canUseServerRepair, case .cannotOpen = error {
                SecondaryButton(title: lang.t("حاول الإصلاح المتقدم عبر الخادم", "Try advanced repair on the server"),
                                systemImage: "icloud.and.arrow.up", action: useServer)
            }
            SecondaryButton(title: lang.t("رجوع وتعديل الخيارات", "Back to options"), systemImage: "slider.horizontal.3", action: reset)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .card()
    }
}

/// Shown before anything is uploaded.
struct UploadNoticeSheet: View {
    @Environment(\.appLanguage) private var lang
    let retentionMinutes: Int
    let done: (_ agreed: Bool, _ remember: Bool) -> Void
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(lang.t("رفع الملف للمعالجة", "Upload for processing"), systemImage: "icloud.and.arrow.up")
                .font(.app(.title3, .bold))
            VStack(alignment: .leading, spacing: 8) {
                bullet(lang.t("هذه الأداة لا يمكن تنفيذها على الجهاز بجودة كافية، لذا يُرسل الملف إلى خادم ورقة.",
                              "This tool can't run on the device with enough quality, so the file is sent to the Waraqa server."))
                bullet(lang.t("الإرسال عبر اتصال مشفر (HTTPS).", "It's sent over an encrypted connection (HTTPS)."))
                bullet(lang.t("يُحذف الملف ونتيجته من الخادم فور انتهاء المعالجة، وخلال \(retentionMinutes) دقائق كحد أقصى.",
                              "The file and its result are deleted from the server right after processing, within \(retentionMinutes) minutes at most."))
                bullet(lang.t("لا تُحفظ محتويات المستند في سجلات الخادم.", "Document contents are never written to server logs."))
            }
            Toggle(lang.t("لا تسألني مجدداً", "Don't ask again"), isOn: $remember)
            PrimaryButton(title: lang.t("موافق، تابع", "Agree and continue"), systemImage: "checkmark") { done(true, remember) }
            Button(lang.t("إلغاء", "Cancel")) { done(false, false) }
                .frame(maxWidth: .infinity)
        }
        .padding(24)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.app(.footnote))
            Text(text).font(.app(.subheadline)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
