import Foundation
import SwiftUI
import StoreKit

// MARK: - Product IDs

enum NomvaProduct {
    /// The auto-renewable subscription product ID.
    /// Must match exactly what you create in App Store Connect.
    static let proMonthly = "com.nerdquad.nomva.pro.monthly"
}

// MARK: - Subscription Manager

@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    // MARK: - Published State

    @AppStorage("is_premium") var isPremium: Bool = false
    @AppStorage("free_messages_used") var freeMessagesUsed: Int = 0
    @AppStorage("is_premium_dev_override") private var isDevOverride: Bool = false

    @Published var product: Product?
    @Published var purchaseState: PurchaseState = .idle
    @Published var subscriptionExpirationDate: Date?

    let freeTrialLimit = 0

    enum PurchaseState: Equatable {
        case idle, purchasing, restoring, error(String)
        
        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }
    }

    // MARK: - Transaction listener task

    private var transactionListenerTask: Task<Void, Never>?

    private init() {
        // Start listening for transactions immediately
        transactionListenerTask = listenForTransactions()

        // Fetch product + check entitlements on launch
        Task {
            await fetchProduct()
            await checkEntitlements()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Public API

    var canUseAI: Bool {
        isPremium || isDevOverride || freeMessagesUsed < freeTrialLimit
    }

    var remainingFreeMessages: Int {
        max(0, freeTrialLimit - freeMessagesUsed)
    }

    func recordAIMessage() {
        if !isPremium && !isDevOverride {
            freeMessagesUsed += 1
        }
    }

    /// Fetch the subscription product from the App Store.
    func fetchProduct() async {
        do {
            let products = try await Product.products(for: [NomvaProduct.proMonthly])
            product = products.first
        } catch {
            print("⚠️ Failed to fetch products: \(error.localizedDescription)")
        }
    }

    /// Purchase the monthly subscription.
    func purchase() async {
        guard let product else {
            purchaseState = .error("Product not available. Check your connection.")
            return
        }

        purchaseState = .purchasing

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                isPremium = true
                purchaseState = .idle

            case .userCancelled:
                purchaseState = .idle

            case .pending:
                // Ask to Buy or other pending state
                purchaseState = .idle

            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .error(error.localizedDescription)
            print("❌ Purchase failed: \(error.localizedDescription)")
        }
    }

    /// Restore purchases — checks all current entitlements.
    func restore() async {
        purchaseState = .restoring
        await checkEntitlements()
        purchaseState = .idle
    }

    // MARK: - Entitlement Checking

    /// Walk through all current entitlements and update premium status.
    func checkEntitlements() async {
        // Dev override always wins
        if isDevOverride {
            isPremium = true
            return
        }

        var foundActive = false

        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                if transaction.productID == NomvaProduct.proMonthly {
                    foundActive = true
                    subscriptionExpirationDate = transaction.expirationDate
                }
            }
        }

        isPremium = foundActive
    }

    // MARK: - Transaction Listener

    /// Listen for transactions that happen outside the app (renewals, refunds,
    /// family sharing changes, Ask to Buy approvals, etc.)
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                if let transaction = try? self?.checkVerified(result) {
                    await transaction.finish()
                    await self?.checkEntitlements()
                }
            }
        }
    }

    // MARK: - Verification

    private nonisolated func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }
}
