import SwiftUI

struct iCloudSyncSettingsView: View {
    @EnvironmentObject private var syncManager: SyncManager

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: syncManager.iCloudEnabled ? "icloud.fill" : "iphone")
                        .foregroundColor(syncManager.iCloudEnabled ? NomvaTheme.info : .secondary)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(syncManager.iCloudEnabled ? "iCloud Sync Is On" : "Stored on This Device")
                            .font(.headline)
                        Text(syncManager.iCloudEnabled
                             ? "Your history stays in sync on your Apple devices."
                             : "Your history stays on this device.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { syncManager.iCloudEnabled },
                    set: { newValue in
                        Task {
                            await syncManager.setSyncEnabled(newValue)
                        }
                    }
                ))
                .tint(NomvaTheme.info)
                .disabled(syncManager.isBusy || (!syncManager.isAccountAvailable && !syncManager.iCloudEnabled))

                if syncManager.isBusy, let message = syncManager.syncStatus.message {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if case .success(let message) = syncManager.syncStatus {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(NomvaTheme.success)
                } else if case .error(let message) = syncManager.syncStatus {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(NomvaTheme.warning)
                } else if !syncManager.isAccountAvailable && !syncManager.iCloudEnabled {
                    Label("Sign in to iCloud on this device to turn sync on. Nomva will keep your data here for now.", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption)
                        .foregroundColor(NomvaTheme.warning)
                }
            } footer: {
                Text("Turn sync on to merge this device into iCloud. Turn it off to keep a copy here without deleting the iCloud copy.")
            }

            if syncManager.lastTransferDate != nil || syncManager.lastErrorMessage != nil {
                Section("Last Transfer") {
                    if let date = syncManager.lastTransferDate {
                        LabeledContent("Completed") {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    if let summary = syncManager.lastTransferSummary {
                        LabeledContent("Records") {
                            Text(summary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if let backup = syncManager.lastBackupFilename {
                        LabeledContent("Safety Backup") {
                            Text(backup)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if let issue = syncManager.lastErrorMessage {
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(NomvaTheme.warning)
                    }
                }
            }

            Section {
                syncItemRow("Food logs & water entries", systemImage: "fork.knife")
                syncItemRow("Weight history", systemImage: "scalemass")
                syncItemRow("Goals & custom foods", systemImage: "target")
                syncItemRow("Chat history", systemImage: "bubble.left.and.bubble.right")
            } header: {
                Text("What Syncs")
            } footer: {
                Text("Nomva creates a backup before switching sync modes and merges records by their stable IDs so a failure never silently replaces the only copy.")
            }
        }
        .navigationTitle("iCloud Sync")
        .task {
            await syncManager.updateAccountStatus()
        }
    }

    @ViewBuilder
    private func syncItemRow(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
        }
    }
}
