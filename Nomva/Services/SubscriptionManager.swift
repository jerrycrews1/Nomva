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

    @AppStorage("is_premium") private var hasVerifiedSubscription: Bool = false
    @AppStorage("free_messages_used") var freeMessagesUsed: Int = 0

    @Published var product: Product?
    @Published var purchaseState: PurchaseState = .idle
    @Published var subscriptionExpirationDate: Date?
    @Published private(set) var hasTestFlightAccess: Bool

    let freeTrialLimit = 0

    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case restoring
        case error(String)
        case notice(String)

        var isBusy: Bool {
            switch self {
            case .purchasing, .restoring:
                return true
            case .idle, .error, .notice:
                return false
            }
        }

        var feedbackMessage: String? {
            switch self {
            case .error(let message), .notice(let message):
                return message
            case .idle, .purchasing, .restoring:
                return nil
            }
        }

        var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    // MARK: - Transaction listener task

    private var transactionListenerTask: Task<Void, Never>?
    private let legacyDevOverrideKey = "is_premium_dev_override"

    private init() {
        hasTestFlightAccess = SubscriptionAccessPolicy.grantsComplimentaryProAccess(
            receiptURL: Bundle.main.appStoreReceiptURL
        )
        UserDefaults.standard.removeObject(forKey: legacyDevOverrideKey)

        if !hasTestFlightAccess {
            transactionListenerTask = listenForTransactions()
        }

        Task {
            if !hasTestFlightAccess {
                await fetchProduct()
                await checkEntitlements()
            }
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Public API

    var isPremium: Bool {
        hasTestFlightAccess || hasVerifiedSubscription
    }

    var canUseAI: Bool {
        isPremium || freeMessagesUsed < freeTrialLimit
    }

    var remainingFreeMessages: Int {
        max(0, freeTrialLimit - freeMessagesUsed)
    }

    func recordAIMessage() {
        if !isPremium {
            freeMessagesUsed += 1
        }
    }

    /// Fetch the subscription product from the App Store.
    func fetchProduct() async {
        guard !hasTestFlightAccess else { return }

        do {
            let products = try await Product.products(for: [NomvaProduct.proMonthly])
            product = products.first
        } catch {
            print("⚠️ Failed to fetch products: \(error.localizedDescription)")
        }
    }

    /// Purchase the monthly subscription.
    func purchase() async {
        guard !hasTestFlightAccess else {
            purchaseState = .notice("Nomva Pro is already unlocked for this TestFlight build.")
            return
        }

        guard let product else {
            purchaseState = .error("Nomva Pro is temporarily unavailable. Please try again.")
            return
        }

        purchaseState = .purchasing

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                setVerifiedSubscription(true)
                purchaseState = .idle

            case .userCancelled:
                purchaseState = .idle

            case .pending:
                purchaseState = .notice("Your purchase is pending approval.")

            @unknown default:
                purchaseState = .idle
            }
        } catch is CancellationError {
            purchaseState = .idle
        } catch {
            purchaseState = .error(
                SubscriptionErrorCopy.message(for: error, operation: .purchase)
            )
            print("❌ Purchase failed: \(error.localizedDescription)")
        }
    }

    /// Restore purchases — checks all current entitlements.
    func restore() async {
        guard !hasTestFlightAccess else {
            purchaseState = .notice("Nomva Pro is already unlocked for this TestFlight build.")
            return
        }

        purchaseState = .restoring
        do {
            try await AppStore.sync()
        } catch is CancellationError {
            purchaseState = .idle
            return
        } catch {
            purchaseState = .error(
                SubscriptionErrorCopy.message(for: error, operation: .restore)
            )
            print("❌ Restore failed: \(error.localizedDescription)")
            return
        }

        await checkEntitlements()
        purchaseState = hasVerifiedSubscription
            ? .notice("Your Nomva Pro purchase was restored.")
            : .notice("No active Nomva Pro subscription was found.")
    }

    // MARK: - Entitlement Checking

    /// Walk through all current entitlements and update premium status.
    func checkEntitlements() async {
        guard !hasTestFlightAccess else { return }

        var foundActive = false
        var expirationDate: Date?

        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                if transaction.productID == NomvaProduct.proMonthly {
                    foundActive = true
                    expirationDate = transaction.expirationDate
                }
            }
        }

        subscriptionExpirationDate = expirationDate
        setVerifiedSubscription(foundActive)
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

    private func setVerifiedSubscription(_ isActive: Bool) {
        guard hasVerifiedSubscription != isActive else { return }
        objectWillChange.send()
        hasVerifiedSubscription = isActive
    }
}
