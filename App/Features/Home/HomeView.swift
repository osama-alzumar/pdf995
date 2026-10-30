import SwiftUI
import PDFEngine
import WaraqaCore

/// Design B home: the protection card first, the file tools second, then recent documents.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var quota = QuotaStore.shared
    @ObservedObject private var purchases = PurchaseStore.shared
    @ObservedObject private var files = FileStore.shared
    @ObservedObject private var shares = SharesStore.shared
    @AppStorage("showRecents") private var showRecents = true
    @State private var protecting = false
    @State private var protectFiles: [PickedFile] = []

    private let grid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if !app.incoming.isEmpty { incomingCard }
                    if shares.newOpens > 0 { opensBanner }
                    hero
                    tools
                    if showRecents { recents }
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .fullScreenCover(isPresented: $protecting, onDismiss: { protectFiles = [] }) {
            ProtectFlowView(language: lang, files: protectFiles)
        }
        .onAppear(perform: openDemoIfRequested)
    }

    /// DEBUG only: `-WaraqaDemoProtect` opens the protect flow with a generated sample document
    /// (no real personal data), used by UI tests and for screenshots.
    private func openDemoIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-WaraqaDemoProtect"), !protecting else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("نموذج مستند تعريفي.pdf")
        let lines = ["مستند تعريفي — نموذج تجريبي", "الاسم: سارة أحمد (اسم افتراضي)", "رقم الهوية 1000000001",
                     "تاريخ الميلاد: 1995/01/01", "الجوال 0500000000", "هذا المستند للعرض فقط ولا يمثل وثيقة حقيقية."]
        try? PDFEngine.textToPDF(pages: [lines.joined(separator: "\n\n")], title: "بطاقة تعريف — نموذج", rightToLeft: true, to: url)
        protectFiles = [PickedFile(url: url, name: url.lastPathComponent)]
        protecting = true
        #endif
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                T("مستنداتك بأمان، وملفاتك بسهولة", "Your documents, safe. Your files, simple.")
                    .font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                T("ورقة", "Waraqa").font(.app(.largeTitle, .heavy))
            }
            Spacer()
            Button { app.selectedTab = .account } label: {
                Image(systemName: "person.crop.circle").font(.app(.title2)).foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(lang.t("حسابي", "Account"))
        }
        .padding(.top, 8)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(lang.t("حماية المستندات", "Document protection"), systemImage: "checkmark.shield")
                .font(.app(.footnote, .bold)).foregroundStyle(.white.opacity(0.85))
            T("احمِ مستندك", "Protect your document").font(.app(.largeTitle, .heavy)).foregroundStyle(.white)
            T("أضف علامة مائية وشارك مستنداتك بثقة أكبر.", "Add a watermark and share your documents with more confidence.")
                .font(.app(.body)).foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: 270, alignment: .leading)
            Button { protectFiles = []; protecting = true } label: {
                Label(lang.t("إضافة مستند", "Add a document"), systemImage: "plus")
                    .font(.app(.body, .bold))
                    .padding(.horizontal, 22).frame(minHeight: 52)
                    .foregroundStyle(Color(red: 0.118, green: 0.227, blue: 0.431))
                    .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("protect.add")
            Text(freeLine).font(.app(.caption)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(alignment: .bottomTrailing) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 120))
                .foregroundStyle(.white.opacity(0.08))
                .rotationEffect(.degrees(-12))
                .offset(x: 18, y: 24)
                .accessibilityHidden(true)
        }
        .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: Theme.radius + 4, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius + 4, style: .continuous))
        .shadow(color: Color(red: 0.118, green: 0.227, blue: 0.431).opacity(0.28), radius: 20, x: 0, y: 12)
    }

    private var freeLine: String {
        if case .subscribed = purchases.entitlement { return lang.t("ورقة بلس مفعّل", "Waraqa Plus is active") }
        let free = quota.quota.freeRemaining
        if free > 0 { return lang.t("متبقٍ لك \(free) من \(PlanRules.freeProtections) مستندات مجانية", "\(free) of \(PlanRules.freeProtections) free documents left") }
        return lang.t("رصيدك: \(quota.quota.credits) مستند", "Credits: \(quota.quota.credits)")
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: lang.t("أدوات الملفات", "File tools"))
                Button(lang.t("الكل", "All")) { app.selectedTab = .tools }.font(.app(.subheadline, .bold))
            }
            LazyVGrid(columns: grid, spacing: 12) {
                ForEach([ToolID.imagesToPDF, .merge, .compress, .pdfToWord, .sign, .watermark], id: \.self) { id in
                    Button { app.open(id) } label: { QuickToolTile(tool: ToolCatalog.info(id)) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: lang.t("المستندات الأخيرة", "Recent documents"))
            let items = Array(files.recents.prefix(5))
            if items.isEmpty {
                Text(lang.t("لا توجد مستندات حديثة. تبقى ملفاتك على جهازك.", "No recent documents. Your files stay on your iPhone."))
                    .font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(items) { item in
                let url = files.url(for: item)
                HStack(spacing: 12) {
                    Text(FileNaming.fileExtension(of: item.fileName).uppercased())
                        .font(.app(.caption2, .bold)).foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 48)
                        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.fileName).font(.app(.subheadline, .bold)).lineLimit(1)
                        Text("\(ByteSize.format(item.size, language: lang)) · \(item.date.formatted(.relative(presentation: .named).locale(lang.locale)))")
                            .font(.app(.caption)).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                        .accessibilityLabel(lang.t("مشاركة", "Share"))
                    Button(role: .destructive) { files.delete(item) } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(lang.t("حذف", "Delete"))
                }
                .padding(10).card()
            }
        }
    }

    private var incomingCard: some View {
        let names = app.incoming.map(\.name)
        let suggestions = FileSuggestion.tools(forFileNames: names)
        let protectable = app.incoming.allSatisfy { $0.isPDF || ["jpg", "jpeg", "png", "heic", "heif"].contains($0.fileExtension) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(names.count == 1 ? names[0] : lang.t("\(names.count) ملفات جديدة", "\(names.count) new files"), systemImage: "tray.and.arrow.down.fill")
                    .font(.app(.headline)).lineLimit(1)
                Spacer()
                Button { app.incoming = [] } label: { Image(systemName: "xmark") }.accessibilityLabel(lang.t("تجاهل", "Dismiss"))
            }
            if protectable {
                Button {
                    protectFiles = app.incoming
                    app.incoming = []
                    protecting = true
                } label: {
                    Label(lang.t("احمِ هذا المستند بعلامة مائية", "Protect this document with a watermark"), systemImage: "checkmark.shield")
                        .font(.app(.subheadline, .bold)).frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
            }
            ForEach(suggestions, id: \.self) { id in
                Button {
                    let incoming = app.incoming
                    app.incoming = []
                    app.open(id, with: incoming)
                } label: { ToolRow(tool: ToolCatalog.info(id)) }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.gutter).card()
    }

    private var opensBanner: some View {
        Button { app.selectedTab = .documents } label: {
            Label(lang.t("فُتحت روابطك \(shares.newOpens) مرة منذ آخر زيارة", "Your links were opened \(shares.newOpens) time(s) since your last visit"),
                  systemImage: "eye")
                .font(.app(.footnote, .bold)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        }
        .buttonStyle(.plain)
    }
}

/// "أدوات PDF": the brief's 18 tools first, then every other existing tool.
struct ToolsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.appLanguage) private var lang
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var showRemoveMark = false

    private let grid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(lang.t("ابحث عن أداة: دمج، ضغط، توقيع…", "Search: merge, compress, sign…"), text: $query)
                            .font(.app(.body)).autocorrectionDisabled()
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        let results = ToolSearch.search(query)
                        if results.isEmpty { T("لا توجد أداة بهذا الاسم.", "No tool matches that.").font(.app(.footnote)) }
                        ForEach(results) { tool in
                            Button { open(tool.id) } label: { ToolRow(tool: tool).padding(12).card() }.buttonStyle(.plain)
                        }
                    } else {
                        LazyVGrid(columns: grid, spacing: 12) {
                            ForEach(ToolCatalog.featured, id: \.self) { id in
                                Button { open(id) } label: { FeaturedToolTile(tool: ToolCatalog.info(id)) }.buttonStyle(.plain)
                            }
                        }
                        SectionTitle(text: lang.t("أدوات أخرى", "More tools"))
                        let others = ToolCatalog.all.filter { !ToolCatalog.featured.contains($0.id) }
                        VStack(spacing: 0) {
                            ForEach(others) { tool in
                                Button { open(tool.id) } label: { ToolRow(tool: tool).padding(12) }.buttonStyle(.plain)
                            }
                        }
                        .card()
                    }
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background)
            .navigationTitle(lang.t("أدوات PDF", "PDF tools"))
            .navigationDestination(for: ToolLaunch.self) { launch in ToolView(tool: launch.tool, files: launch.files) }
            .sheet(isPresented: $showRemoveMark) { RemoveMarkSheet() }
        }
        .onAppear(perform: consumeLaunch)
        .onChange(of: app.launch) { _, _ in consumeLaunch() }
    }

    private func consumeLaunch() {
        guard let launch = app.launch else { return }
        app.launch = nil
        if launch.tool == .removeWatermark { showRemoveMark = true } else { path.append(launch) }
    }

    private func open(_ id: ToolID) {
        if id == .removeWatermark { showRemoveMark = true } else { path.append(ToolLaunch(tool: id, files: [])) }
    }
}

struct FeaturedToolTile: View {
    @Environment(\.appLanguage) private var lang
    let tool: ToolInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolIcon(tool: tool, size: 38)
            Text(lang.t(tool.title)).font(.app(.subheadline, .bold)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
            Text(tool.execution == .server ? lang.t("يحتاج اتصالاً", "Needs internet") : lang.t("على الجهاز", "On device"))
                .font(.app(.caption2)).foregroundStyle(tool.execution == .server ? Theme.secondaryText : Theme.success)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// "Remove Waraqa mark": the mark is part of the page, so it is removed by handing back the
/// original that was saved with the protected copy.
struct RemoveMarkSheet: View {
    @Environment(\.appLanguage) private var lang
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var vault = VaultStore.shared
    @ObservedObject private var lock = VaultLock.shared

    var body: some View {
        NavigationStack {
            Group {
                if !lock.isUnlocked {
                    VStack(spacing: 14) {
                        T("افتح «مستنداتي» أولاً", "Unlock My documents first").font(.app(.headline))
                        PrimaryButton(title: lang.t("فتح", "Unlock"), systemImage: "faceid") {
                            Task { await lock.unlock(reason: lang.t("افتح محفظة مستنداتك", "Unlock your documents")) }
                        }
                    }
                    .padding()
                } else {
                    let items = vault.documents.filter { $0.kind == .protected && vault.original(of: $0) != nil }
                    List {
                        Section {
                            if items.isEmpty {
                                Text(lang.t("لا توجد نسخ محمية محفوظ أصلها. عند حماية مستند فعّل «احفظ الأصل أيضاً».",
                                            "No protected copies with a saved original. Turn on “Keep the original” when protecting."))
                                    .font(.app(.footnote))
                            }
                            ForEach(items) { doc in
                                NavigationLink(value: doc) { Text(doc.title).font(.app(.body)) }
                            }
                        } footer: {
                            Text(lang.t("العلامة جزء من صفحات النسخة المحمية، لذلك «إزالتها» تعني استرجاع الأصل المحفوظ مشفّراً.",
                                        "The mark is part of the protected pages, so removing it means getting back the encrypted original."))
                        }
                    }
                    .navigationDestination(for: VaultDocument.self) { VaultDocumentView(document: $0) }
                }
            }
            .navigationTitle(lang.t("إزالة علامة ورقة", "Remove Waraqa mark"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(lang.t("إغلاق", "Close")) { dismiss() } } }
        }
    }
}
