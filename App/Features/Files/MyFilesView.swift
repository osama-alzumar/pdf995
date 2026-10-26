import SwiftUI
import WaraqaCore

/// Recent results. Each file can be opened, shared, used with another tool, or deleted.
struct MyFilesView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var store = FileStore.shared
    @State private var previewURL: URL?
    @State private var confirmDeleteAll = false
    @State private var nextFor: RecentItem?

    var body: some View {
        NavigationStack {
            Group {
                if store.recents.isEmpty {
                    ContentUnavailableView {
                        Label(lang.t("لا توجد ملفات بعد", "No files yet"), systemImage: "folder")
                    } description: {
                        Text(lang.t("ستظهر هنا نتائج الأدوات التي تستخدمها.", "Results from the tools you use will appear here."))
                    }
                } else {
                    List {
                        ForEach(store.recents) { item in
                            row(item)
                        }
                        .onDelete { offsets in offsets.map { store.recents[$0] }.forEach(store.delete) }
                    }
                }
            }
            .navigationTitle(lang.t("ملفاتي", "My files"))
            .toolbar {
                if !store.recents.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) { confirmDeleteAll = true } label: { Image(systemName: "trash") }
                            .accessibilityLabel(lang.t("حذف الكل", "Delete all"))
                    }
                }
            }
            .confirmationDialog(lang.t("حذف كل الملفات من التطبيق؟", "Delete all files from the app?"), isPresented: $confirmDeleteAll,
                                titleVisibility: .visible) {
                Button(lang.t("حذف الكل", "Delete all"), role: .destructive) { store.deleteAll() }
            } message: {
                Text(lang.t("الملفات التي حفظتها في تطبيق الملفات لن تتأثر.", "Files you saved to the Files app aren't affected."))
            }
            .quickLookPreview($previewURL)
            .sheet(item: $nextFor) { item in
                NextToolSheet { tool in
                    nextFor = nil
                    app.open(tool, with: [store.picked(from: item)])
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func row(_ item: RecentItem) -> some View {
        let url = store.url(for: item)
        let info = ToolCatalog.info(item.tool)
        return HStack(spacing: 12) {
            ToolIcon(tool: info, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName).font(.subheadline.weight(.medium)).lineLimit(2)
                Text("\(lang.t(info.title)) · \(ByteSize.format(item.size, language: lang)) · \(item.date.formatted(.relative(presentation: .named).locale(lang.locale)))")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            Menu {
                Button { previewURL = url } label: { Label(lang.t("فتح", "Open"), systemImage: "eye") }
                ShareLink(item: url) { Label(lang.t("مشاركة", "Share"), systemImage: "square.and.arrow.up") }
                if url.pathExtension.lowercased() == "pdf" {
                    Button { nextFor = item } label: { Label(lang.t("استخدم مع أداة أخرى", "Use with another tool"), systemImage: "arrow.forward.circle") }
                }
                Button(role: .destructive) { store.delete(item) } label: { Label(lang.t("حذف", "Delete"), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel(lang.t("خيارات", "Options"))
        }
        .contentShape(Rectangle())
        .onTapGesture { previewURL = url }
    }
}
