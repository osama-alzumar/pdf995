import Foundation
import WaraqaCore

/// A certified translation order sent from this device. The owner token (needed to follow the
/// order and download the translation) is kept in the Keychain, never in this record.
struct TranslationRecord: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    var status: TranslationOrderStatus
    /// Downloaded translation, relative to the results folder.
    var resultPath: String?
    var seen: Bool
}

@MainActor
final class TranslationsStore: ObservableObject {
    static let shared = TranslationsStore()
    @Published private(set) var records: [TranslationRecord] = []

    private let url: URL
    private let tokenService = "app.waraqa.translations"

    /// Orders whose new state the user hasn't opened yet (e.g. "translation ready").
    var unseen: Int { records.filter { !$0.seen }.count }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = base.appendingPathComponent("Waraqa/translations.enc")
        if let data = try? VaultCrypto.readDecrypted(url),
           let saved = try? JSONDecoder.waraqa.decode([TranslationRecord].self, from: data) {
            records = saved
        }
    }

    private func save() {
        guard let data = try? JSONEncoder.waraqa.encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? VaultCrypto.writeEncrypted(data, to: url)
    }

    func add(_ response: CreateTranslationResponse, title: String) {
        try? Keychain.set(Data(response.ownerToken.utf8), service: tokenService, account: response.order.id)
        records.insert(TranslationRecord(id: response.order.id, title: title, status: response.order, resultPath: nil, seen: true), at: 0)
        save()
    }

    private func token(_ id: String) -> String? {
        Keychain.get(service: tokenService, account: id).flatMap { String(data: $0, encoding: .utf8) }
    }

    func refresh() async {
        guard ServerService.shared.isConfigured else { return }
        let client = ServerService.shared.client
        for i in records.indices where !records[i].status.state.isFinished || (records[i].status.hasResult && records[i].resultPath == nil) {
            guard let token = token(records[i].id),
                  let status = try? await client.translationStatus(id: records[i].id, ownerToken: token) else { continue }
            if status != records[i].status {
                if status.state != records[i].status.state || status.message != records[i].status.message { records[i].seen = false }
                records[i].status = status
            }
        }
        save()
    }

    func markSeen(_ id: String) {
        guard let i = records.firstIndex(where: { $0.id == id }), !records[i].seen else { return }
        records[i].seen = true
        save()
    }

    /// Downloads the delivered translation once and keeps it in "My files".
    func result(for id: String) async throws -> URL {
        guard let i = records.firstIndex(where: { $0.id == id }) else { throw WaraqaError.cannotOpen(fileName: "") }
        if let path = records[i].resultPath {
            let existing = FileStore.shared.results.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: existing.path) { return existing }
        }
        guard let token = token(id) else { throw WaraqaError.cannotOpen(fileName: "") }
        let folder = try FileStore.shared.newOutputFolder()
        let file = try await ServerService.shared.client.downloadTranslation(id: id, ownerToken: token, into: folder)
        let recent = FileStore.shared.record(file, tool: .translate)
        records[i].resultPath = recent.path
        save()
        return file
    }
}

extension JSONEncoder {
    static var waraqa: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

extension JSONDecoder {
    static var waraqa: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
