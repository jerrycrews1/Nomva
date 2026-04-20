import SwiftUI
import SwiftData

struct iCloudSyncSettingsView: View {
    @EnvironmentObject private var syncManager: SyncManager
    @Environment(\.modelContext) private var modelContext
    @State private var showRestartAlert = false
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: syncManager.iCloudEnabled ? "icloud.fill" : "icloud.slash")
                        .foregroundColor(syncManager.iCloudEnabled ? .blue : .secondary)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("iCloud Sync")
                            .font(.headline)
                        Text(syncManager.iCloudEnabled
                             ? "Your data syncs across your devices"
                             : "Data is stored only on this device")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Toggle("Sync with iCloud", isOn: Binding(
                    get: { syncManager.iCloudEnabled },
                    set: { newValue in
                        Task {
                            if newValue {
                                checking = true
                                await syncManager.enableiCloud(modelContainer: modelContext.container)
                                checking = false
                            } else {
                                syncManager.disableiCloud()
                            }
                            if !syncManager.syncStatus.isIdle && !syncManager.iCloudEnabled {
                                // Don't show restart if it failed
                            } else {
                                showRestartAlert = true
                            }
                        }
                    }
                ))
                .tint(.blue)
                .disabled(!syncManager.isAccountAvailable && !syncManager.iCloudEnabled)

                if !syncManager.isAccountAvailable && !syncManager.iCloudEnabled {
                    Label("iCloud is not signed in. Please sign in via iOS Settings to enable sync.", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if case .error(let msg) = syncManager.syncStatus {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if syncManager.iCloudEnabled, let date = syncManager.lastSyncDate {
                    Text("Last synced: \(date.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

            } footer: {
                Text("When on, your food logs and goals sync privately across your Apple devices using your iCloud account. No account is created. No one can see your data.")
            }
        }
        .navigationTitle("iCloud Sync")
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("OK") { }
        } message: {
            Text("Close and reopen the app to apply your sync changes.")
        }
    }
}
