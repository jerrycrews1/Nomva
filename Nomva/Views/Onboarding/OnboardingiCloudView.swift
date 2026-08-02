import SwiftUI

struct OnboardingiCloudView: View {
    var onContinue: () -> Void

    @State private var enableSync = false
    @State private var isApplying = false
    @EnvironmentObject private var syncManager: SyncManager

    var body: some View {
        OnboardingShell {
            OnboardingSectionCard(
                title: "Sync across your devices?",
                subtitle: "Use iCloud if you want your history on your other Apple devices.",
                tone: .hero
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(systemName: "icloud.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(NomvaTheme.info)
                            .frame(width: 64, height: 64)
                            .background(NomvaTheme.info.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Optional")
                                .font(.headline)
                            Text("This uses your Apple account. Nomva creates a backup before switching stores.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !syncManager.isAccountAvailable {
                        Label("Sign in to iCloud on this device to turn sync on.", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(NomvaTheme.warning)
                    }

                    if case .error(let message) = syncManager.syncStatus {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(NomvaTheme.warning)
                    }
                }
            }

            OnboardingSectionCard(
                title: "Choose your default",
                subtitle: "You can always change this later in Settings."
            ) {
                Toggle(isOn: $enableSync) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable iCloud Sync")
                            .font(.headline)
                        Text("Turn this on if you want your history to follow you across devices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(NomvaTheme.info)
                .disabled(!syncManager.isAccountAvailable || isApplying)

                if isApplying, let message = syncManager.syncStatus.message {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Button(enableSync ? "Enable & Continue" : "Continue Without Sync") {
                Task {
                    if enableSync {
                        isApplying = true
                        await syncManager.setSyncEnabled(true)
                        isApplying = false
                        guard syncManager.iCloudEnabled else { return }
                    }
                    onContinue()
                }
            }
            .buttonStyle(NomvaPrimaryButtonStyle())
            .disabled(isApplying)

            Button("Decide Later") {
                onContinue()
            }
            .buttonStyle(NomvaSecondaryButtonStyle())
            .disabled(isApplying)
        }
        .task {
            await syncManager.updateAccountStatus()
        }
    }
}
