import Foundation
import Observation
import StoreKit

@MainActor @Observable
final class TipStore {
    static let productIDs = [
        "watchmate.tip.sml",
        "watchmate.tip.med",
        "watchmate.tip.lrg"
    ]

    // Enable Release tips only after licensing is settled and the product is approved.
    static var isEnabled: Bool {
        #if DEBUG || ENABLE_TIPS
        true
        #else
        false
        #endif
    }

    private(set) var products: [Product] = []
    private(set) var loading = false
    private(set) var purchasing = false
    private(set) var message: String?
    var hasMissingProducts: Bool { products.count < Self.productIDs.count }
    #if DEBUG
    private(set) var productDiagnostics = ""
    #endif
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init() {
        // Listen at app launch, including for purchases approved after Settings closes.
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.complete(result)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func finishUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            await complete(result)
        }
    }

    func loadProduct() async {
        guard Self.isEnabled, !loading, !purchasing, hasMissingProducts else { return }
        loading = true
        message = nil
        defer { loading = false }
        do {
            let available = try await Product.products(for: Self.productIDs)
            products = Self.productIDs.compactMap { id in
                available.first { $0.id == id && $0.type == .consumable }
            }
            #if DEBUG
            productDiagnostics = Self.productIDs.compactMap { id -> String? in
                guard let product = available.first(where: { $0.id == id }) else {
                    return "\(id): not returned by StoreKit"
                }
                return product.type == .consumable ? nil : "\(id): expected Consumable, received \(product.type)"
            }.joined(separator: "\n")
            #endif
            if products.isEmpty {
                message = String(localized: "Coffee tips are currently unavailable. Please try again later.")
            } else if hasMissingProducts {
                message = String(localized: "Some tip options are currently unavailable. You can retry loading their prices.")
            }
        } catch is CancellationError {
            return
        } catch {
            message = String(localized: "Could not load the tip price. Check your connection and try again.")
        }
    }

    func buyCoffee(_ product: Product, using purchase: @MainActor (Product) async throws -> Product.PurchaseResult) async {
        guard Self.isEnabled, !purchasing, products.contains(where: { $0.id == product.id }) else { return }
        guard StoreKit.AppStore.canMakePayments else {
            message = String(localized: "In-app purchases are not allowed on this device.")
            return
        }
        purchasing = true
        message = nil
        defer { purchasing = false }
        do {
            switch try await purchase(product) {
            case .success(let result):
                await complete(result)
            case .pending:
                message = String(localized: "Your tip is awaiting approval. Thank you! You can keep using WatchMate.")
            case .userCancelled:
                break
            @unknown default:
                message = String(localized: "The purchase could not be completed. Please try again.")
            }
        } catch is CancellationError {
            return
        } catch {
            message = String(localized: "The purchase could not be completed. Please try again.")
        }
    }

    private func complete(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            guard Self.productIDs.contains(transaction.productID),
                  transaction.productType == .consumable else { return }
            if transaction.revocationDate == nil {
                message = String(localized: "Thank you for the coffee! Your support is much appreciated.")
            }
            // Tips grant no entitlement or content, so there is nothing to restore or unlock.
            await transaction.finish()
        case .unverified(let transaction, _):
            guard Self.productIDs.contains(transaction.productID) else { return }
            message = String(localized: "Apple could not verify this purchase. Please try again later.")
        }
    }
}
