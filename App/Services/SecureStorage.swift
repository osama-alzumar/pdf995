import Foundation
import Security
import CryptoKit
import LocalAuthentication
import WaraqaCore

/// Small Keychain wrapper (generic passwords). Items never sync to iCloud and are readable
/// only while the device is unlocked, on this device.
enum Keychain {
    static func set(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw WaraqaError.writeFailed }
    }

    static func get(service: String, account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// AES-256-GCM with a random key created on first use and kept only in the Keychain.
/// Used for the documents wallet and the share records.
enum VaultCrypto {
    private static let service = "app.waraqa.vault"

    static func key() throws -> SymmetricKey {
        if let data = Keychain.get(service: service, account: "key-v1"), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try Keychain.set(key.withUnsafeBytes { Data($0) }, service: service, account: "key-v1")
        return key
    }

    static func seal(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key()).combined else { throw WaraqaError.writeFailed }
        return combined
    }

    static func open(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key())
    }

    static func writeEncrypted(_ data: Data, to url: URL) throws {
        do {
            try seal(data).write(to: url, options: [.atomic, .completeFileProtection])
        } catch let error as WaraqaError {
            throw error
        } catch {
            throw (error as NSError).code == NSFileWriteOutOfSpaceError ? WaraqaError.notEnoughStorage : WaraqaError.writeFailed
        }
    }

    static func readDecrypted(_ url: URL) throws -> Data {
        try open(Data(contentsOf: url))
    }
}

/// Face ID / passcode gate for the wallet. Locks again whenever the app leaves the foreground.
@MainActor
final class VaultLock: ObservableObject {
    static let shared = VaultLock()
    @Published private(set) var isUnlocked = false
    @Published var lastError: String?

    var lockEnabled: Bool {
        get {
            #if DEBUG
            // UI tests: the simulator can't answer Face ID prompts. The wallet stays encrypted.
            if ProcessInfo.processInfo.arguments.contains("-WaraqaUITestUnlocked") { return false }
            #endif
            return UserDefaults.standard.object(forKey: "vaultLockEnabled") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "vaultLockEnabled"); objectWillChange.send() }
    }

    var biometryName: LocalizedText {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return LocalizedText("Face ID", "Face ID")
        case .touchID: return LocalizedText("Touch ID", "Touch ID")
        default: return LocalizedText("رمز الجهاز", "device passcode")
        }
    }

    func unlock(reason: String) async {
        guard lockEnabled else { isUnlocked = true; return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode on the device: the wallet is still encrypted, but can't be gated.
            isUnlocked = true
            return
        }
        do {
            isUnlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            lastError = nil
        } catch {
            isUnlocked = false
            lastError = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
        }
    }

    func lock() {
        isUnlocked = !lockEnabled
    }
}

/// Free uses, purchased credits and monthly usage. Kept in the Keychain so deleting and
/// reinstalling the app does not reset the free documents.
@MainActor
final class QuotaStore: ObservableObject {
    static let shared = QuotaStore()
    private let service = "app.waraqa.quota"
    @Published private(set) var quota: ProtectionQuota

    private init() {
        if let data = Keychain.get(service: "app.waraqa.quota", account: "v1"),
           let saved = try? JSONDecoder().decode(ProtectionQuota.self, from: data) {
            quota = saved
        } else {
            quota = ProtectionQuota()
        }
    }

    func update(_ change: (inout ProtectionQuota) -> Void) {
        change(&quota)
        if let data = try? JSONEncoder().encode(quota) {
            try? Keychain.set(data, service: service, account: "v1")
        }
    }

    /// Transactions already credited, so a replayed transaction never adds a credit twice.
    func markProcessed(_ transactionID: UInt64) -> Bool {
        let account = "tx-\(transactionID)"
        if Keychain.get(service: service, account: account) != nil { return false }
        try? Keychain.set(Data([1]), service: service, account: account)
        return true
    }
}

/// Start of the free PDF-tools trial, kept in the Keychain so reinstalling doesn't restart it.
@MainActor
final class ToolTrialStore: ObservableObject {
    static let shared = ToolTrialStore()
    let trial: ToolTrial

    private init() {
        let service = "app.waraqa.trial"
        if let data = Keychain.get(service: service, account: "tools-v1"),
           let seconds = Double(String(decoding: data, as: UTF8.self)) {
            trial = ToolTrial(started: Date(timeIntervalSince1970: seconds))
        } else {
            let now = Date()
            try? Keychain.set(Data(String(now.timeIntervalSince1970).utf8), service: service, account: "tools-v1")
            trial = ToolTrial(started: now)
        }
    }

    func allowsTools(_ entitlement: Entitlement) -> Bool {
        #if DEBUG
        // UI tests: show the screen after the trial has ended.
        if ProcessInfo.processInfo.arguments.contains("-WaraqaTrialEnded") { return entitlement != .free }
        #endif
        return trial.allowsTools(entitlement)
    }

    var daysLeft: Int {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-WaraqaTrialEnded") { return 0 }
        #endif
        return trial.daysLeft()
    }
}
