import SwiftUI
import SwiftData

struct OnboardingiCloudView: View {
    var onContinue: () -> Void

    @State private var enableSync = false
    @State private var iCloudAvailable = false
    @EnvironmentObject private var syncManager: SyncManager

    var body: some View {
        OnboardingShell {
            OnboardingSectionCard(
                title: "Sync across your devices?",
                subtitle: "Keep your data private in iCloud and available on iPhone, iPad, and Mac.",
                tone: .hero
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(systemName: "icloud.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.blue)
                            .frame(width: 64, height: 64)
                            .background(Color.blue.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Optional and private")
                                .font(.headline)
                            Text("Nomva uses your Apple account. No separate signup required.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !syncManager.isAccountAvailable {
                        Label("No iCloud account was found on this device yet.", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
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
                .tint(.blue)
                .disabled(!syncManager.isAccountAvailable)
            }
        } footer: {
            Button(enableSync ? "Enable & Continue" : "Continue Without Sync") {
                if enableSync {
                    syncManager.iCloudEnabled = true
                }
                onContinue()
            }
            .buttonStyle(NomvaPrimaryButtonStyle())

            Button("Decide Later") {
                onContinue()
            }
            .buttonStyle(NomvaSecondaryButtonStyle())
        }
        .task {
            await syncManager.updateAccountStatus()
        }
    }
}
