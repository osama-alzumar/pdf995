import Foundation
import WaraqaCore

/// The processing server, as configured in Info.plist (`WaraqaServerURL`, from the
/// WARAQA_SERVER_URL build setting). Empty = server tools are shown as not available in this
/// build; nothing is ever uploaded.
@MainActor
final class ServerService: ObservableObject {
    static let shared = ServerService()

    enum Availability: Equatable {
        case notConfigured
        case unknown
        case available(ServerStatus)
        case unreachable
    }

    @Published private(set) var availability: Availability = .unknown
    /// Set for the duration of one upload the user explicitly approved. Read by the client from
    /// a background thread, hence the lock.
    private let approval: UploadApproval
    let baseURL: URL?
    let client: ServerClient

    private init() {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "WaraqaServerURL") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        var configured: URL?
        if let url = URL(string: raw), url.scheme == "https" || (url.host == "127.0.0.1" && url.scheme == "http") {
            configured = url
        }
        let gate = UploadApproval()
        approval = gate
        baseURL = configured
        client = ServerClient(baseURL: configured, workDirectory: FileStore.shared.work, consent: { gate.isApproved })
        if configured == nil { availability = .notConfigured }
    }

    var isConfigured: Bool { baseURL != nil }

    var retentionMinutes: Int {
        if case .available(let s) = availability { return s.retentionMinutes }
        return 10
    }

    func refresh() async {
        guard isConfigured else { return }
        do {
            availability = .available(try await client.status())
        } catch {
            availability = .unreachable
        }
    }

    /// Runs `body` with upload permission. Call only after the user tapped "Agree".
    func withApprovedUpload<T>(_ body: (ServerClient) async throws -> T) async throws -> T {
        guard isConfigured else { throw WaraqaError.serverNotConfigured }
        approval.set(true)
        defer { approval.set(false) }
        return try await body(client)
    }
}

final class UploadApproval: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isApproved: Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}
