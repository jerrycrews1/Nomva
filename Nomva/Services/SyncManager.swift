import SwiftUI
import SwiftData
import CloudKit
import Combine

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    enum SyncStatus: Equatable {
        case idle
        case working(String)
        case success(String)
        case error(String)

        var message: String? {
            switch self {
            case .idle:
                return nil
            case .working(let message), .success(let message), .error(let message):
                return message
            }
        }

        var isWorking: Bool {
            if case .working = self {
                return true
            }
            return false
        }
    }

    @Published private(set) var syncStatus: SyncStatus = .idle
    @Published private(set) var lastTransferDate: Date?
    @Published private(set) var lastBackupURL: URL?
    @Published private(set) var isAccountAvailable: Bool = false
    @Published private(set) var activeStoreKind: ModelContainerManager.StoreKind
    @Published private(set) var lastErrorMessage: String?

    var iCloudEnabled: Bool {
        activeStoreKind == .cloud
    }

    var isBusy: Bool {
        syncStatus.isWorking
    }

    var lastBackupFilename: String? {
        lastBackupURL?.lastPathComponent
    }

    private let cloudContainer = CKContainer(identifier: "iCloud.com.nomva.app")
    private let lastTransferDateKey = "icloud_sync_last_transfer_date"
    private let lastBackupPathKey = "icloud_sync_last_backup_path"
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        activeStoreKind = ModelContainerManager.shared.activeStoreKind
        lastErrorMessage = ModelContainerManager.shared.lastError

        if let storedDate = UserDefaults.standard.object(forKey: lastTransferDateKey) as? Date {
            lastTransferDate = storedDate
        }

        if let storedPath = UserDefaults.standard.string(forKey: lastBackupPathKey) {
            lastBackupURL = URL(fileURLWithPath: storedPath)
        }

        bindContainerManager()

        if let lastErrorMessage {
            syncStatus = .error(lastErrorMessage)
        }

        Task {
            await updateAccountStatus()
        }
    }

    func updateAccountStatus() async {
        let status = try? await cloudContainer.accountStatus()
        isAccountAvailable = (status == .available)
    }

    func enableiCloud(modelContainer _: ModelContainer? = nil) async {
        await setSyncEnabled(true)
    }

    func disableiCloud() async {
        await setSyncEnabled(false)
    }

    func setSyncEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }

        if enabled == iCloudEnabled {
            syncStatus = .success(enabled ? "iCloud sync is already active." : "Your data is already staying on this device only.")
            return
        }

        if enabled {
            await enableCloudSync()
        } else {
            await disableCloudSync()
        }
    }

    private func enableCloudSync() async {
        syncStatus = .working("Checking your iCloud account…")
        await updateAccountStatus()

        guard isAccountAvailable else {
            let message = "Sign into iCloud in iPhone Settings before turning sync on."
            lastErrorMessage = message
            syncStatus = .error(message)
            return
        }

        do {
            let sourceContainer = ModelContainerManager.shared.container

            syncStatus = .working("Creating a protected local backup…")
            let localArchive = try SyncMigrationService.captureArchive(
                from: sourceContainer,
                storeKind: .local
            )
            let backupURL = try SyncMigrationService.writeArchive(localArchive, reason: "enable-cloud")

            syncStatus = .working("Preparing the iCloud store…")
            let cloudContainer = try ModelContainerManager.shared.makeAuxiliaryContainer(for: .cloud)
            let deletionBaseline = SyncMigrationService.loadBaseline()

            syncStatus = .working("Moving your data into the iCloud store…")
            let counts = try SyncMigrationService.merge(
                archive: localArchive,
                into: cloudContainer,
                deletionBaseline: deletionBaseline
            )
            SyncMigrationService.clearBaseline()

            try ModelContainerManager.shared.activate(.cloud, using: cloudContainer)

            lastTransferDate = .now
            lastBackupURL = backupURL
            lastErrorMessage = nil
            persistMetadata()

            let touchedCount = counts.totalTouched
            let summary = touchedCount > 0
                ? "iCloud sync is active. Prepared \(touchedCount) records and kept your local copy safe."
                : "iCloud sync is active. Your local copy was backed up and the cloud store is ready."
            syncStatus = .success(summary)
        } catch {
            let message = "Nomva couldn't turn iCloud sync on safely. Your local data was left untouched."
            lastErrorMessage = message
            syncStatus = .error(message)
        }
    }

    private func disableCloudSync() async {
        do {
            let sourceContainer = ModelContainerManager.shared.container

            syncStatus = .working("Creating a protected iCloud backup…")
            let cloudArchive = try SyncMigrationService.captureArchive(
                from: sourceContainer,
                storeKind: .cloud
            )
            let backupURL = try SyncMigrationService.writeArchive(cloudArchive, reason: "disable-cloud")

            syncStatus = .working("Restoring the on-device store from your synced data…")
            let localContainer = try ModelContainerManager.shared.makeAuxiliaryContainer(for: .local)
            _ = try SyncMigrationService.replaceStore(with: cloudArchive, in: localContainer)
            try SyncMigrationService.saveBaseline(cloudArchive.baseline)

            try ModelContainerManager.shared.activate(.local, using: localContainer)

            lastTransferDate = .now
            lastBackupURL = backupURL
            lastErrorMessage = nil
            persistMetadata()

            syncStatus = .success("iCloud sync is off. Your data now lives in the preserved on-device store, and the iCloud copy was not deleted.")
        } catch {
            let message = "Nomva couldn't switch back to the on-device store safely, so it left your synced data alone."
            lastErrorMessage = message
            syncStatus = .error(message)
        }
    }

    private func persistMetadata() {
        UserDefaults.standard.set(lastTransferDate, forKey: lastTransferDateKey)
        UserDefaults.standard.set(lastBackupURL?.path, forKey: lastBackupPathKey)
        UserDefaults.standard.set(lastErrorMessage, forKey: ModelContainerManager.lastErrorKey)
    }

    private func bindContainerManager() {
        let manager = ModelContainerManager.shared

        manager.$activeStoreKind
            .receive(on: RunLoop.main)
            .sink { [weak self] kind in
                self?.activeStoreKind = kind
            }
            .store(in: &cancellables)

        manager.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard let self else { return }
                self.lastErrorMessage = error
                if let error, !self.syncStatus.isWorking {
                    self.syncStatus = .error(error)
                }
            }
            .store(in: &cancellables)
    }
}
