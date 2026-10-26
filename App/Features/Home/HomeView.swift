import SwiftUI
import WaraqaCore

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.appLanguage) private var lang
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var expanded: Set<ToolCategory> = []

    private let grid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(lang.t("ماذا تريد أن تفعل بملفك؟", "What do you want to do with your file?"))
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    searchField
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchResults
                    } else {
                        if !app.incoming.isEmpty { incomingCard }
                        quickTools
                        if !app.favorites.isEmpty { favorites }
                        allTools
                    }
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.immediately)
            .navigationDestination(for: ToolLaunch.self) { launch in
                ToolView(tool: launch.tool, files: launch.files)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            if let launch = app.launch {
                path.append(launch)
                app.launch = nil
            }
        }
        .onChange(of: app.launch) { _, launch in
            guard let launch else { return }
            path.append(launch)
            app.launch = nil
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(lang.t("ابحث عن أداة: دمج، ضغط، توقيع…", "Search tools: merge, compress, sign…"), text: $query)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel(lang.t("مسح البحث", "Clear search"))
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
    }

    private var searchResults: some View {
        let results = ToolSearch.search(query)
        return VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text(lang.t("لا توجد أداة بهذا الاسم.", "No tool matches that."))
                    .foregroundStyle(Theme.secondaryText).padding()
            }
            ForEach(results) { tool in
                Button { open(tool.id) } label: { ToolRow(tool: tool, isFavorite: app.isFavorite(tool.id)).padding(12) }
                    .buttonStyle(.plain)
                if tool.id != results.last?.id { Divider().padding(.leading, 60) }
            }
        }
        .card()
    }

    private var incomingCard: some View {
        let names = app.incoming.map(\.name)
        let suggestions = FileSuggestion.tools(forFileNames: names)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(names.count == 1 ? names[0] : lang.t("\(names.count) ملفات جديدة", "\(names.count) new files"),
                      systemImage: "tray.and.arrow.down.fill")
                    .font(.headline).lineLimit(1)
                Spacer()
                Button { app.incoming = [] } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(lang.t("تجاهل", "Dismiss"))
            }
            Text(lang.t("اقتراحات لهذا الملف:", "Suggested for this file:")).font(.subheadline).foregroundStyle(Theme.secondaryText)
            ForEach(suggestions, id: \.self) { id in
                Button {
                    let files = app.incoming
                    app.incoming = []
                    open(id, files: files)
                } label: { ToolRow(tool: ToolCatalog.info(id)) }
                .buttonStyle(.plain)
            }
            if suggestions.isEmpty {
                T("اختر أداة من القائمة أدناه.", "Pick a tool below.").font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(Theme.gutter)
        .card()
    }

    private var quickTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: lang.t("الأدوات السريعة", "Quick tools"))
            LazyVGrid(columns: grid, spacing: 12) {
                ForEach(ToolCatalog.quickTools, id: \.self) { id in
                    Button { open(id) } label: { QuickToolTile(tool: ToolCatalog.info(id)) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: lang.t("المفضلة", "Favorites"))
            VStack(spacing: 0) {
                ForEach(app.favorites, id: \.self) { id in
                    Button { open(id) } label: { ToolRow(tool: ToolCatalog.info(id), isFavorite: true).padding(12) }
                        .buttonStyle(.plain)
                }
            }
            .card()
        }
    }

    private var allTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: lang.t("جميع الأدوات", "All tools"))
            ForEach(ToolCategory.allCases) { category in
                let tools = ToolCatalog.tools(in: category)
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(category) },
                    set: { if $0 { expanded.insert(category) } else { expanded.remove(category) } })) {
                    VStack(spacing: 0) {
                        ForEach(tools) { tool in
                            Button { open(tool.id) } label: { ToolRow(tool: tool, isFavorite: app.isFavorite(tool.id)).padding(.vertical, 10) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { app.toggleFavorite(tool.id) } label: {
                                        Label(app.isFavorite(tool.id) ? lang.t("إزالة من المفضلة", "Remove from favorites") : lang.t("إضافة إلى المفضلة", "Add to favorites"),
                                              systemImage: app.isFavorite(tool.id) ? "star.slash" : "star")
                                    }
                                }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.symbol).foregroundStyle(Theme.tint(for: category)).frame(width: 26)
                        Text(lang.t(category.title)).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Spacer()
                        Text("\(tools.count)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    }
                }
                .tint(Theme.secondaryText) // calm chevron and label instead of link-blue
                .padding(14)
                .card()
            }
        }
    }

    private func open(_ tool: ToolID, files: [PickedFile] = []) {
        path.append(ToolLaunch(tool: tool, files: files))
    }
}
