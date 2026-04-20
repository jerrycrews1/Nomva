import SwiftUI
import SwiftData
import CloudKit

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published var iCloudEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(iCloudEnabled, forKey: userDefaultsKey)
            NotificationCenter.default.post(name: .iCloudSyncPreferenceChanged, object: nil)
        }
    }
    @Published private(set) var syncStatus: SyncStatus = .idle
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var isAccountAvailable: Bool = false

    private let userDefaultsKey = "icloud_sync_enabled"

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case error(String)
        case success
        
        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }
    }

    private init() {
        iCloudEnabled = UserDefaults.standard.bool(forKey: userDefaultsKey)
        Task { await updateAccountStatus() }
    }

    func updateAccountStatus() async {
        let status = try? await CKContainer.default().accountStatus()
        isAccountAvailable = (status == .available)
    }

    func enableiCloud(modelContainer: ModelContainer) async {
        await updateAccountStatus()
        guard isAccountAvailable else {
            syncStatus = .error("No iCloud account found. Sign in to iCloud in your device Settings.")
            iCloudEnabled = false
            return
        }

        iCloudEnabled = true
        syncStatus = .syncing
    }

    func disableiCloud() {
        iCloudEnabled = false
        syncStatus = .idle
    }
}

extension Notification.Name {
    static let iCloudSyncPreferenceChanged = Notification.Name("iCloudSyncPreferenceChanged")
}
