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
            Group {
                if containerManager.recoveryRequired {
                    VStack(spacing: 18) {
                        Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                        Text("Your saved data could not be opened").font(.title2.bold())
                        Text("Nomva has kept the existing store intact. Logging is paused so new entries cannot disappear into a temporary store. Close and reopen Nomva, or retry below.")
                        Button("Retry opening saved data") { containerManager.refreshContainer() }
                    }.padding(28)
                } else { RootView() }
            }
                .tint(NomvaTheme.accent)
                .environmentObject(syncManager)
                .environmentObject(subscriptionManager)
                .environmentObject(garminManager)
                .environmentObject(routeCenter)
                .task {
                    guard !NomvaRuntime.isAutomatedTest, !containerManager.recoveryRequired else { return }
                    await garminManager.refreshIfNeeded()
                }
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
            false // Health and nutrition records must remain in protected local storage.
        }
    }

    static let shared = ModelContainerManager()

    static let syncPreferenceKey = "icloud_sync_enabled"
    static let activeStoreKindKey = "icloud_sync_active_store_kind"
    static let lastErrorKey = "icloud_sync_last_error"

    @Published private(set) var container: ModelContainer
    @Published private(set) var activeStoreKind: StoreKind
    @Published private(set) var lastError: String?
    @Published private(set) var recoveryRequired = false

    private let schema = Schema([
        FoodEntry.self, DailyGoal.self, WeightEntry.self, WeightSyncState.self, WeightSyncTombstone.self,
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
        recoveryRequired = state.error != nil
    }

    func refreshContainer() {
        let desiredStore = Self.desiredStoreKind()
        do {
            try activate(desiredStore)
        } catch {
            lastError = "Nomva couldn't open its saved data. The existing store has been preserved."
            // Keep any already-open durable store. Startup recovery remains blocked.
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
        recoveryRequired = false
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
        if NomvaRuntime.isAutomatedTest {
            let container = createInMemoryContainer(schema: schema)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-NomvaBeverageRegression") {
                let context = container.mainContext
                context.insert(FoodEntry(name: "Gatorade Cool Blue — 12 fl oz (28 oz bottle)", brand: "Gatorade", meal: "dinner",
                    portionGrams: 0, portionDescription: "12 fl oz", servings: 1, servingUnit: "bottle",
                    calories: 80, proteinG: 0, carbsG: 22, fatG: 0, fiberG: 0, sugarG: 21, sodiumMg: 160,
                    rawUserInput: "Gatorade", source: "web_published"))
                try? context.save()
            }
            #endif
            return (container, .local, nil)
        }

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
            let message = "Nomva couldn't open its saved data. No replacement store was created."
            UserDefaults.standard.set(message, forKey: lastErrorKey)
            return (createInMemoryContainer(schema: schema), desiredStore, message)
        }
    }

    private static func desiredStoreKind() -> StoreKind {
        // The legacy cloud file remains the source of truth for existing installs.
        // Changing the mirroring policy must never switch them to an empty local file.
        if let raw = UserDefaults.standard.string(forKey: activeStoreKindKey), let kind = StoreKind(rawValue: raw) { return kind }
        return UserDefaults.standard.bool(forKey: syncPreferenceKey) ? .cloud : .local
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
        // The legacy schema mixes health records, notes and goals in one store.
        // Keep its exact file locally; do not mirror this schema to CloudKit.
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .none

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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)

        let fileName = kind == .cloud ? "nomva-cloud.store" : "nomva-local.store"
        let store = directory.appendingPathComponent(fileName)
        for suffix in ["", "-wal", "-shm"] {
            let path = store.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
            }
        }
        var nomvaDirectory = directory.deletingLastPathComponent()
        try nomvaDirectory.setResourceValues(values)
        return store
    }

    private static func createInMemoryContainer(schema: Schema) -> ModelContainer {
        let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
