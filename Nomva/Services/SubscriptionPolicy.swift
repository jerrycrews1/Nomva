import Foundation

enum SubscriptionAccessPolicy {
    private static let testFlightReceiptName = "sandboxReceipt"

    static func grantsComplimentaryProAccess(receiptURL: URL?) -> Bool {
        guard let receiptURL else { return false }
        return receiptURL.lastPathComponent.caseInsensitiveCompare(testFlightReceiptName) == .orderedSame
    }
}

enum SubscriptionOperation {
    case purchase
    case restore
}

enum SubscriptionErrorCopy {
    static func message(for error: Error, operation: SubscriptionOperation) -> String {
        let nsError = error as NSError
        return message(domain: nsError.domain, operation: operation)
    }

    static func message(domain: String, operation: SubscriptionOperation) -> String {
        if domain.caseInsensitiveCompare(NSURLErrorDomain) == .orderedSame {
            return "Check your internet connection and try again."
        }

        let normalizedDomain = domain.lowercased()
        let isAppStoreError = normalizedDomain.hasPrefix("sk")
            || normalizedDomain.contains("storekit")
            || normalizedDomain.hasPrefix("asd")
            || normalizedDomain.hasPrefix("ams")

        if isAppStoreError {
            switch operation {
            case .purchase:
                return "The App Store couldn't complete the purchase. Please try again."
            case .restore:
                return "The App Store couldn't restore purchases right now. Please try again."
            }
        }

        switch operation {
        case .purchase:
            return "We couldn't complete the purchase. Please try again."
        case .restore:
            return "We couldn't restore purchases right now. Please try again."
        }
    }
}
