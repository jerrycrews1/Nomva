import SwiftUI

struct iCloudSyncSettingsView: View {
    @EnvironmentObject private var syncManager: SyncManager
    var body: some View {
        Form {
            Section {
                Label("Stored on this device", systemImage: "iphone")
                    .font(.headline)
                Text("Your food logs, water, goals, custom foods, and chat history stay in protected storage on this device. Nomva does not upload a copy of this history for cloud sync.")
            }
            Section("Weight Sync") {
                NavigationLink { WeightSyncSettingsView() } label: {
                    Label("Apple Health & Garmin Weigh-ins", systemImage: "heart.fill")
                }
                Text("Garmin Connect shares Weight with Apple Health. Nomva reads it from Apple Health and can save Nomva weigh-ins back there. Apple Health handles weight history across your Apple devices.")
            }
            Section("Existing Data") {
                Text("This update keeps your existing local history in place, including the store used by earlier iCloud versions. Previous iCloud copies are not deleted automatically; they can be managed in Apple Settings.")
                if let error = syncManager.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(NomvaTheme.warning)
                }
            }
            Section("AI Processing") {
                Text("AI food requests and photos you choose to scan are sent for processing. Weight sync does not use Nomva Cloud.")
                NavigationLink("AI & Privacy") { LLMProviderSettingsView() }
            }
        }
        .navigationTitle("Data Storage")
    }
}
