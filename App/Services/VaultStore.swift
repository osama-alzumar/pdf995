import Foundation
import WaraqaCore

/// One document in "My documents".
struct VaultDocument: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case original, protected }

    let id: UUID
    var title: String
    var folder: String          // a VaultFolder raw value, or "custom:<name>"
    let kind: Kind
    let fileExtension: String
    let size: Int64
    let created: Date
    /// For a protected copy: the original it was made from (if the original was kept).
    var originalID: UUID?
    var spec: ProtectionSpec?
    var pages: Int

    var fileName: String { FileNaming.sanitize(title) + "." + fileExtension }
}

/// The encrypted documents wallet. Each file is AES-256-GCM encrypted with a key that lives
/// only in this device's Keychain; the index (titles, folders) is encrypted too. Opened files
/// are decrypted into a private temporary folder that is emptied when the app goes to the
/// background and at launch.
@MainActor
final class VaultStore: ObservableObject {
    static let shared = VaultStore()

    @Published private(set) var documents: [VaultDocument] = []
    @Published private(set) var customFolders: [String] = []

    private let root: URL
    private let openedDir: URL
    private var indexURL: URL { root.appendingPathComponent("index.enc") }

    private struct Index: Codable {
        var documents: [VaultDocument]
        var customFolders: [String]
    }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Waraqa/Vault", isDirectory: true)
        openedDir = FileManager.default.temporaryDirectory.appendingPathComponent("VaultOpen", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        closeOpenedFiles()
        load()
    }

    private func load() {
        guard let data = try? VaultCrypto.readDecrypted(indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        documents = index.documents.filter { FileManager.default.fileExists(atPath: fileURL($0.id).path) }
        customFolders = index.customFolders
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Index(documents: documents, customFolders: customFolders)) else { return }
        try? VaultCrypto.writeEncrypted(data, to: indexURL)
    }

    private func fileURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".enc") }

    // MARK: Adding

    @discardableResult
    func add(file: URL, title: String, folder: String, kind: VaultDocument.Kind, originalID: UUID? = nil,
             spec: ProtectionSpec? = nil, pages: Int) throws -> VaultDocument {
        let data = try Data(contentsOf: file)
        let doc = VaultDocument(id: UUID(), title: String(FileNaming.sanitize(title).prefix(100)), folder: folder, kind: kind,
                                fileExtension: file.pathExtension.lowercased().isEmpty ? "pdf" : file.pathExtension.lowercased(),
                                size: Int64(data.count), created: Date(), originalID: originalID, spec: spec, pages: pages)
        try VaultCrypto.writeEncrypted(data, to: fileURL(doc.id))
        documents.insert(doc, at: 0)
        save()
        return doc
    }

    // MARK: Reading

    /// Decrypts a document into a private temporary file for viewing or sharing.
    func open(_ doc: VaultDocument) throws -> URL {
        let data = try VaultCrypto.readDecrypted(fileURL(doc.id))
        let folder = openedDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        let url = folder.appendingPathComponent(doc.fileName)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func closeOpenedFiles() {
        try? FileManager.default.removeItem(at: openedDir)
    }

    func original(of doc: VaultDocument) -> VaultDocument? {
        guard let id = doc.originalID else { return nil }
        return documents.first { $0.id == id }
    }

    func documents(in folder: String) -> [VaultDocument] {
        documents.filter { $0.folder == folder }
    }

    func search(_ query: String) -> [VaultDocument] {
        let q = ToolSearch.normalize(query)
        guard !q.isEmpty else { return documents }
        return documents.filter { ToolSearch.normalize($0.title).contains(q) }
    }

    // MARK: Changes

    func rename(_ doc: VaultDocument, to title: String) {
        let clean = FileNaming.sanitize(title)
        guard !clean.isEmpty, let i = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        documents[i].title = String(clean.prefix(100))
        save()
    }

    func move(_ doc: VaultDocument, to folder: String) {
        guard let i = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        documents[i].folder = folder
        save()
    }

    func delete(_ doc: VaultDocument) {
        try? FileManager.default.removeItem(at: fileURL(doc.id))
        documents.removeAll { $0.id == doc.id }
        // Protected copies made from it can no longer be "un-marked".
        for i in documents.indices where documents[i].originalID == doc.id { documents[i].originalID = nil }
        save()
    }

    func addFolder(_ name: String) {
        let clean = FileNaming.sanitize(name)
        guard !clean.isEmpty, !customFolders.contains(clean) else { return }
        customFolders.append(clean)
        save()
    }

    func deleteFolder(_ name: String) {
        customFolders.removeAll { $0 == name }
        for i in documents.indices where documents[i].folder == "custom:" + name { documents[i].folder = VaultFolder.other.rawValue }
        save()
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        documents = []
        customFolders = []
        closeOpenedFiles()
    }

    static func folderTitle(_ folder: String, _ lang: AppLanguage) -> String {
        if folder.hasPrefix("custom:") { return String(folder.dropFirst(7)) }
        return lang.t(VaultFolder(rawValue: folder)?.title ?? VaultFolder.other.title)
    }
}
