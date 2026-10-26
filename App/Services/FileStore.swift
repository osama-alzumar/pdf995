import Foundation
import UniformTypeIdentifiers
import WaraqaCore

/// A file the user picked or produced, as used by the tool screens.
struct PickedFile: Identifiable, Hashable, Sendable {
    let id = UUID()
    /// A private copy inside the app (the user's original is never touched).
    let url: URL
    let name: String
    var password: String?

    var size: Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
    var fileExtension: String { FileNaming.fileExtension(of: name) }
    var isPDF: Bool { fileExtension == "pdf" }
}

/// A saved result in "My files".
struct RecentItem: Codable, Identifiable, Hashable {
    let id: UUID
    let tool: ToolID
    let fileName: String
    /// Relative to the results folder.
    let path: String
    let size: Int64
    let date: Date
}

/// Where Waraqa keeps files:
///  - Imports/<uuid>/: private copies of files the user picked or shared in (removed after use or
///    on launch when older than a day).
///  - Results/<uuid>/: produced files listed in "My files" until the user deletes them.
/// All folders use complete file protection and are excluded from iCloud backup.
@MainActor
final class FileStore: ObservableObject {
    static let shared = FileStore()

    @Published private(set) var recents: [RecentItem] = []

    let root: URL
    let imports: URL
    let results: URL
    let work: URL
    private var indexURL: URL { root.appendingPathComponent("recents.json") }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Waraqa", isDirectory: true)
        imports = root.appendingPathComponent("Imports", isDirectory: true)
        results = root.appendingPathComponent("Results", isDirectory: true)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("Work", isDirectory: true)
        for dir in [root, imports, results, work] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.complete])
            var url = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        loadRecents()
        cleanUpStaleFiles()
    }

    // MARK: Imports

    /// Copies a user-picked file into the app. Handles security-scoped URLs from the Files app.
    func importFile(_ source: URL) throws -> PickedFile {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size <= Limits.maxOnDeviceBytes else { throw WaraqaError.fileTooLarge(limitBytes: Limits.maxOnDeviceBytes) }
        let folder = imports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = FileNaming.sanitize(source.lastPathComponent)
        let target = folder.appendingPathComponent(name.isEmpty ? "file" : name)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            throw (error as NSError).code == NSFileWriteOutOfSpaceError ? WaraqaError.notEnoughStorage : WaraqaError.cannotOpen(fileName: name)
        }
        return PickedFile(url: target, name: name)
    }

    func importData(_ data: Data, name: String) throws -> PickedFile {
        let folder = imports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(FileNaming.sanitize(name))
        do { try data.write(to: target, options: [.atomic, .completeFileProtection]) } catch { throw WaraqaError.notEnoughStorage }
        return PickedFile(url: target, name: target.lastPathComponent)
    }

    /// A result file used as the input of the next tool (chained actions).
    func picked(from recent: RecentItem) -> PickedFile {
        PickedFile(url: results.appendingPathComponent(recent.path), name: recent.fileName)
    }

    // MARK: Results

    /// A fresh folder for one operation's outputs.
    func newOutputFolder() throws -> URL {
        let folder = results.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        return folder
    }

    @discardableResult
    func record(_ url: URL, tool: ToolID) -> RecentItem {
        let relative = url.path.replacingOccurrences(of: results.path + "/", with: "")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let item = RecentItem(id: UUID(), tool: tool, fileName: url.lastPathComponent, path: relative, size: size, date: Date())
        recents.insert(item, at: 0)
        saveRecents()
        return item
    }

    func url(for item: RecentItem) -> URL { results.appendingPathComponent(item.path) }

    func delete(_ item: RecentItem) {
        let file = url(for: item)
        try? FileManager.default.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
        recents.removeAll { $0.id == item.id }
        saveRecents()
    }

    func deleteAll() {
        for item in recents { try? FileManager.default.removeItem(at: url(for: item)) }
        try? FileManager.default.removeItem(at: results)
        try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        recents = []
        saveRecents()
        clearTemporaryFiles()
    }

    func clearTemporaryFiles() {
        for dir in [imports, work] {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    var storageUsed: Int64 {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: Persistence

    private func loadRecents() {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder().decode([RecentItem].self, from: data) else { return }
        // Drop entries whose file is gone.
        recents = items.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func saveRecents() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        try? data.write(to: indexURL, options: [.atomic, .completeFileProtection])
    }

    private func cleanUpStaleFiles() {
        let dayAgo = Date().addingTimeInterval(-86_400)
        for dir in [imports, work] {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for item in items {
                let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if date < dayAgo { try? FileManager.default.removeItem(at: item) }
            }
        }
    }
}

extension UTType {
    static let docx = UTType("org.openxmlformats.wordprocessingml.document") ?? .data
    static let doc = UTType("com.microsoft.word.doc") ?? .data
    static let pptx = UTType("org.openxmlformats.presentationml.presentation") ?? .data
    static let ppt = UTType("com.microsoft.powerpoint.ppt") ?? .data
    static let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data
    static let xls = UTType("com.microsoft.excel.xls") ?? .data
    static let odt = UTType("org.oasis-open.opendocument.text") ?? .data

    static func types(for input: InputKind) -> [UTType] {
        switch input {
        case .singlePDF, .multiplePDFs, .twoPDFs: [.pdf]
        case .images, .camera: [.image]
        case .word: [.docx, .doc, .odt, .rtf, .plainText]
        case .powerPoint: [.pptx, .ppt]
        case .excel: [.xlsx, .xls, .commaSeparatedText]
        case .webPage: [.html]
        }
    }

    static func forFile(named name: String) -> UTType {
        UTType(filenameExtension: FileNaming.fileExtension(of: name)) ?? .data
    }
}
