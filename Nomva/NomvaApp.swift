import SwiftUI
import SwiftData
import CloudKit
import Combine

@main
struct NomvaApp: App {
    @StateObject private var containerManager = ModelContainerManager.shared
    @StateObject private var syncManager = SyncManager.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var garminManager = GarminManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(syncManager)
                .environmentObject(subscriptionManager)
                .environmentObject(garminManager)
                .task { await subscriptionManager.checkEntitlements() }
                .task { await garminManager.refreshIfNeeded() }
        }
        .modelContainer(containerManager.container)
    }
}

/// Manages the ModelContainer lifecycle and handles switching between local and iCloud-backed storage.
@MainActor
final class ModelContainerManager: ObservableObject {
    static let shared = ModelContainerManager()
    
    @Published private(set) var container: ModelContainer
    
    private let schema = Schema([
        FoodEntry.self, DailyGoal.self, WeightEntry.self,
        ChatMessage.self, CustomFood.self, UserProfile.self,
        MealTemplate.self, WaterEntry.self, LoggingSession.self,
        AgentTraceRecord.self, ResolvedFoodEvidence.self
    ])
    
    private let cloudKitContainerIdentifier = "iCloud.com.nomva.app"
    
    private init() {
        self.container = Self.createInitialContainer(schema: schema, cloudKitIdentifier: cloudKitContainerIdentifier)
        
        NotificationCenter.default.addObserver(
            forName: .iCloudSyncPreferenceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Re-initialize container live
            self?.refreshContainer()
        }
    }
    
    func refreshContainer() {
        self.container = Self.createInitialContainer(schema: schema, cloudKitIdentifier: cloudKitContainerIdentifier)
    }
    
    private static func createInitialContainer(schema: Schema, cloudKitIdentifier: String) -> ModelContainer {
        let shouldUseCloudKit = UserDefaults.standard.bool(forKey: "icloud_sync_enabled")

        if shouldUseCloudKit {
            let cloudConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private(cloudKitIdentifier)
            )
            
            do {
                print("✅ Creating iCloud-backed ModelContainer")
                return try ModelContainer(for: schema, configurations: [cloudConfig])
            } catch {
                print("❌ Failed to create iCloud container, falling back to local: \(error)")
                return createLocalContainer(schema: schema)
            }
        } else {
            print("✅ Creating local-only ModelContainer")
            return createLocalContainer(schema: schema)
        }
    }
    
    private static func createLocalContainer(schema: Schema) -> ModelContainer {
        let localConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [localConfig])
        } catch {
            fatalError("❌ Could not create even a local ModelContainer: \(error)")
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
