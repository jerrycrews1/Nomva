import SwiftUI
import SwiftData
import CloudKit

@main
struct NomvaApp: App {
    @StateObject private var containerManager = ModelContainerManager.shared
    @StateObject private var syncManager = SyncManager.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var garminManager = GarminManager.shared
    @StateObject private var routeCenter = NomvaRouteCenter.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(NomvaTheme.accent)
                .environmentObject(syncManager)
                .environmentObject(subscriptionManager)
                .environmentObject(garminManager)
                .environmentObject(routeCenter)
                .task { await subscriptionManager.checkEntitlements() }
                .task { await garminManager.refreshIfNeeded() }
                .onOpenURL { url in
                    routeCenter.handle(url: url)
                }
        }
        .modelContainer(containerManager.container)
    }
}

/// Manages the ModelContainer lifecycle and switching between local and CloudKit-backed stores.
@MainActor
final class ModelContainerManager: ObservableObject {
    enum StoreKind: String {
        case local
        case cloud

        var syncEnabled: Bool {
            self == .cloud
        }
    }

    static let shared = ModelContainerManager()

    static let syncPreferenceKey = "icloud_sync_enabled"
    static let activeStoreKindKey = "icloud_sync_active_store_kind"
    static let lastErrorKey = "icloud_sync_last_error"

    @Published private(set) var container: ModelContainer
    @Published private(set) var activeStoreKind: StoreKind
    @Published private(set) var lastError: String?

    private let schema = Schema([
        FoodEntry.self, DailyGoal.self, WeightEntry.self,
        ChatMessage.self, CustomFood.self, UserProfile.self,
        MealTemplate.self, WaterEntry.self, LoggingSession.self,
        AgentTraceRecord.self, ResolvedFoodEvidence.self
    ])

    private let cloudKitContainerIdentifier = "iCloud.com.nomva.app"

    private init() {
        let state = Self.createInitialState(
            schema: schema,
            cloudKitIdentifier: cloudKitContainerIdentifier
        )
        container = state.container
        activeStoreKind = state.kind
        lastError = state.error
    }

    func refreshContainer() {
        let desiredStore = Self.desiredStoreKind()
        do {
            try activate(desiredStore)
        } catch {
            let fallbackMessage = "Nomva couldn't open the \(desiredStore == .cloud ? "iCloud" : "local") store, so it stayed on this device only."
            UserDefaults.standard.set(false, forKey: Self.syncPreferenceKey)
            persistRuntimeState(kind: .local, error: fallbackMessage)
            container = Self.makeLocalFallbackContainer(schema: schema)
            activeStoreKind = .local
            lastError = fallbackMessage
        }
    }

    func makeAuxiliaryContainer(for kind: StoreKind) throws -> ModelContainer {
        try Self.makeContainer(
            schema: schema,
            storeKind: kind,
            cloudKitIdentifier: cloudKitContainerIdentifier
        )
    }

    func activate(_ kind: StoreKind, using preparedContainer: ModelContainer? = nil) throws {
        let targetContainer = try preparedContainer ?? Self.makeContainer(
            schema: schema,
            storeKind: kind,
            cloudKitIdentifier: cloudKitContainerIdentifier
        )
        container = targetContainer
        activeStoreKind = kind
        lastError = nil
        persistRuntimeState(kind: kind, error: nil)
    }

    private func persistRuntimeState(kind: StoreKind, error: String?) {
        UserDefaults.standard.set(kind.syncEnabled, forKey: Self.syncPreferenceKey)
        UserDefaults.standard.set(kind.rawValue, forKey: Self.activeStoreKindKey)
        UserDefaults.standard.set(error, forKey: Self.lastErrorKey)
    }

    private static func createInitialState(
        schema: Schema,
        cloudKitIdentifier: String
    ) -> (container: ModelContainer, kind: StoreKind, error: String?) {
        let desiredStore = desiredStoreKind()
        do {
            let container = try makeContainer(
                schema: schema,
                storeKind: desiredStore,
                cloudKitIdentifier: cloudKitIdentifier
            )
            UserDefaults.standard.set(desiredStore.rawValue, forKey: activeStoreKindKey)
            UserDefaults.standard.removeObject(forKey: lastErrorKey)
            return (container, desiredStore, nil)
        } catch {
            let message = "Nomva couldn't open the iCloud store on launch, so it fell back to local-only data on this device."
            UserDefaults.standard.set(false, forKey: syncPreferenceKey)
            UserDefaults.standard.set(StoreKind.local.rawValue, forKey: activeStoreKindKey)
            UserDefaults.standard.set(message, forKey: lastErrorKey)
            return (makeLocalFallbackContainer(schema: schema), .local, message)
        }
    }

    private static func desiredStoreKind() -> StoreKind {
        UserDefaults.standard.bool(forKey: syncPreferenceKey) ? .cloud : .local
    }

    private static func makeContainer(
        schema: Schema,
        storeKind: StoreKind,
        cloudKitIdentifier: String
    ) throws -> ModelContainer {
        let configuration = try makeConfiguration(
            schema: schema,
            storeKind: storeKind,
            cloudKitIdentifier: cloudKitIdentifier
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func makeConfiguration(
        schema: Schema,
        storeKind: StoreKind,
        cloudKitIdentifier: String
    ) throws -> ModelConfiguration {
        let url = try storeURL(for: storeKind)
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = storeKind == .cloud
            ? .private(cloudKitIdentifier)
            : .none

        return ModelConfiguration(
            storeKind == .cloud ? "NomvaCloud" : "NomvaLocal",
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: cloudKitDatabase
        )
    }

    private static func storeURL(for kind: StoreKind) throws -> URL {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "ModelContainerManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Application Support directory is unavailable."]
            )
        }

        let directory = baseURL
            .appendingPathComponent("Nomva", isDirectory: true)
            .appendingPathComponent("Stores", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = kind == .cloud ? "nomva-cloud.store" : "nomva-local.store"
        return directory.appendingPathComponent(fileName)
    }

    private static func makeLocalFallbackContainer(schema: Schema) -> ModelContainer {
        let localConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [localConfig])
        } catch {
            return createInMemoryContainer(schema: schema)
        }
    }

    private static func createInMemoryContainer(schema: Schema) -> ModelContainer {
        let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [inMemoryConfig])
        } catch {
            fatalError("Could not create fallback in-memory ModelContainer: \(error)")
        }
    }
}

struct RootView: View {
    @AppStorage("onboarding_complete") private var onboardingComplete = false

    var body: some View {
        if onboardingComplete {
            ContentView()
        } else {
            OnboardingCoordinatorView()
        }
    }
}
