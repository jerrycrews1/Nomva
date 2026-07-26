import Darwin
import Foundation

@main
struct SubscriptionPolicyTests {
    private static var passed = 0
    private static var failed = 0

    static func main() {
        check(
            SubscriptionAccessPolicy.grantsComplimentaryProAccess(
                receiptURL: URL(fileURLWithPath: "/app/StoreKit/sandboxReceipt")
            ),
            "TestFlight sandbox receipt grants access"
        )
        check(
            SubscriptionAccessPolicy.grantsComplimentaryProAccess(
                receiptURL: URL(fileURLWithPath: "/app/StoreKit/SANDBOXRECEIPT")
            ),
            "TestFlight receipt comparison is case insensitive"
        )
        check(
            !SubscriptionAccessPolicy.grantsComplimentaryProAccess(
                receiptURL: URL(fileURLWithPath: "/app/StoreKit/receipt")
            ),
            "Production receipt does not grant complimentary access"
        )
        check(
            !SubscriptionAccessPolicy.grantsComplimentaryProAccess(receiptURL: nil),
            "Missing receipt does not grant complimentary access"
        )
        check(
            !SubscriptionAccessPolicy.grantsComplimentaryProAccess(
                receiptURL: URL(fileURLWithPath: "/app/StoreKit/debug")
            ),
            "Unknown receipt does not grant complimentary access"
        )

        let purchaseStoreError = SubscriptionErrorCopy.message(
            domain: "SKInternalErrorDomain",
            operation: .purchase
        )
        check(
            purchaseStoreError == "The App Store couldn't complete the purchase. Please try again.",
            "Internal StoreKit purchase error gets friendly copy"
        )
        check(
            !purchaseStoreError.contains("SKInternalErrorDomain"),
            "Internal StoreKit domain is never exposed"
        )

        let restoreStoreError = SubscriptionErrorCopy.message(
            domain: "SKErrorDomain",
            operation: .restore
        )
        check(
            restoreStoreError == "The App Store couldn't restore purchases right now. Please try again.",
            "StoreKit restore error gets friendly copy"
        )
        check(
            SubscriptionErrorCopy.message(
                domain: NSURLErrorDomain,
                operation: .restore
            ) == "Check your internet connection and try again.",
            "Network failures get actionable copy"
        )
        check(
            SubscriptionErrorCopy.message(
                domain: "UnexpectedSubscriptionFailure",
                operation: .purchase
            ) == "We couldn't complete the purchase. Please try again.",
            "Unknown purchase failures get safe fallback copy"
        )

        print("Subscription policy tests: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            passed += 1
            print("PASS: \(name)")
        } else {
            failed += 1
            print("FAIL: \(name)")
        }
    }
}
