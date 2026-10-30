import SwiftUI
import QuickLook
import PDFEngine
import WaraqaCore

/// "مستنداتي": the encrypted wallet, the share log and the files produced by the tools.
struct VaultView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var lock = VaultLock.shared
    @ObservedObject private var vault = VaultStore.shared
    @ObservedObject private var shares = SharesStore.shared
    @State private var section = 0
    @State private var query = ""
    @State private var newFolder = ""
    @State private var showNewFolder = false

    var body: some View {
        NavigationStack {
            Group {
                if lock.isUnlocked {
                    content
                } else {
                    lockedView
                }
            }
            .background(Theme.background)
            .navigationTitle(lang.t("مستنداتي", "My documents"))
            .navigationDestination(for: String.self) { folder in VaultFolderView(folder: folder) }
            .navigationDestination(for: VaultDocument.self) { doc in VaultDocumentView(document: doc) }
        }
    }

    private var lockedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.doc.fill").font(.system(size: 56)).foregroundStyle(Theme.accent).accessibilityHidden(true)
            T("المحفظة مقفلة", "The wallet is locked").font(.app(.title3, .bold))
            Text(lang.t("مستنداتك مشفّرة على هذا الجهاز، ومفتاحها محفوظ في سلسلة مفاتيح iOS.",
                        "Your documents are encrypted on this iPhone; the key is kept in the iOS Keychain."))
                .font(.app(.subheadline)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            PrimaryButton(title: lang.t("افتح بـ \(lang.t(lock.biometryName))", "Unlock with \(lang.t(lock.biometryName))"),
                          systemImage: "faceid") {
                Task { await lock.unlock(reason: lang.t("افتح محفظة مستنداتك", "Unlock your documents")) }
            }
            .frame(maxWidth: 320)
            if let error = lock.lastError { Text(error).font(.app(.footnote)).foregroundStyle(Theme.danger) }
            Spacer()
        }
        .padding(Theme.gutter)
        .task { if !lock.isUnlocked { await lock.unlock(reason: lang.t("افتح محفظة مستنداتك", "Unlock your documents")) } }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $section) {
                    Text(lang.t("المحفظة", "Wallet")).tag(0)
                    Text(lang.t("المشاركات", "Shares")).tag(1)
                    Text(lang.t("ملفات الأدوات", "Tool files")).tag(2)
                }
                .pickerStyle(.segmented)
                switch section {
                case 0: wallet
                case 1: SharesLogView()
                default: ToolFilesList()
                }
            }
            .padding(Theme.gutter)
        }
        .refreshable { await shares.refresh() }
    }

    private var wallet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(lang.t("ابحث في مستنداتك", "Search your documents"), text: $query).font(.app(.body))
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(VaultFolder.allCases) { folder in
                        folderTile(lang.t(folder.title), folder.symbol, count: vault.documents(in: folder.rawValue).count, value: folder.rawValue)
                    }
                    ForEach(vault.customFolders, id: \.self) { name in
                        folderTile(name, "folder", count: vault.documents(in: "custom:" + name).count, value: "custom:" + name)
                    }
                    Button { showNewFolder = true } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "folder.badge.plus").font(.app(.title3)).foregroundStyle(Theme.accent)
                            T("مجلد جديد", "New folder").font(.app(.subheadline, .bold))
                            Spacer(minLength: 0)
                        }
                        .padding(14).frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                let results = vault.search(query)
                if results.isEmpty { T("لا توجد نتائج.", "No results.").font(.app(.footnote)).foregroundStyle(Theme.secondaryText) }
                ForEach(results) { doc in NavigationLink(value: doc) { VaultRow(document: doc) }.buttonStyle(.plain) }
            }
        }
        .alert(lang.t("مجلد جديد", "New folder"), isPresented: $showNewFolder) {
            TextField(lang.t("اسم المجلد", "Folder name"), text: $newFolder)
            Button(lang.t("إنشاء", "Create")) { vault.addFolder(newFolder); newFolder = "" }
            Button(lang.t("إلغاء", "Cancel"), role: .cancel) { newFolder = "" }
        }
    }

    private func folderTile(_ title: String, _ symbol: String, count: Int, value: String) -> some View {
        NavigationLink(value: value) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.app(.title3)).foregroundStyle(Theme.accent)
                Text(title).font(.app(.subheadline, .bold)).foregroundStyle(.primary)
                Text(lang.t("\(count) مستند", "\(count) documents")).font(.app(.caption)).foregroundStyle(Theme.secondaryText)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading).card()
        }
        .buttonStyle(.plain)
    }
}

struct VaultRow: View {
    @Environment(\.appLanguage) private var lang
    let document: VaultDocument

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: document.kind == .protected ? "checkmark.shield.fill" : "doc.fill")
                .foregroundStyle(document.kind == .protected ? Theme.success : Theme.accent)
                .frame(width: 40, height: 48)
                .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title).font(.app(.subheadline, .bold)).lineLimit(2)
                Text("\(document.kind == .protected ? lang.t("نسخة محمية", "Protected copy") : lang.t("أصل", "Original")) · \(ByteSize.format(document.size, language: lang)) · \(document.created.formatted(date: .abbreviated, time: .omitted))")
                    .font(.app(.caption)).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
        }
        .padding(12).card()
    }
}

struct VaultFolderView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var vault = VaultStore.shared
    let folder: String

    var body: some View {
        let docs = vault.documents(in: folder)
        ScrollView {
            VStack(spacing: 10) {
                if docs.isEmpty {
                    ContentUnavailableView(lang.t("لا توجد مستندات", "No documents"), systemImage: "tray",
                                           description: Text(lang.t("احفظ النسخ المحمية هنا من شاشة النتيجة.", "Save protected copies here from the result screen.")))
                }
                ForEach(docs) { doc in NavigationLink(value: doc) { VaultRow(document: doc) }.buttonStyle(.plain) }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .navigationTitle(VaultStore.folderTitle(folder, lang))
        .toolbar {
            if folder.hasPrefix("custom:") {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) { vault.deleteFolder(String(folder.dropFirst(7))) } label: { Image(systemName: "trash") }
                        .accessibilityLabel(lang.t("حذف المجلد", "Delete folder"))
                }
            }
        }
    }
}

struct VaultDocumentView: View {
    @Environment(\.appLanguage) private var lang
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var vault = VaultStore.shared
    @ObservedObject private var shares = SharesStore.shared
    let document: VaultDocument
    @State private var openedURL: URL?
    @State private var previewURL: URL?
    @State private var originalURL: IdentifiedURL?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false
    @State private var showShare = false
    @State private var protectAgain = false
    @State private var error: WaraqaError?

    private var current: VaultDocument { vault.documents.first { $0.id == document.id } ?? document }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let url = openedURL, current.fileExtension == "pdf" {
                    Button { previewURL = url } label: {
                        PageThumb(file: PickedFile(url: url, name: current.fileName), index: 0)
                            .frame(maxHeight: 280).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(lang.t("فتح المستند", "Open the document"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.title).font(.app(.title3, .bold))
                    Text("\(VaultStore.folderTitle(current.folder, lang)) · \(current.pages) \(lang.t("صفحة", "pages")) · \(ByteSize.format(current.size, language: lang))")
                        .font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                    if let spec = current.spec {
                        Text(spec.sentence).font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                    }
                }
                if let url = openedURL {
                    ShareLink(item: url) {
                        Label(lang.t("مشاركة", "Share"), systemImage: "square.and.arrow.up").font(.app(.body, .bold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if current.kind == .protected && ToolAvailability.linkSharing {
                    SecondaryButton(title: lang.t("مشاركة آمنة برابط", "Secure link"), systemImage: "link") { showShare = true }
                }
                SecondaryButton(title: lang.t("علامة مائية جديدة", "New watermark"), systemImage: "drop") { protectAgain = true }
                if current.kind == .protected {
                    if let original = vault.original(of: current) {
                        SecondaryButton(title: lang.t("إزالة علامة ورقة (استرجاع الأصل)", "Remove Waraqa mark (get the original)"),
                                        systemImage: "drop.halffull") {
                            do { originalURL = IdentifiedURL(url: try vault.open(original)) } catch { self.error = ToolRunner.map(error) }
                        }
                    } else {
                        NoteBox(systemImage: "info.circle", text: lang.t(
                            "الأصل غير محفوظ لهذه النسخة، لذا لا يمكن إزالة العلامة. العلامة جزء من الصفحة ولا يمكن «مسحها» من نسخة دون الأصل.",
                            "The original wasn't kept for this copy, so the mark can't be removed: it's part of the page."))
                    }
                }
                HStack(spacing: 10) {
                    SecondaryButton(title: lang.t("إعادة التسمية", "Rename"), systemImage: "pencil") { newTitle = current.title; renaming = true }
                    Menu {
                        ForEach(VaultFolder.allCases) { f in Button(lang.t(f.title)) { vault.move(current, to: f.rawValue) } }
                        ForEach(vault.customFolders, id: \.self) { name in Button(name) { vault.move(current, to: "custom:" + name) } }
                    } label: {
                        Label(lang.t("نقل", "Move"), systemImage: "folder").frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(lang.t("حذف", "Delete"), systemImage: "trash").frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.bordered)
                let related = shares.records.filter { $0.documentTitle == current.title }
                if !related.isEmpty {
                    T("سجل مشاركات هذا المستند", "This document's shares").font(.app(.headline))
                    ForEach(related) { ShareRow(record: $0) }
                }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .navigationTitle(lang.t("المستند", "Document"))
        .navigationBarTitleDisplayMode(.inline)
        .task { openedURL = try? vault.open(current) }
        .quickLookPreview($previewURL)
        .sheet(item: $originalURL) { item in
            let url = item.url
            NavigationStack {
                VStack(spacing: 16) {
                    T("النسخة الأصلية بدون علامة", "The original, without the mark").font(.app(.headline))
                    ShareLink(item: url) { Label(lang.t("مشاركة / حفظ الأصل", "Share / save the original"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                    Button(lang.t("معاينة", "Preview")) { previewURL = url }
                }
                .padding()
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = openedURL {
                SecureShareView(file: url, title: current.title, recipient: current.spec?.recipient ?? "", purpose: current.spec?.purposeText ?? "")
            }
        }
        .fullScreenCover(isPresented: $protectAgain) {
            if let source = sourceForProtect() {
                ProtectFlowView(language: lang, files: [source])
            }
        }
        .alert(lang.t("إعادة التسمية", "Rename"), isPresented: $renaming) {
            TextField(lang.t("الاسم", "Name"), text: $newTitle)
            Button(lang.t("حفظ", "Save")) { vault.rename(current, to: newTitle) }
            Button(lang.t("إلغاء", "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(lang.t("حذف المستند نهائياً؟", "Delete this document permanently?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(lang.t("حذف", "Delete"), role: .destructive) { vault.delete(current); dismiss() }
        }
        .alert(lang.t("تنبيه", "Notice"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(lang.t("حسناً", "OK"), role: .cancel) {}
        } message: { Text(error.map { lang.t($0.message) } ?? "") }
    }

    /// Re-protecting starts from the original when it was kept (no mark on top of a mark).
    private func sourceForProtect() -> PickedFile? {
        let target = vault.original(of: current) ?? current
        guard let url = try? vault.open(target) else { return nil }
        return PickedFile(url: url, name: target.fileName)
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SharesLogView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var shares = SharesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shares.records.isEmpty {
                ContentUnavailableView(lang.t("لا توجد مشاركات", "No shares"), systemImage: "link",
                                       description: Text(lang.t("الروابط الآمنة التي تنشئها تظهر هنا.", "Secure links you create appear here.")))
            }
            ForEach(shares.records) { ShareRow(record: $0) }
            if !shares.records.isEmpty {
                Text(lang.t("اسحب للأسفل لتحديث عدد مرات الفتح. لا يمكن معرفة هوية من فتح الرابط.",
                            "Pull down to refresh opens. Who opened a link can't be known."))
                    .font(.app(.caption)).foregroundStyle(Theme.secondaryText)
            }
        }
        .task { await shares.refresh(); shares.clearNewOpens() }
    }
}

struct ShareRow: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var shares = SharesStore.shared
    let record: ShareRecord
    @State private var showCard = false

    var body: some View {
        let state = record.effectiveState
        Button { showCard = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(record.documentTitle).font(.app(.subheadline, .bold)).lineLimit(1)
                    Spacer()
                    Text(lang.t(state.title)).font(.app(.caption, .bold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(state == .active ? Theme.success : (state == .revoked ? Theme.secondaryText : Theme.warning))
                        .background((state == .active ? Theme.success : Theme.warning).opacity(0.12), in: Capsule())
                }
                Text(lang.t("إلى: \(record.recipient)", "To: \(record.recipient)")).font(.app(.footnote))
                Text("\(lang.t("أُنشئ", "Created")) \(record.created.formatted(date: .abbreviated, time: .shortened)) · \(lang.t("ينتهي", "Expires")) \(record.expires.formatted(date: .abbreviated, time: .shortened))")
                    .font(.app(.caption)).foregroundStyle(Theme.secondaryText)
                Text(lang.t("مرات الفتح المسجلة: \(record.opens) من \(record.maxViews)", "Recorded opens: \(record.opens) of \(record.maxViews)"))
                    .font(.app(.caption))
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { shares.forget(record) } label: { Label(lang.t("إزالة من السجل", "Remove from log"), systemImage: "trash") }
        }
        .sheet(isPresented: $showCard) {
            NavigationStack {
                ScrollView { ShareLinkCard(record: record).padding(Theme.gutter) }
                    .navigationTitle(record.documentTitle).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(lang.t("إغلاق", "Close")) { showCard = false } } }
            }
        }
    }
}

/// Results of the PDF tools (previously "My files").
struct ToolFilesList: View {
    @Environment(\.appLanguage) private var lang
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = FileStore.shared
    @State private var previewURL: URL?

    var body: some View {
        VStack(spacing: 10) {
            if store.recents.isEmpty {
                ContentUnavailableView(lang.t("لا توجد ملفات بعد", "No files yet"), systemImage: "folder",
                                       description: Text(lang.t("ستظهر هنا نتائج أدوات PDF.", "Results of the PDF tools appear here.")))
            }
            ForEach(store.recents) { item in
                let url = store.url(for: item)
                HStack(spacing: 12) {
                    ToolIcon(tool: ToolCatalog.info(item.tool), size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.fileName).font(.app(.subheadline, .bold)).lineLimit(2)
                        Text("\(ByteSize.format(item.size, language: lang)) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.app(.caption)).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(lang.t("مشاركة", "Share"))
                    Button(role: .destructive) { store.delete(item) } label: { Image(systemName: "trash") }
                        .accessibilityLabel(lang.t("حذف", "Delete"))
                }
                .padding(12).card()
                .contentShape(Rectangle())
                .onTapGesture { previewURL = url }
            }
        }
        .quickLookPreview($previewURL)
    }
}
