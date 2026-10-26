import SwiftUI
import WaraqaCore

/// App-wide state: language, favorites, the server-consent preference and files that were
/// opened in or shared to Waraqa.
@MainActor
final class AppModel: ObservableObject {
    @AppStorage("language") private var storedLanguage: String = AppLanguage.deviceDefault().rawValue
    @AppStorage("favorites") private var storedFavorites: String = ""
    /// When true the upload notice is not shown again (the user can turn it back on in Settings).
    @AppStorage("skipUploadNotice") var skipUploadNotice = false

    @Published var language: AppLanguage = .arabic
    @Published var favorites: [ToolID] = []
    /// Files that arrived from "Open in Waraqa" / the share sheet, waiting for the user to pick a tool.
    @Published var incoming: [PickedFile] = []
    /// A tool to open right away (from a suggestion or a chained action), with its input.
    @Published var launch: ToolLaunch?
    @Published var selectedTab: Tab = .home

    enum Tab: Hashable { case home, files, settings }

    init() {
        language = AppLanguage(rawValue: storedLanguage) ?? .arabic
        favorites = storedFavorites.split(separator: ",").compactMap { ToolID(rawValue: String($0)) }
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        storedLanguage = language.rawValue
    }

    func isFavorite(_ tool: ToolID) -> Bool { favorites.contains(tool) }

    func toggleFavorite(_ tool: ToolID) {
        if let index = favorites.firstIndex(of: tool) {
            favorites.remove(at: index)
        } else {
            favorites.append(tool)
        }
        storedFavorites = favorites.map(\.rawValue).joined(separator: ",")
    }

    /// Called for files opened from other apps (Files, Mail, WhatsApp…).
    func receive(_ url: URL) {
        guard let file = try? FileStore.shared.importFile(url) else { return }
        // Files delivered to the Inbox are copies made by iOS; remove them once we have ours.
        if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        incoming.append(file)
        selectedTab = .home
    }

    func open(_ tool: ToolID, with files: [PickedFile] = []) {
        launch = ToolLaunch(tool: tool, files: files)
        selectedTab = .home
    }
}

struct ToolLaunch: Identifiable, Hashable {
    let id = UUID()
    let tool: ToolID
    let files: [PickedFile]
}
