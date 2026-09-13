import SwiftUI
import Combine

/// Storage status only. Weigh-ins sync through HealthKit; the application store
/// remains on-device, including the existing file used by older iCloud installs.
@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    @Published private(set) var lastErrorMessage: String?
    private var observer: AnyCancellable?
    private init() {
        lastErrorMessage = ModelContainerManager.shared.lastError
        observer = ModelContainerManager.shared.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastErrorMessage = $0 }
    }
}
