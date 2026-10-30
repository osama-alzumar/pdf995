import Foundation
import StoreKit
import WaraqaCore

/// In-app purchases with StoreKit 2: one consumable "protect one document" credit and the
/// Waraqa Plus subscription (monthly / yearly). Prices always come from the App Store
/// (`displayPrice`), so they are correct for every country and can change without an update.
@MainActor
final class PurchaseStore: ObservableObject {
    static let shared = PurchaseStore()

    enum ProductID {
        static let credit = "app.waraqa.ios.credit1"
        static let monthly = "app.waraqa.ios.plus.monthly"
        static let yearly = "app.waraqa.ios.plus.yearly"
        static let all = [credit, monthly, yearly]
        static let subscriptions: Set<String> = [monthly, yearly]
    }

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var entitlement: Entitlement = .free
    @Published private(set) var loadError = false
    @Published var purchasing = false

    private var updates: Task<Void, Never>?

    private init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
    }

    func start() async {
        await loadProducts()
        for await result in Transaction.unfinished { await handle(result) }
        await refreshEntitlement()
    }

    func loadProducts() async {
        do {
            let list = try await Product.products(for: ProductID.all)
            products = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            loadError = list.isEmpty
        } catch {
            loadError = true
        }
    }

    func refreshEntitlement() async {
        var best: Entitlement = .free
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, ProductID.subscriptions.contains(t.productID), t.revocationDate == nil else { continue }
            best = .subscribed(renews: t.expirationDate, monthlyAllowance: PlanRules.monthlyAllowance)
        }
        entitlement = best
    }

    enum Outcome { case success, pending, cancelled }

    func buy(_ id: String) async throws -> Outcome {
        guard let product = products[id] else { throw WaraqaError.serverUnavailable }
        purchasing = true
        defer { purchasing = false }
        switch try await product.purchase() {
        case .success(let result):
            await handle(result)
            return .success
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlement()
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return } // unverified: never granted
        if transaction.productID == ProductID.credit, transaction.revocationDate == nil {
            let quota = QuotaStore.shared
            if quota.markProcessed(transaction.id) {
                quota.update { $0.credits += transaction.purchasedQuantity }
            }
        }
        await transaction.finish()
        await refreshEntitlement()
    }
}
