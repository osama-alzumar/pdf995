import Foundation
import WaraqaCore

/// A secure link the user created. The owner token (needed to see opens or revoke) is kept in
/// the Keychain, never in this record.
struct ShareRecord: Codable, Identifiable, Hashable {
    let id: String
    let url: String
    let documentTitle: String
    let recipient: String
    let purpose: String
    let created: Date
    let expires: Date
    let maxViews: Int
    let allowDownload: Bool
    var state: ShareState
    var opens: Int
    var lastOpened: Date?
    var lastChecked: Date?

    /// State as far as the device knows (expiry needs no server call).
    var effectiveState: ShareState {
        if state == .active && Date() >= expires { return .expired }
        return state
    }
}

@MainActor
final class SharesStore: ObservableObject {
    static let shared = SharesStore()
    @Published private(set) var records: [ShareRecord] = []
    /// Opens noticed since the user last looked (shown as a badge / banner).
    @Published private(set) var newOpens = 0

    private let url: URL
    private let tokenService = "app.waraqa.shares"

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = base.appendingPathComponent("Waraqa/shares.enc")
        if let data = try? VaultCrypto.readDecrypted(url), let saved = try? JSONDecoder().decode([ShareRecord].self, from: data) {
            records = saved
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? VaultCrypto.writeEncrypted(data, to: url)
    }

    func add(_ response: CreateShareResponse, title: String, recipient: String, purpose: String,
             maxViews: Int, allowDownload: Bool) {
        try? Keychain.set(Data(response.ownerToken.utf8), service: tokenService, account: response.id)
        let record = ShareRecord(id: response.id, url: response.url, documentTitle: title, recipient: recipient, purpose: purpose,
                                 created: Date(), expires: response.expiresAt, maxViews: maxViews, allowDownload: allowDownload,
                                 state: .active, opens: 0, lastOpened: nil, lastChecked: Date())
        records.insert(record, at: 0)
        save()
    }

    private func token(_ id: String) -> String? {
        Keychain.get(service: tokenService, account: id).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Asks the server for opens and state of every link that can still change.
    func refresh() async {
        let client = ServerService.shared.client
        guard ServerService.shared.isConfigured else { return }
        for i in records.indices where records[i].state == .active {
            guard let token = token(records[i].id),
                  let status = try? await client.shareStatus(id: records[i].id, ownerToken: token) else { continue }
            if status.opens > records[i].opens { newOpens += status.opens - records[i].opens }
            records[i].opens = status.opens
            records[i].state = status.state
            records[i].lastOpened = status.lastOpenedAt
            records[i].lastChecked = Date()
        }
        save()
    }

    func revoke(_ record: ShareRecord) async throws {
        guard let token = token(record.id) else { throw WaraqaError.serverRejected(message: "") }
        let status = try await ServerService.shared.client.revokeShare(id: record.id, ownerToken: token)
        if let i = records.firstIndex(where: { $0.id == record.id }) {
            records[i].state = status.state
            records[i].opens = status.opens
        }
        save()
    }

    func forget(_ record: ShareRecord) {
        Keychain.delete(service: tokenService, account: record.id)
        records.removeAll { $0.id == record.id }
        save()
    }

    func clearNewOpens() { newOpens = 0 }
}
